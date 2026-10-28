# 审查与合并策略 / Review policy

本文件规定 qvictl/weread.koplugin 的 PR 如何审查、何时自动批准并合并。测试与覆盖率要求见 [CONTRIBUTING.md](CONTRIBUTING.md)；
网关逻辑在 [`.github/review-gate/`](.github/review-gate/)，工作流是
[`.github/workflows/review-gate.yml`](.github/workflows/review-gate.yml)。

**原则（所有者决定，2026-10-28）：不设人工审查关卡。** agent 认为可以就可以；出了回归就快速向前修复，迭代速度优先。
硬性条件只有下面四项，全部由 CI、AI 审查和审查对话保证。发布、版本号、CI 和策略文件的改动也走同样的流程。

## 审查者

| 审查者 | 角色 | 配置 |
|---|---|---|
| [CodeRabbit](https://github.com/apps/coderabbitai) | 主审查。每次推送增量审查；有阻断性问题时 **Request changes**，问题解决且最新提交审查通过后自动 **Approve**（这个批准可以满足 `main` 的“需要 1 个批准”） | [`.coderabbit.yaml`](.coderabbit.yaml) |
| [Gemini Code Assist](https://github.com/apps/gemini-code-assist) | 第二意见。PR 打开时审查；之后的推送评论 `/gemini review` 请它重新审查 | [`.gemini/config.yaml`](.gemini/config.yaml)、[`.gemini/styleguide.md`](.gemini/styleguide.md) |

两个 AI 审查者的重点相同：512 MB Kindle 上的内存占用；绝不阻塞 UI 线程（事件处理里的网络、磁盘、DNS）；
子进程 / fork 安全；休眠 / 唤醒生命周期；Lua 陷阱（全局变量、nil 解引用、模式字符串转义）；KOReader 控件生命周期
（paint 前先有 `dimen`）；测试是否满足覆盖率策略；WeRead 的密钥 / 隐私和 i18n 规则。摘要用简体中文，行内评论可以是英文。

## 处理审查意见

- AI 标为 **潜在问题 / bug** 的评论（CodeRabbit 的 “Potential issue”、Gemini 的 HIGH / CRITICAL）：修复，或在对话里写明
  理由（为什么不是问题、为什么不在本 PR 修），然后 agent 自己把对话标为已解决。不回复就 Resolve 不行。
- 其他建议（Nitpick、Refactor suggestion、MEDIUM / LOW）：采纳，或简短说明后解决。
- 需要 AI 重新审查最新提交时，评论 `@coderabbitai review` 或 `/gemini review`。

## 自动批准与自动合并的条件

网关（github-actions[bot]）在下面 **全部** 条件对 PR 的最新提交（head SHA）成立时批准，并开启自动合并
（squash，上游同步分支 `sync/upstream-*` 用 merge commit，保留与上游共享的历史）：

1. **必需检查全部成功**：`main` 分支保护要求的检查（网关运行时从分支保护读取；撰写本文时为 `ci`、`integration`、`tests-policy`，
   包括测试策略和覆盖率门禁）都成功（`success` / `neutral` / `skipped`）。排队或重跑中的检查算未完成。
2. **AI 审查已完成且没有 Request changes**：至少一个 AI 审查者（`coderabbitai[bot]` 或 `gemini-code-assist[bot]`）
   审查过 head SHA——提交了 `commit_id` 等于 head 的审查，或者（CodeRabbit 没有意见时不发 review）`coderabbitai` 应用在
   该提交上最新的 `CodeRabbit` 检查已完成、结论为 success 且为 “Review completed”；并且每个 AI 审查者最新的结论性审查
   （Approve / Request changes）都不是 **Request changes**。
3. **没有未解决的审查对话**（过时的对话也算）。
4. **非草稿，没有 `do-not-merge` 标签。**

只要有一项不满足，网关就不批准；如果它之前批准过，会**撤销自己的批准**，并关闭它自己开启的自动合并。出现硬性问题
（检查失败、Request changes、未解决对话、草稿 / `do-not-merge`）时，它还会撤销机器人（CodeRabbit 等）的批准；
检查只是还在运行时不撤销。

`do-not-merge` 是唯一的人工刹车：任何有打标签权限的人都可以加，网关见到即不批准。

## 上游同步 PR

*Upstream sync* 的 `sync/upstream-<date>` PR 合并时用 **merge commit**。配置了 `SYNC_TOKEN`（所有者的 PAT）后同步 PR 以所有者
身份创建，和其他 PR 一样由网关处理；没有 `SYNC_TOKEN` 时 PR 由 `github-actions[bot]` 创建，GitHub 不允许它批准自己的 PR，
这时 CodeRabbit 的自动批准或所有者的批准可以满足 `main` 的批准要求，网关仍会在条件满足时开启自动合并。

## 安全说明

- 网关的所有运行都使用默认分支上的工作流和脚本（`pull_request_target`、`workflow_run`、`check_suite`、定时任务；手动运行
  只允许在默认分支上）；审查事件由没有任何权限、不检出代码的 `review-gate-relay.yml` 转发。网关从不检出或执行 PR 的代码。
- 自动合并使用 `REVIEW_GATE_MERGE_TOKEN`（所有者的 fine-grained PAT），只存放在 environment `review-gate`（只允许 `main`
  部署）中，只有 `automerge` 作业读得到。用 `GITHUB_TOKEN` 合并不会触发 `main` 上的 push 工作流（覆盖率基线、nightly），
  所以不用它合并。PR 已经可以立即合并时（GitHub 拒绝为 clean / unstable 状态的 PR 开启自动合并），网关直接合并并固定到
  评估过的 head SHA。
- 写权限是信任边界：有写权限的人可以在自己的分支上新增工作流，以 github-actions[bot] 身份批准 PR 或伪造网关的评论。
  网关每次运行都会撤销不带网关标记的 github-actions 批准；fork 来的 PR 只拿到只读 token。

## 网关如何运行

- 触发：PR 事件（`pull_request_target`）、审查与审查评论（经 `review-gate-relay.yml` 转发）、必需检查所在工作流完成（`workflow_run`）、
  第三方 check suite 完成，以及每 15 分钟一次的定时兜底（GitHub Actions 没有“对话已解决”的触发器）。也可以在 Actions 页面
  手动运行 *Review gate*（填 PR 号，或留空评估全部）。
- 定时任务每个打开的 PR 只读一次评论列表；只有 head 变了、只被 AI 审查或对话阻塞、或已批准的 PR 才完整评估，其余 PR 在每天
  UTC 00/06/12/18 点的第一个定时运行中刷新。
- 每个 PR 一条置顶评论（以 `<!-- review-gate -->` 开头）列出各项条件；内容不变时不编辑。
- 只评估目标分支为 `main` 的打开的 PR。
- 仓库变量 `REVIEW_GATE_DRY_RUN=true`：只报告，不批准、不撤销、不合并。`REVIEW_GATE_AUTOMERGE=on`：merge token 已配置。
- 单元测试：`python3 -m unittest discover -s .github/review-gate -v`（工作流 `review-gate-tests.yml`）。

## 启用步骤

需要仓库 admin 权限（本机：`export GH_CONFIG_DIR=/home/qcraft/.config/gh`）。

```sh
R=qvictl/weread.koplugin

# 1. Actions 可以批准 PR；允许自动合并
gh api -X PUT repos/$R/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
gh api -X PATCH repos/$R -F allow_auto_merge=true

# 2. merge token 只放进 environment `review-gate`（只允许 main 部署），再打开开关
echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' | gh api -X PUT repos/$R/environments/review-gate --input -
gh api -X POST repos/$R/environments/review-gate/deployment-branch-policies -f name=main -f type=branch
gh secret set REVIEW_GATE_MERGE_TOKEN -R $R --env review-gate < /path/to/pat
( set -euo pipefail
  vars=$(gh api --paginate repos/$R/actions/variables --jq '.variables[].name')
  if grep -qx REVIEW_GATE_AUTOMERGE <<<"$vars"; then
    gh api -X PATCH repos/$R/actions/variables/REVIEW_GATE_AUTOMERGE -f value=on
  else
    gh api -X POST repos/$R/actions/variables -f name=REVIEW_GATE_AUTOMERGE -f value=on
  fi )

# 3. main 需要 1 个批准；新提交使旧批准失效；管理员同样受约束
gh api -X PATCH repos/$R/branches/main/protection/required_pull_request_reviews \
  -F required_approving_review_count=1 -F dismiss_stale_reviews=true \
  -F require_code_owner_reviews=false -F require_last_push_approval=false
gh api -X POST repos/$R/branches/main/protection/enforce_admins
gh api repos/$R/branches/main/protection --jq '{approvals: .required_pull_request_reviews.required_approving_review_count,
  dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews, enforce_admins: .enforce_admins.enabled,
  checks: .required_status_checks.contexts}'
```

紧急停用（网关或 AI 应用出问题）。按顺序：网关改为只报告 → 取消排队 / 运行中的网关运行并等它们真正结束（取消返回 409
表示已经结束，跳过）→ 再关闭所有打开 PR 的自动合并 → 核验没有剩余运行和自动合并。子 shell 中任何一步失败都会中止；
`do-not-merge` 可以单独拦住某个 PR。

```sh
( set -euo pipefail
  vars=$(gh api --paginate repos/$R/actions/variables --jq '.variables[].name')
  if grep -qx REVIEW_GATE_DRY_RUN <<<"$vars"; then
    gh api -X PATCH repos/$R/actions/variables/REVIEW_GATE_DRY_RUN -f value=true
  else
    gh api -X POST repos/$R/actions/variables -f name=REVIEW_GATE_DRY_RUN -f value=true
  fi
  active() {
    for st in queued in_progress waiting pending requested; do
      gh api --paginate "repos/$R/actions/workflows/review-gate.yml/runs?status=$st&per_page=100" --jq '.workflow_runs[].id'
    done
  }
  ids=$(active)
  for id in $ids; do
    if ! gh api -X POST repos/$R/actions/runs/$id/cancel >/dev/null 2>&1; then
      st=$(gh api repos/$R/actions/runs/$id --jq .status)   # 409: already finished
      [ "$st" = completed ] || { echo "cannot cancel run $id ($st)" >&2; exit 1; }
    fi
  done
  for i in $(seq 1 20); do left=$(active); [ -z "$left" ] && break; sleep 15; done
  if [ -n "$left" ]; then echo "review gate runs still active: $left" >&2; exit 1; fi
  ids=$(gh api --paginate "repos/$R/pulls?state=open&per_page=100" --jq '.[] | select(.auto_merge != null) | .node_id')
  for id in $ids; do
    gh api graphql -f query='mutation($id:ID!){disablePullRequestAutoMerge(input:{pullRequestId:$id}){clientMutationId}}' -f id=$id >/dev/null
  done
  left=$(gh api --paginate "repos/$R/pulls?state=open&per_page=100" --jq '.[] | select(.auto_merge != null) | .number')
  if [ -n "$left" ]; then echo "auto-merge still enabled on: $left" >&2; exit 1; fi
  echo "review gate stopped" )
```

只有在上面的块成功结束、并且确实需要不经批准合并时，才单独执行：

```sh
gh api -X PATCH repos/$R/branches/main/protection/required_pull_request_reviews   -F required_approving_review_count=0 -F dismiss_stale_reviews=false   -F require_code_owner_reviews=false -F require_last_push_approval=false
```

---

## English summary

- **No human gate** (owner decision, 2026-10-28): if the agent and the AI review think it is fine, it merges; regressions
  are fixed forward. Releases, version bumps, CI and policy changes follow the same flow.
- **Reviewers:** CodeRabbit (primary; requests changes for blocking findings and auto-approves once resolved — its
  approval may satisfy the required approval) and Gemini Code Assist (second opinion; `/gemini review` after new pushes).
- **Review comments:** potential issues / bugs are fixed or answered with a justification; then the agent resolves the
  thread.
- **The gate approves and enables auto-merge (squash)** when, on the head SHA: (1) all required checks passed
  (coverage gates included); (2) an AI reviewer reviewed the head commit and none's latest decisive review requests
  changes; (3) no unresolved review thread; (4) not draft, no `do-not-merge`. It dismisses its own approval when a
  condition stops holding, and bot approvals on hard failures.
- **Auto-merge** uses the owner's PAT from environment `review-gate` (main only); a PR that is already mergeable is
  merged directly at the evaluated head SHA.
