# 审查与合并策略 / Review policy

本文件规定 qvictl/weread.koplugin 的 PR 由谁审查、何时可以自动批准和合并、何时必须由人决定。
它和 [CONTRIBUTING.md](CONTRIBUTING.md)（测试与覆盖率要求）一起生效；网关逻辑在
[`.github/review-gate/`](.github/review-gate/)，工作流是
[`.github/workflows/review-gate.yml`](.github/workflows/review-gate.yml)。

> **当前状态：咨询模式（advisory）。** 分支保护要求的批准数仍为 0，AI 审查应用尚未安装。
> 网关照常评估每个 PR 并更新置顶评论，但因为没有 AI 审查，第 2 项永远不满足，所以它不会批准、
> 也不会开启自动合并；合并仍由维护者按 CONTRIBUTING.md 手动完成。安装应用后按
> [启用步骤](#启用步骤) 切换。

## 审查者

| 审查者 | 角色 | 配置 |
|---|---|---|
| [CodeRabbit](https://github.com/apps/coderabbitai) | 主审查。每次推送都会增量审查；发现阻断性问题时 **Request changes**，问题解决且最新提交审查通过后自动 **Approve** | [`.coderabbit.yaml`](.coderabbit.yaml) |
| [Gemini Code Assist](https://github.com/apps/gemini-code-assist) | 第二意见。PR 打开时审查；之后的推送需评论 `/gemini review` 才会重新审查 | [`.gemini/config.yaml`](.gemini/config.yaml)、[`.gemini/styleguide.md`](.gemini/styleguide.md) |
| 维护者（admin / maintain） | 敏感改动、超大改动、首次贡献者、上游同步和所有发布的最终决定者 | `human-approved` 标签 |

两个 AI 审查者使用相同的重点：512 MB Kindle 上的内存占用；绝不阻塞 UI 线程（事件处理里的网络、磁盘、DNS）；
子进程 / fork 安全；休眠 / 唤醒生命周期；Lua 陷阱（全局变量、nil 解引用、模式字符串转义）；KOReader 控件生命周期
（paint 前先有 `dimen`）；测试是否满足覆盖率策略；WeRead 的密钥 / 隐私和 i18n 规则。
摘要用简体中文，行内评论可以是英文。

## 严重级别的处理

- AI 标为 **潜在问题 / bug**（CodeRabbit 的 “Potential issue”、Gemini 的 HIGH / CRITICAL）的评论：**必须修复，
  或在对话里写明理由**（为什么不是问题、为什么不在本 PR 修），之后才能把对话标为已解决。不能不回复就直接 Resolve。
- 重构建议、可读性、风格类评论（“Nitpick”、“Refactor suggestion”、MEDIUM / LOW）：可以采纳，也可以简短说明后解决。
- 如果 AI 明显误判，在对话里回复理由后 Resolve，再评论 `@coderabbitai review` 请它重新审查最新提交。
  PR 作者不能用 `@coderabbitai approve` / `@coderabbitai resolve` 让 CodeRabbit 批准或关闭自己 PR 上的问题
  （`.coderabbit.yaml` 中 `allow_author_approval: false`：本仓库的 agent 都以所有者账号提交 PR）。
- 所有审查对话（AI 或人）都未解决时，网关不会批准（第 3 项）。

## 自动批准与自动合并的条件

网关（github-actions[bot]）只在 **全部** 条件对 PR 的最新提交（head SHA）成立时批准，并开启自动合并（squash，功能 PR 压缩为一个提交；上游同步分支 `sync/upstream-*` 仍用 merge commit，保留与上游共享的历史）：

1. **必需检查全部成功**：`main` 分支保护要求的检查（当前为 `ci`、`integration`、`tests-policy`）在 head SHA 上都已成功（`success` / `neutral` / `skipped`）。
2. **AI 审查已完成且没有 Request changes**：至少一个 AI 审查者（`coderabbitai[bot]` 或 `gemini-code-assist[bot]`）
   提交了 `commit_id` 等于 head SHA 的审查（CodeRabbit 没有可操作意见时不发 PR review，只在该提交上留下
   `CodeRabbit` 检查 “Review completed”，这同样算审查完成）；并且每个 AI 审查者最新的结论性审查（Approve / Request changes）都不是
   **Request changes**（之后的普通评论不会抵消 Request changes）。尚无任何 AI 审查时，网关显示“等待 AI 审查（咨询模式）”。
3. **没有未解决的审查对话**（GraphQL `reviewThreads.isResolved`，过时的对话也算）。
4. **非测试、非文档的改动 ≤ 500 行**（新增 + 删除）。测试：`spec/**`、`scripts/test_*.py`；文档：`**/*.md`、`docs/**`、`screenshots/**`。
   改动文件数超过 API 上限（3000）时视为不满足。
5. **没有触及敏感路径**（重命名的原路径也算）：
   - `.github/**`
   - `.ci/**`
   - `.circleci/**`
   - `REVIEW_POLICY.md`
   - `CONTRIBUTING.md`
   - `.coderabbit.yaml`
   - `.coderabbit.yml`
   - `.gemini/**`
   - `.luacheckrc`
   - `.luacov`
   - `.gitmodules`
   - `CHANGELOG.md`
   - `CLAUDE.md`
   - `weread/lib/updater.lua`
   - `weread/ui/updater.lua`
   - `weread/lib/cookie.lua`
   - `weread/lib/crypto.lua`
   - `weread/lib/qr_login.lua`
   - `weread/lib/worker_settings.lua`
   - `scripts/package_release.sh`
   - `scripts/extract_release_notes.sh`
   - `scripts/check_secrets.sh`
   - `scripts/check_test_policy.py`
   - `scripts/coverage_tools.py`
   - `scripts/run_lua_coverage.sh`
   - `scripts/check_lua_namespace.sh`
   - 以及按行判断的敏感改动（读不到 diff 时一律视为敏感）：
     - `_meta.lua` 中匹配 `^\s*version\s*=` 的改动行（版本号）
     - `main.lua` 中匹配 `^\s*version\s*=` 的改动行（版本号）
     - `weread/lib/client.lua` 中匹配 `(?i)(auth\|cookie\|token\|skey\|wr_vid\|login\|credential\|bearer\|x-wrpa\|api_?key\|signature\|\bsign)` 的改动行（认证/Cookie 相关代码）
     - `weread/lib/protocol.lua` 中匹配 `(?i)(sign\|hmac\|secret\|salt\|nonce\|sha\|md5)` 的改动行（签名/加密相关代码）
6. **非草稿、没有 `do-not-merge` 标签，作者可信**：作者是仓库协作者（`OWNER` / `MEMBER` / `COLLABORATOR`），
   或是已经有至少一个 PR 被合并的外部贡献者。

只要有一项不满足，网关就不批准；如果它之前批准过，会**撤销（dismiss）自己的批准**，并关闭它自己开启的自动合并
（别人开启的自动合并不动）。有新提交时，旧提交上的批准一律撤销，条件重新满足后再对新提交批准。

## 覆盖规则

- **`human-approved`**：只有当**最后一次**添加该标签的人拥有 admin 或 maintain 权限时才有效（网关通过 issue 事件 API
  查出打标签的人，再查询其权限；查不到时按无效处理）。它豁免第 4、5 项和第 6 项中的“首次贡献者”限制，
  **永远不豁免第 1–3 项**，也不豁免草稿和 `do-not-merge`。非管理员添加的 `human-approved` 会被忽略，置顶评论会写明原因。
  标签在后续提交上继续有效；不再认可时请移除标签。
- **`do-not-merge`**：任何有打标签权限的人都可以加，网关见到即不批准，覆盖标签也无法豁免。
- **`no-tests-needed`**（CONTRIBUTING.md）只影响测试策略检查，与本网关无关。

## 上游同步 PR

*Upstream sync* 工作流创建的 `sync/upstream-<date>` PR（带 `upstream-sync` 标签） 由 `github-actions[bot]` 创建。GitHub 不允许 github-actions 批准自己创建的 PR，所以**网关永远不会批准同步 PR**，
置顶评论会明确说明这一点。处理方式：

- 仓库所有者审核后手动批准并合并（必须用 **merge commit**，保留上游历史）；或
- 配置 `SYNC_TOKEN`（所有者的 fine-grained PAT），让同步 PR 以所有者身份创建。这时网关可以批准，但同步 PR 的改动行数和
  敏感路径几乎必然超限，仍需管理员审核后加 `human-approved`，并且仍需 AI 审查（可评论 `@coderabbitai review`）。

## 安全理由

- 插件内置更新器（`weread/lib/updater.lua`）会把 `main` 上版本号升级后的发布自动推送到设备。合入 `main` 的缺陷会直接到达读者的设备，所以**发布永远需要人**：版本号、发布 / 更新器、CI 和策略文件都是敏感路径，
  只有维护者用 `human-approved` 才能让它们自动合并，而且 CI 与 AI 审查仍须全部通过。
- 网关脚本永远从默认分支检出（`pull_request_target`、`workflow_run`、定时任务运行的都是默认分支上的工作流；审查事件触发的运行
  也会显式检出默认分支的脚本），从不检出或执行 PR 的代码，因此 PR 不能修改网关来批准自己。修改网关本身（`.github/**`）属于敏感路径。
- 网关只认带有自己标记的批准；其他以 github-actions[bot] 身份做出的批准（例如某个 PR 新增的工作流）会被撤销。
- 用 `GITHUB_TOKEN` 合并不会触发 `main` 上的 push 工作流（覆盖率基线、nightly），所以自动合并使用单独的
  `REVIEW_GATE_MERGE_TOKEN`；未配置时网关只批准，合并由人完成。
- 首次贡献者的 PR 必须由人看过一次（防止恶意或刷量 PR 自动合入）。

## 网关如何运行

- 触发：PR 事件（`pull_request_target`：opened / synchronize / reopened / labeled / unlabeled / ready_for_review /
  converted_to_draft）、审查与审查评论（`pull_request_review`、`pull_request_review_comment`）、必需检查所在工作流完成
  （`workflow_run`）、第三方 check suite 完成（`check_suite`），以及每 15 分钟一次的定时兜底
  （GitHub Actions 没有“审查对话已解决”的触发器，由定时任务补上）。也可以在 Actions 页面手动运行 *Review gate*，填 PR 号或留空评估全部。
- 定时任务很轻：每个打开的 PR 只读一次评论列表，只有可能在没有事件的情况下发生变化的 PR 才完整评估（head 变了、
  只被未解决对话阻塞、已批准、或超过 6 小时未刷新）；同一个 PR 的新事件会取消旧的运行。
- 每个 PR 只有一条置顶评论（以 `<!-- review-gate -->` 开头），逐项列出条件和阻塞原因；内容不变时不会重复编辑。
- 只评估目标分支为 `main` 的打开的 PR。
- 仓库变量 `REVIEW_GATE_DRY_RUN=true` 时只报告、不批准、不撤销、不合并（紧急关闭开关）。
- 单元测试：`python3 -m unittest discover -s .github/review-gate -v`（工作流 `review-gate-tests.yml`，改动网关时运行）。

## 启用步骤

在 CodeRabbit 和 Gemini Code Assist 两个 GitHub App 安装到本仓库、并确认它们已在至少一个 PR 上留下审查后执行。
以下命令需要仓库 admin 权限（本机：`export GH_CONFIG_DIR=/home/qcraft/.config/gh`）。

```sh
R=qvictl/weread.koplugin

# 0. 确认 Actions 可以批准 PR（Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests"）
gh api -X PUT repos/$R/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true

# 1. 允许自动合并
gh api -X PATCH repos/$R -F allow_auto_merge=true

# 2. 自动合并用的 token：fine-grained PAT，仅限本仓库，Contents 和 Pull requests 读写
gh secret set REVIEW_GATE_MERGE_TOKEN -R $R

# 3. main 需要 1 个批准；新提交使旧批准失效；不要求 CODEOWNERS
gh api -X PATCH repos/$R/branches/main/protection/required_pull_request_reviews \
  -F required_approving_review_count=1 \
  -F dismiss_stale_reviews=true \
  -F require_code_owner_reviews=false \
  -F require_last_push_approval=false

# 4. 管理员同样受保护规则约束（保持现状：enforce_admins=true）
gh api -X POST repos/$R/branches/main/protection/enforce_admins

# 5. 核对
gh api repos/$R/branches/main/protection --jq '{approvals: .required_pull_request_reviews.required_approving_review_count,
  dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews, enforce_admins: .enforce_admins.enabled,
  checks: .required_status_checks.contexts}'
gh api repos/$R --jq '{allow_auto_merge}'
```

启用后：所有者自己（以及以所有者账号提交的 agent）的 PR 只能由网关批准；`github-actions[bot]` 创建的同步 PR 由所有者批准。
所有 PR 仍需必需检查全部通过（`enforce_admins` 使管理员也不能绕过）。

回退到咨询模式（批准数改回 0，网关继续报告）：

```sh
gh api -X PATCH repos/$R/branches/main/protection/required_pull_request_reviews \
  -F required_approving_review_count=0 -F dismiss_stale_reviews=false \
  -F require_code_owner_reviews=false -F require_last_push_approval=false
```

紧急情况（网关或 AI 应用故障且必须合并）：先设 `REVIEW_GATE_DRY_RUN=true`
（`gh api -X POST repos/$R/actions/variables -f name=REVIEW_GATE_DRY_RUN -f value=true`），
再按上面的命令回退到 0 个批准；处理完后恢复，并在 PR 中记录原因。

---

## English summary

- **Reviewers:** CodeRabbit (primary; request-changes workflow, auto-approves once resolved) and Gemini Code Assist
  (second opinion; `/gemini review` after new pushes), configured in `.coderabbit.yaml` and `.gemini/`. Maintainers decide
  sensitive, large, first-time, upstream-sync and release changes.
- **Severity:** AI comments flagged as potential issues / bugs must be fixed or answered with a justification before the
  thread is resolved.
- **Auto-approve + auto-merge (squash)** by github-actions[bot] only when, on the head SHA: (1) all required checks
  passed; (2) an AI reviewer reviewed the head commit and no AI reviewer's latest decisive review requests changes;
  (3) no unresolved review thread; (4) ≤ 500 changed non-test / non-doc lines; (5) no sensitive path
  (CI, policy, AI config, release / version tooling, updaters, credential code, build scripts); (6) not draft, no
  `do-not-merge`, author is a collaborator or has a merged PR. The gate dismisses its own approval when a new commit
  arrives or a condition stops holding.
- **Override:** `human-approved`, effective only when last applied by an admin / maintainer, waives (4), (5) and the
  first-time-contributor rule — never (1)–(3).
- **Sync PRs** opened by github-actions[bot] cannot be approved by the gate: the owner approves them (or `SYNC_TOKEN`
  makes them owner-authored, and an admin adds `human-approved`).
- **Why:** merged code reaches devices through auto-update; releases always need a human. The gate script always runs
  from the default branch and never executes PR code.
- **Status:** advisory (0 required approvals) until the AI review apps are installed; see *启用步骤* for the exact
  `gh api` commands that switch `main` to 1 required approval while keeping `enforce_admins` on.
