# Architecture: three repositories, one workspace

ghfind is developed in three repositories and deployed as one application.

| Repository | Visibility | Owns |
| --- | --- | --- |
| **`FindAny/ghfind`** | public | The workspace root: the scoring module (`scoring/`), SDKs (`packages/ghfind-js`, `packages/ghfind-py`), the Go CLI (`cmd/ghfind`, `internal/agentcli`), agent skills, the scoring docs, **all CI/CD and deploy workflows** (`.github/workflows`), the composition tooling (`.github/compose`, `.github/actions/assemble`) and a minimal scoring-only pnpm workspace. It is the deploy hub: the `Production` and Feed environments, the Cloudflare secrets and the `Protect main` ruleset live here. |
| `FindAny/ghfind-server` | private | Everything else: `src/lib`, `src/app/api`, the Workers in `apps/{api,coord,talent,cost-monitor,router}`, Go services, `platform/`, migrations, `scripts/`, `ops/`, operator docs, and the workspace configuration (`package.json`, `pnpm-lock.yaml`, `tsconfig.json`, `wrangler.jsonc`, …). |
| `FindAny/ghfind-frontend` | private | `apps/web`, `src/components`, `src/app/[locale]`, `src/app/globals.css`, `src/messages`, `src/i18n`, `src/hooks`, `src/config`, `packages/i18n`, `public/`, `components.json`, `design/`. |

The exact ownership lives in [`.github/compose/components.json`](../.github/compose/components.json).
The frontend still imports shared server code (`src/lib`, server-side readers used
by Astro pages), so neither private repository builds on its own: every build
assembles all three.

## Assembly

[`.github/compose/assemble.sh`](../.github/compose/assemble.sh) runs in a checkout of
this repository and copies the private components on top:

- `ghfind-server`: every tracked file except its own `.github/`. Its root files may
  replace this repository's copies only if they are listed in `replaces`
  (`README.md`, `AGENTS.md`, `package.json`, `pnpm-lock.yaml`, `go.mod`, …).
- `ghfind-frontend`: its `paths`.
- Any other file that already exists is a conflict, and assembly fails.

Which version of each component is used:

| Situation | Components used |
| --- | --- |
| Commit on the `deploy` branch | The exact commits pinned by `components.manifest.json` (`--require-manifest` makes this mandatory) |
| CI and ops workflows elsewhere | The latest **verified release** of each component (the highest `vX.Y.Z` with a `rel/vX.Y.Z` marker), or `main` if none exists |
| Local development | `--dir name=../path` for local checkouts, `--ref name=tag` to pin, `--channel main` for default branches |

Private repositories are fetched with a GitHub App installation token
(`COMPOSE_TOKEN`), minted per job with read-only Contents access to the two
private repositories. Overlaid files are listed in `.git/info/exclude`, so they
never show up as changes and can never be committed by accident.

## Release and deployment

```text
any repository:  merge to main ─▶ CI green ─▶ tag vX.Y.Z
                                               │
                         release.yml: CI green on that exact main commit?
                                               │ yes
                         push rel/vX.Y.Z marker, publish GitHub release,
                         dispatch FindAny/ghfind compose-release.yml
                         (event-driven only: retried, then the release fails loudly)
                                               │
FindAny/ghfind compose-release.yml:
  latest verified ghfind + ghfind-server + ghfind-frontend
  ─▶ assemble once to prove the combination has no conflicts
  ─▶ commit = ghfind release tree + components.manifest.json   (no private code)
  ─▶ push to `deploy` with the release bot App (only the App may update `deploy`)
                                               │
FindAny/ghfind CI (push to deploy): full suite on the assembled workspace
  (Application checks, Feed storage contracts, Feed runtime builds,
   Complete local Feed E2E, Verify release)
                                               │ success
deploy-cf-production.yml + deploy-apps-production.yml (workflow_run, branch deploy)
  ─▶ check out that exact commit, assemble with --require-manifest
  ─▶ D1 migrations, Workers, Feed runtime, smoke, automatic rollback
  ─▶ Cloudflare
```

