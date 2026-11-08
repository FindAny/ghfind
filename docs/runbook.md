# ghfind-release(7) — operator runbook

## NAME

ghfind-release — release, compose, deploy, roll back and recover the three-repository
ghfind application.

## SYNOPSIS

```sh
# Release a component (in FindAny/ghfind, ghfind-server or ghfind-frontend)
git switch main && git pull && git tag vX.Y.Z && git push origin vX.Y.Z

# Compose by hand (pin, recompose, preview)
gh workflow run compose-release.yml -R FindAny/ghfind \
  [-f ghfind=vA.B.C] [-f ghfind_server=vD.E.F] [-f ghfind_frontend=vG.H.I] \
  [-f force=true] [-f dry_run=true]

# Force a Feed runtime cutover on the next production release
gh variable set FEED_RELEASE_MODE -R FindAny/ghfind --body always   # then delete it

# Assemble a workspace locally (in a FindAny/ghfind checkout)
.github/compose/assemble.sh [--channel main] [--ref NAME=REF] [--dir NAME=PATH] [--clean]
```

## DESCRIPTION

ghfind is three repositories deployed as one application. The design is in
[architecture.md](./architecture.md); this page covers only the procedures.

| Repository | Visibility | Release workflow | CI workflow |
| --- | --- | --- | --- |
| `FindAny/ghfind` | public, deploy hub | `release.yml` | `scoring.yml` (PRs), `ci.yml` (main, deploy) |
| `FindAny/ghfind-server` | private | `release.yml` (calls the hub's `component-release.yml`) | `ci.yml` (calls the hub's `component-ci.yml`) |
| `FindAny/ghfind-frontend` | private | same | same |

The release path is event-driven. Nothing polls:

```text
tag vX.Y.Z on green main → Release → rel/vX.Y.Z + GitHub release → dispatch Compose release
→ deploy-branch commit (public tree + components.manifest.json) → CI on deploy
→ Deploy production (Cloudflare) + Deploy apps (production)
```

The private repositories hold no build or deploy logic of their own. Their
`ci.yml` and `release.yml` are thin callers of the reusable workflows in
`FindAny/ghfind/.github/workflows/` (`component-ci.yml`, `component-release.yml`),
so all CI/CD changes happen in one place.

## COMMANDS

### release

1. Merge to `main` in the component's repository and wait for its `CI` to pass.
2. Tag the version on that exact commit: `git tag vX.Y.Z && git push origin vX.Y.Z`.
   Use the next semver. Tags are permanent, so never move or reuse one.
3. Watch, in order:
   - `Release` in the component's repository. It refuses a tag that is not on
     `main` or whose commit has no green `CI`, then pushes `rel/vX.Y.Z` and
     dispatches composition.
   - `Compose release` in `FindAny/ghfind`.
   - `CI` on the `deploy` branch in `FindAny/ghfind`.
   - `Deploy production (Cloudflare)` and `Deploy apps (production)` in
     `FindAny/ghfind`.

A release is *verified* once `rel/vX.Y.Z` exists. It is *deployed* once the deploy
workflows succeed on the `deploy` commit that pins it.

If the public repository changes ownership of a path (see **add-path**), release
`FindAny/ghfind` first, then the component that relies on it.

**Release order when removing or renaming things.** The hub workflows call scripts
and `package.json` commands from ghfind-server, and a `deploy` commit runs the
workflows of the latest *released* hub. So when a server change removes or renames
something a hub workflow uses, update the hub, merge it and release it first. Only
then release the server. Otherwise CI on `deploy` fails and nothing deploys. (This
happened on 2026-11-08: server v1.0.5 removed `smoke:backend:*` while hub v1.0.1
still ran it. Fixed by hub v1.0.2.) Before tagging, check with
`grep -rn '<removed name>' .github/` here.

### compose

`Compose release` (Actions → Compose release → Run workflow, or `gh workflow run`) has
these inputs:

