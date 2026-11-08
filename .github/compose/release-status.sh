#!/usr/bin/env bash
# Where a release is in the chain: Release → rel/ marker → deploy commit → deploy CI →
# production deploys. Read-only; needs gh (authenticated) and jq.
#
#   .github/compose/release-status.sh ghfind-server v1.0.6          # one report
#   .github/compose/release-status.sh --wait ghfind v1.0.3          # follow until it ends
#
# Exit status: 0 deployed (Cloudflare and apps deploys succeeded), 1 a step failed,
# 2 still in progress (only without --wait).
#
# The deploy workflows start by workflow_run, so their runs report main's SHA, not the
# deploy commit's. They are matched as the first runs created after the deploy CI run.
set -euo pipefail

wait=0
[ "${1:-}" = --wait ] && { wait=1; shift; }
repo=${1:-}; tag=${2:-}
case "$repo" in ghfind|ghfind-server|ghfind-frontend) ;; *) echo "usage: $0 [--wait] ghfind|ghfind-server|ghfind-frontend vX.Y.Z" >&2; exit 64 ;; esac
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-status: tag must look like v1.2.3" >&2; exit 64; }
hub=FindAny/ghfind

# gh with retries: transient GitHub/TLS errors should not end a long --wait.
ghr() { local _; for _ in 1 2 3 4; do "$@" 2>/dev/null && return 0; sleep 5; done; return 1; }
line() { printf '%-11s %-10s %s\n' "$1" "$2" "${3:-}"; }

# Prints the report; returns 0 deployed, 1 failed, 2 pending.
report() {
  local run state url
  run=$(ghr gh run list --repo "FindAny/$repo" --workflow release.yml --limit 30 \
    --json databaseId,status,conclusion,headBranch,url \
    --jq "[.[]|select(.headBranch==\"$tag\")][0]|select(.!=null)|\"\(.status) \(.conclusion) \(.url)\"") || run=""
  if [ -z "$run" ]; then line release pending "no Release run for $tag in FindAny/$repo yet"; return 2; fi
  read -r state conc url <<<"$run"
  [ "$state" = completed ] || { line release running "$url"; return 2; }
  [ "$conc" = success ] || { line release "$conc" "$url"; return 1; }
  line release success "$url"

  if ! git ls-remote --exit-code --tags "https://github.com/FindAny/$repo.git" "refs/tags/rel/$tag" >/dev/null 2>&1; then
    line verified missing "rel/$tag not pushed (see the Release run)"; return 1
  fi
  line verified yes "rel/$tag"

  # Deploy commits that pin this version, newest first, e.g.
  # "deploy: ghfind v1.0.3 + ghfind-server v1.0.5 + ghfind-frontend v1.0.2".
  local commits head pinned=() s m
  commits=$(ghr gh api "repos/$hub/commits?sha=deploy&per_page=60" --jq '.[]|"\(.sha) \(.commit.message|split("\n")[0])"') || commits=""
  while read -r s m; do
    [[ " ${m#deploy: } " =~ (^|[[:space:]+])$repo\ $tag([[:space:]]|$) ]] && pinned+=("$s $m")
  done <<<"$commits"
  if [ ${#pinned[@]} = 0 ]; then line compose pending "no deploy commit pins $repo $tag yet (Compose release in $hub)"; return 2; fi
  head=$(ghr gh api "repos/$hub/commits/deploy" --jq .sha) || head=""
  # Report the newest commit, unless a newer composition superseded it before it
  # finished (CI cancelled); then report the newest older commit that deployed.
  local entry out rc first="" first_rc=0
  for entry in "${pinned[@]}"; do
    set +e; out=$(deploy_chain "${entry%% *}" "${entry#* }" "$head"); rc=$?; set -e
    [ -n "$first" ] || { first=$out; first_rc=$rc; }
    if [ $rc = 0 ] || [ "${entry%% *}" = "$head" ]; then printf '%s\n' "$out"; return $rc; fi
  done
  printf '%s\n' "$first"; return $first_rc
}

# One deploy commit through CI and both production deploys.
deploy_chain() {
  local sha=$1 msg=$2 head=$3 run state conc url
  line compose "done" "${sha:0:7} $msg$([ "$sha" = "$head" ] && echo ' (deploy head)' || echo ' (superseded by a newer deploy commit)')"

  local ci created
  ci=$(ghr gh run list --repo "$hub" --workflow ci.yml --commit "$sha" --limit 1 \
    --json status,conclusion,createdAt,url --jq '.[0]|select(.!=null)|"\(.status) \(.conclusion) \(.createdAt) \(.url)"') || ci=""
  if [ -z "$ci" ]; then line ci pending "CI on deploy not started"; return 2; fi
  read -r state conc created url <<<"$ci"
  [ "$state" = completed ] || { line ci running "$url"; return 2; }
  [ "$conc" = success ] || { line ci "$conc" "$url (production deploys are skipped)"; return 1; }
  line ci success "$url"

  local wf name result=0 id plan
  for wf in deploy-apps-production.yml deploy-cf-production.yml; do
    name=$([ "$wf" = deploy-cf-production.yml ] && echo cloudflare || echo apps)
    run=$(ghr gh run list --repo "$hub" --workflow "$wf" --limit 40 \
      --json databaseId,status,conclusion,createdAt,url \
      --jq "[.[]|select(.createdAt>=\"$created\")]|sort_by(.createdAt)[0]|select(.!=null)|\"\(.databaseId) \(.status) \(.conclusion) \(.url)\"") || run=""
    if [ -z "$run" ]; then line "$name" pending "not started"; result=2; continue; fi
    read -r id state conc url <<<"$run"
    if [ "$state" != completed ]; then line "$name" running "$url"; result=2; continue; fi
    if [ "$conc" != success ]; then line "$name" "$conc" "$url"; [ $result = 2 ] || result=1; continue; fi
    if [ "$name" = cloudflare ]; then
      # The Feed plan: site-only when Feed inputs are unchanged, else the Feed cutover.
      plan=$(ghr gh run view "$id" --repo "$hub" --log | grep -oE '\{"feedRelease":[^}]*\}' | head -1) || plan=""
      line "$name" success "$url ${plan:+feed plan $plan}"
    else
      line "$name" success "$url"
    fi
  done
  return $result
}

if [ $wait = 0 ]; then report; exit $?; fi
prev=""
while true; do
  set +e; out=$(report); rc=$?; set -e
  if [ "$out" != "$prev" ]; then printf '\n[%s]\n%s\n' "$(date +%H:%M:%S)" "$out"; prev=$out; fi
  [ $rc = 2 ] || exit $rc
  sleep 30
done
