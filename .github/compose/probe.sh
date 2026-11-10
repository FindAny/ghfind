#!/usr/bin/env bash
# Read-only probe of production after a deploy: status code, latency, and raw i18n keys
# (a page showing "tiers.x.name" instead of text means a missing translation).
#
#   .github/compose/probe.sh                 # https://ghfind.com
#   .github/compose/probe.sh https://host    # another origin
#
# Exit status: 0 every path returned 200 with no raw keys, 1 otherwise.
set -uo pipefail
origin=${1:-https://ghfind.com}
paths=(/ /en /zh /en/leaderboard /zh/leaderboard /en/u/hikariming /zh/u/hikariming
  /en/vs/torvalds/yyx990803 /en/developers/language/TypeScript /en/projects /en/feed /en/docs
  /api/score/hikariming /api/stats "/api/leaderboard?view=trending&window=all"
  /api/badge/hikariming "/api/card/hikariming?theme=light" /openapi.json /llms.txt /sitemap.xml)
body=$(mktemp); trap 'rm -f "$body"' EXIT
bad=0
printf '%-44s %5s %7s %s\n' PATH CODE MS RAWKEYS
for p in "${paths[@]}"; do
  out=$(curl -s -o "$body" -w '%{http_code} %{time_total}' -H 'user-agent: ghfind-deploy-probe' --max-time 30 "$origin$p")
  code=${out% *}; ms=$(awk -v t="${out#* }" 'BEGIN{printf "%d", t*1000}')
  raw=$(grep -o -E '(realms|tiers)\.[a-zA-Z]+\.(name|blurb)' "$body" 2>/dev/null | sort -u | head -3 | tr '\n' ' ')
  { [ "$code" = 200 ] && [ -z "$raw" ]; } || bad=1
  printf '%-44s %5s %7s %s\n' "$p" "$code" "$ms" "$raw"
done
exit $bad