| Input | Effect |
| --- | --- |
| `ghfind`, `ghfind_server`, `ghfind_frontend` | Pin that component to a tag. Empty means the latest verified release. |
| `force` | Recompose even when `deploy` already pins exactly these releases. |
| `dry_run` | Compose and assemble, report the manifest, push nothing. |

Runs are serialized. A run is a no-op when `deploy` already pins the requested
releases and `force` is off.

### rollback

- **Application rollback (preferred).** Recompose the previous good tags with
  `force=true`. The usual CI and deploy gates then apply. Find the tags in the
  `components.manifest.json` of earlier `deploy` commits:
  `git log origin/deploy -p -- components.manifest.json`.
- **Immediate Worker rollback.** The production workflow already rolls back
  automatically when a smoke check fails. To roll back by hand, follow "Manual
  rollback" in `docs/operations/cloudflare-deployment-runbook.md` (ghfind-server).
  A Worker rollback does not undo D1 migrations, R2 objects or the Feed runtime.
- **Web anchor repair.** If a failed production run left the Web paused, run
  `Repair production web (manual)`. It rebuilds the anchor from the `deploy` head.

### feed

The Feed runtime (container image, runtime Worker, Feed D1 schema) is released only
when its inputs change. `deploy-cf-production.yml` decides this in its plan job:

| Plan result | Job that runs | Effect |
| --- | --- | --- |
| inputs equal the `feed/released` hash | `site` | Web and Workers deploy in the live Feed gateway mode. The runtime is not touched. |
| inputs changed, no hash recorded, or `FEED_RELEASE_MODE=always` | `deploy` | Full cutover: runtime rollout, then a settle gate of about 4 minutes while Cloudflare placements move to the new image, then Web, smoke, and `feed/released` is moved to the release. |

- Hashed inputs: the `Dockerfile.feed.dockerignore` allowlist plus `platform/runtime`,
  `platform/shared`, `migrations-feed`, `ops/feed-production-manifest.json` and the
  rollout scripts. See `scripts/feed-release-plan.mjs` in ghfind-server.
- Inspect the recorded cutover: `git fetch origin tag feed/released && git show -s feed/released`.
- Force a cutover: set the repository variable `FEED_RELEASE_MODE=always`, release
  or recompose with `force=true`, then **delete the variable**.
- Contain the Feed without a release: run `Feed production pause (containment only)`.

### recover

| Symptom | Action |
| --- | --- |
| `Release` failed with "CI not green" | Wait for or fix `CI` on that commit. Then re-run the failed `Release` job. The tag stays. |
| `Release` failed to dispatch composition | The release is verified but not deployed. Run `Compose release` by hand. |
| `Compose release` notice "no verified release" | That component has no `rel/` marker yet, so the run used `main`. Release the component. |
| `Compose release` assembly conflict | The log names a file owned by two repositories. Fix ownership in `.github/compose/components.json` or remove the duplicate, then release again. |
| `CI` failed on `deploy` | Nothing was deployed. Fix forward with a new release, or recompose older tags (**rollback**). |
| Deploy failed before cutover | Production is unchanged. Re-run the workflow, or fix forward. |
| Deploy failed after smoke rollback | The previous Worker versions are active. Read the job summary, then fix forward. |
| `container_version_or_contract_mismatch` during a Feed cutover | Placements were still on the old image. The settle gate prevents this. If it happens anyway, re-run the deploy; the next attempt waits again. |

### rotate-key

The release bot (`findany-ghfind-release-bot`, an org-owned GitHub App) can be
managed and re-keyed only by organization owners.

1. Organization settings → GitHub Apps → findany-ghfind-release-bot → Generate a
   private key. Save it to a temporary file.
2. Store it everywhere, without printing it:
   ```sh
   K=/path/to/new-key.pem
   for env in release Production "Feed staging" "Feed staging operations"; do
     gh secret set RELEASE_BOT_PRIVATE_KEY -R FindAny/ghfind --env "$env" < "$K"
   done
   gh secret set RELEASE_BOT_PRIVATE_KEY -R FindAny/ghfind-server < "$K"
   gh secret set RELEASE_BOT_PRIVATE_KEY -R FindAny/ghfind-frontend < "$K"
   rm -P "$K"
   ```