- **Event-driven, no polling.** Composition starts only when a release dispatches it
  (or an owner runs it). Runs are serialized, so two close releases compose one
  after the other; each reads the newest verified releases, and the deploy
  workflows' superseded checks skip any older deploy commit, so production only
  moves forward. If the dispatch still fails after retries, the release job fails:
  the release is verified (`rel/vX.Y.Z`) but not deployed until an owner runs
  `compose-release.yml`.
- Composition is a no-op when `deploy` already pins the latest verified releases.
- `repair-prod-web.yml` rebuilds the paused web anchor from the `deploy` head after a failed production run.
- **One CI/CD definition.** The private repositories' `ci.yml` and `release.yml` are thin
  callers of the reusable [`component-ci.yml`](../.github/workflows/component-ci.yml) and
  [`component-release.yml`](../.github/workflows/component-release.yml) here, so the
  release gate, marker tags and composition dispatch are identical in all three
  repositories.
- Feed operations workflows (`feed-operator`, `feed-governance`, `feed-staging`, `feed-production-pause`, …) are dispatched on `main` and assemble the latest verified releases. Staging from `codex/feed-*` branches is retired: the release bot key is only available on `main` and `deploy`.

### Feed releases

The Feed runtime is released separately from the site. A plan job hashes the
Feed inputs (image context, runtime Worker, Feed schema) and compares them with
the last successful cutover (`feed/released` tag). When nothing changed, the site
release deploys the Web in the live Feed gateway mode and never touches the runtime;
otherwise the full cutover runs, after a settle gate that waits for Cloudflare
container placements to pick up the new image. Production and apps releases are
serialized on core D1 migrations. Operator details: [runbook.md → feed](./runbook.md#feed).

## Pull requests

Pull requests to `main` run `scoring.yml`, which needs no secrets and is safe for
forks: **Scoring parity (TS / Go / Python) and boundary**, **JavaScript SDK** and
**Workflow lint**. These are the required checks in the `Protect main` ruleset.
The full application suite (`ci.yml`) needs the release bot, so it runs after
merge on `main` and again on every `deploy` commit, where deploys require it.
Tag a release only once `main` CI is green; `release.yml` enforces this.

The deploy workflows act only on successful push CI of the `deploy` branch, and their exact-commit CI evidence (`scripts/feed-ci-evidence.mjs` in `ghfind-server`) is verified before any write. `scripts/check-cf-release-workflow.mts` keeps that contract, including `require-manifest` assembly in every production job, under test.

## Credentials

| Credential | Where | Used for |
| --- | --- | --- |
| Cloudflare token, Feed and Mosoo secrets | `FindAny/ghfind` repository secrets and the `Production` / `Feed staging` environments | Deploys and Feed operations; only workflows in this repository can read them |
| Release bot App key (`secrets.RELEASE_BOT_PRIVATE_KEY`) | Here: only the `release` (main, deploy), `Production`, `Feed staging` and `Feed staging operations` environments, never a repository secret. Private repositories: repository secret (they are owner-only) | Short-lived tokens: read the private components for assembly, push `deploy`, dispatch composition |
| Release bot App ID (`vars.RELEASE_BOT_APP_ID`) | Repository variable in all three repositories | Not secret |

The App is owned by FindAny. Only organization owners can manage, re-key or debug
it (no App managers are configured). Because its key exists only in environments
limited to `main` and `deploy`, a workflow on any other branch, including one
pushed by a collaborator with write access, cannot use it. The private
repositories hold no deploy credentials.

## Security notes

- **Pull requests** (forks included) run only the key-less `scoring.yml` checks.
  Required jobs never skip themselves. No workflow uses `pull_request_target`.
- **Public logs.** Workflow logs here are public. Secrets are masked; workflows must
  not print private source or upload it as an artifact.
- **No private code in this repository.** `compose-release.sh` refuses to commit
  anything except `components.manifest.json`.

## GitHub Free plan constraints

- This public repository has unlimited Actions minutes, rulesets and environments.
- Private repositories get 2,000 Actions minutes per month and no rulesets or
  required reviewers, so their CI is one lean job and their `main` branches are not
  protected by GitHub. The full gate runs here before production.
- Deploy keys are disabled for the organization; the release bot App replaces them.

## Runbook

Procedures (release, compose, rollback, Feed cutover, recovery, key rotation, local
assembly) are in [runbook.md](./runbook.md).
