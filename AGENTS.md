# AGENTS.md (FindAny/ghfind)

本仓库是 ghfind 的公开仓库：评分模块、SDK、CLI，以及**全部 CI/CD 与生产部署工作流**（部署中枢）。
完整产品规则（业务规则、Frontend Stack Rules 等）在私有仓库 `ghfind-server` 的 `AGENTS.md`；组装后的工作区根目录使用那一份。
接手前先读下方「文档索引」。

## 文档索引

| 要做的事 | 先读 |
| --- | --- |
| 了解三仓库、组装、发布 → 组合 → 部署、凭据与安全模型 | [`docs/architecture.md`](docs/architecture.md) |
| 发版、组合 / 固定版本、回滚、Feed 切换、故障恢复、App 密钥轮换、本地组装 | [`docs/runbook.md`](docs/runbook.md)（man page 格式，操作以此为准） |
| 给客户 / 合作方介绍部署方式（中文） | [`docs/deployment.zh.md`](docs/deployment.zh.md) |
| 文件归属（哪个仓库拥有哪个路径） | [`.github/compose/components.json`](.github/compose/components.json)（唯一清单） |
| 修改 CI/CD | `.github/workflows/`；私有仓库共用 [`component-ci.yml`](.github/workflows/component-ci.yml) / [`component-release.yml`](.github/workflows/component-release.yml)，它们自己的 `ci.yml`/`release.yml` 只是调用方 |
| 评分模块 | [`scoring/README.md`](scoring/README.md)、[`docs/rfc/2026-10-15-account-scoring.md`](docs/rfc/2026-10-15-account-scoring.md) |
| CLI | [`docs/development/cli.md`](docs/development/cli.md) |
| 产品与业务规则、前端规则、Cloudflare 资源细节 | 私有仓库 `ghfind-server`：根目录 `AGENTS.md`、`docs/README.md`、`docs/operations/cloudflare-deployment-runbook.md` |

文档只在一处维护：设计写进 `architecture.md`，操作写进 `runbook.md`，中文对外说明 `deployment.zh.md` 跟随两者更新。私有仓库只链接这里，不复制。

## 规则

- **评分纯净与三端一致**：评分公式、风险规则、评级阶梯只在 `scoring/` 定义；不得联网、读环境变量、碰 token、时钟或随机数，Go 只用标准库白名单。修改时 TypeScript、Go、Python 三端与 `scoring/fixtures/` 在同一 PR 内同步，见 [`scoring/README.md`](scoring/README.md)。`pnpm scoring:boundary` 必须通过。
- **工作流是生产关键路径**：`.github/workflows`、`.github/compose`、`.github/actions` 决定生产部署。修改须保持 `ghfind-server` 中 `scripts/check-cf-release-workflow.mts` 的发布契约通过（在组装后的工作区运行 `pnpm ci:check-cf-release-workflow` 与 `node --test scripts/check-cf-release-workflow.test.mjs`），生产作业只在 `deploy` 分支的组装提交上运行（`require-manifest: true`）。
- **不放私有代码与凭据**：不得把 `ghfind-server` / `ghfind-frontend` 的文件、组装产物或任何密钥提交到本仓库；`deploy` 分支只允许 release bot 写入，提交内容只能是公开发布树加 `components.manifest.json`。不要在工作流里打印私有源码或把它作为 artifact 上传（日志公开）。
- **不使用 `pull_request_target`**。PR（含 fork）只跑无密钥的 `scoring.yml`（三项必需检查，不得自行跳过）；需要 release bot 的完整 `ci.yml` 只在合并后的 `main` 与 `deploy` 上运行。
- 前端规则（shadcn/ui Nova、Lucide、Motion 等）见 `ghfind-server` 的 `AGENTS.md`。

## 完成前检查

| 改动 | 必跑 |
| --- | --- |
| `scoring/` | `pnpm --filter @ghfind/scoring typecheck && pnpm --filter @ghfind/scoring test`、`(cd scoring && go test ./...)`、`(cd packages/ghfind-py && python3 -m pytest -q)`、`pnpm scoring:boundary` |
| SDK | `packages/ghfind-js`：`npm ci && npm run typecheck && npm test`；`packages/ghfind-py`：`python3 -m pytest -q` |
| CLI | `go test ./internal/agentcli && go build -o bin/ghfind ./cmd/ghfind` |
| 工作流 / 组装工具 | 在组装后的工作区（见 `docs/architecture.md`）运行发布契约检查与 `pnpm test` |