3. Run `Compose release` with `dry_run=true` to prove the new key works. Then delete
   the old key in the App settings.

Never store the key as a repository secret in `FindAny/ghfind`. Only the
environments above, which are limited to `main` and `deploy`, may hold it there.

### add-path

- **Server-owned path:** nothing to do. ghfind-server contributes every tracked file
  except `.github/`.
- **Frontend-owned path:** add it to the `ghfind-frontend` `paths` in
  `.github/compose/components.json` here, release `FindAny/ghfind`, then release
  the frontend.
- **Replacing a public root file from ghfind-server:** add it to `replaces`.
  Any other overlap fails assembly.

### develop

```sh
git clone git@github.com:FindAny/ghfind.git && cd ghfind
.github/compose/assemble.sh --channel main          # needs read access to the private repos
pnpm install
# Work on a component from a local checkout instead of a fetched copy:
.github/compose/assemble.sh --clean --dir ghfind-server=../ghfind-server --dir ghfind-frontend=../ghfind-frontend
```

Overlaid files are listed in `.git/info/exclude`, so `git status` shows only public
changes. Commit component changes in the component's own repository. `--clean`
removes a previous assembly.

## ENVIRONMENT

| Name | Kind | Where | Purpose |
| --- | --- | --- | --- |
| `RELEASE_BOT_APP_ID` | variable | all three repositories | Release bot App ID |
| `RELEASE_BOT_PRIVATE_KEY` | secret | hub environments `release`, `Production`, `Feed staging`, `Feed staging operations`; private repositories | Mints per-job tokens: read the components, push `deploy`, dispatch composition |
| `COMPOSE_PUBLIC_REF` | variable | private repositories (optional) | Public ref that component CI assembles against (default: latest `rel/` tag) |
| `FEED_RELEASE_MODE` | variable | hub | `auto` (default) or `always` |
| `CF_API_TOKEN`, `CF_ACCOUNT_ID` | secrets | hub | Cloudflare deploys |
| `FEED_*_SECRET`, `MOSOO_API_TOKEN`, `AUTH_*` | secrets | hub environments | Feed runtime and app secrets, set as Worker secrets during deploy |
| `COMPOSE_TOKEN` | env (local or job) | | Token assemble.sh uses to fetch the private repositories. Falls back to your git credentials. |

The production GitHub token pool used by scans is runtime data of the private
deployment. It must never appear in this repository, the SDKs or a workflow log.

## FILES

| Path (in FindAny/ghfind) | Role |
| --- | --- |
| `.github/compose/components.json` | Who owns which path |
| `.github/compose/assemble.sh` | Workspace assembly |
| `.github/compose/compose-release.sh` | Builds the `deploy` commit. It refuses to stage anything except the manifest. |
| `.github/actions/assemble/` | Assembly action used by every workflow |
| `.github/workflows/component-{ci,release}.yml` | Reusable CI and release for the private repositories |
| `components.manifest.json` (on `deploy` only) | Exact component commits for that deploy |
| tags `rel/vX.Y.Z` | Verified-release markers, one set per repository |
| tag `feed/released` | Feed input hash and release of the last successful cutover |

## EXIT STATUS

Every workflow fails loudly rather than skipping. A required check never skips.
A release that could not dispatch composition fails. A deploy that cannot prove
exact-commit CI evidence stops before its first write.

## SEE ALSO

[architecture.md](./architecture.md) (design, credentials, security model).
[deployment.zh.md](./deployment.zh.md) (Chinese deployment overview for clients and partners).
In ghfind-server: `docs/operations/cloudflare-deployment-runbook.md` (Cloudflare
resources, secrets, smoke, manual rollback) and
`docs/operations/feed-github-protection.md`.
