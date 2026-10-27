# Contributing / 贡献指南

Thanks for your interest in WeRead KOReader Plugin.

感谢你愿意参与 WeRead KOReader Plugin。为了让 issue 和 PR 更容易被处理，请遵循下面的规则。

## This fork / 关于本分支

`qvictl/weread.koplugin` is a maintained fork of
[finlater/weread.koplugin](https://github.com/finlater/weread.koplugin) with
stability fixes for memory-constrained devices. Branches:

- `main` - this fork's release line (default branch, protected). Releases and
  the in-app updater come from here.
- `upstream` - a read-only mirror of `finlater/main`, fast-forwarded weekly by
  the *Upstream sync* workflow, which also opens a `sync/upstream-<date>` PR
  into `main` (or an "Upstream sync conflict" issue). Run it manually with
  `upstream_ref` to merge up to a specific upstream commit, e.g. the part
  before a conflict.

Pull requests are welcome whether written by people or by AI. We gate on
tests, not on who wrote the code. A PR can be merged only when all required
checks pass:

- `ci` - Lua lint (luacheck), namespace policy, unit/component specs, Python
  scripts, mock-service contract, package and changelog checks, secret scan;
- `integration` - the plugin running inside a real headless KOReader
  emulator against the local mock WeRead service
  (`spec/emulator/scenarios/`), plus the pinned KOReader PluginLoader test;
- `tests-policy` - the test rule and the coverage gates below.

Test rule: Lua code changes under `main.lua`, `weread/` or `integrations/`
must come with changes under `spec/`, and every user-visible feature or fix
(PR title `feat...` / `fix...`) must add or update at least one emulator
scenario in `spec/emulator/scenarios/` (name it in the PR description). Bug
fixes need a regression test that fails without the fix. Only a maintainer
can waive this with the `no-tests-needed` label, and only for docs, comments
or log wording.

### Coverage policy / 覆盖率策略

Configured in [`.ci/coverage-policy.json`](.ci/coverage-policy.json) and
enforced by `tests-policy` on every PR to `main`. Scope: the whole plugin
(`main.lua`, `weread/`, `integrations/`; never `spec/`, `scripts/` or
fixtures). Plugin files no test loads count as 0%.

| Gate | Rule | Blocking |
| --- | --- | --- |
| Diff, unit | changed executable Lua lines covered by unit specs ≥ 80% | yes (waived by `no-tests-needed`) |
| Diff, combined | changed lines covered by unit specs + emulator scenarios ≥ 90% | yes (waived by `no-tests-needed`) |
| Ratchet | overall unit and overall combined coverage must not drop below `main`'s latest value (0.1 pp tolerance: emulator runs vary by a few timing-dependent lines, observed 0.03 pp) | yes |
| Target 4 weeks | overall combined ≥ max(75%, day-one baseline 80.78%) from 2026-11-24 | report-only before the date, then yes |
| Target 8 weeks | overall combined ≥ 85% from 2026-12-22 | report-only before the date, then yes |

Emulator coverage is measured with LuaCov inside the real KOReader app while
the scenarios run (forked download/login workers included). Every PR gets
the full table (diff unit, diff combined, overall, ratchet, targets, trend)
in the job summary and as a sticky comment. After each green `Integration`
run on `main`, the *Coverage* workflow publishes `baseline.json`,
`history.jsonl` and the README badge on the
[`coverage` branch](https://github.com/qvictl/weread.koplugin/tree/coverage).
Day-one baseline (2026-10-27): unit 73.80%, unit + emulator 80.78%.

覆盖率策略见 `.ci/coverage-policy.json`，由 `tests-policy` 在每个合入 `main` 的 PR
上强制执行：改动的可执行 Lua 行单元测试覆盖率 ≥ 80%，单元测试 + 模拟器场景合计 ≥ 90%；
整体覆盖率（单元、合计）不得低于 `main` 当前值；合计整体覆盖率在 2026-11-24 起
≥ max(75%, 首日基线 80.78%)，2026-12-22 起 ≥ 85%，到期前仅报告。每个 PR 的摘要和评论
都会列出各项结果，`main` 的历史趋势与徽章发布在 `coverage` 分支。

See [docs/testing.md](docs/testing.md).

本仓库是 finlater/weread.koplugin 的维护分支：`main` 为本分支发布线（默认、受保护），
`upstream` 为上游 `finlater/main` 的只读镜像，每周自动同步并向 `main` 发起合并 PR。

欢迎任何 PR，无论由人还是由 AI 编写；我们以测试而非作者身份把关。合并前必须通过
`ci`、`integration`（真实 KOReader 模拟器 + 本地 mock 服务的集成场景，以及固定版本
PluginLoader 测试）和 `tests-policy`（修改 Lua 代码必须同时修改 `spec/` 下的测试，`feat`/`fix`
类 PR 必须新增或更新至少一个模拟器场景，并满足下面的覆盖率门禁；仅维护者可用
`no-tests-needed` 标签豁免，且仅限文档、注释或日志措辞改动）。Bug 修复需附带修复前会失败的
回归测试。

## Issues / 提交 Issue

Before opening an issue, please search existing issues and read the README first.

提交 issue 前，请先搜索已有 issue，并阅读 README。

### Bug reports / Bug 反馈

Bug reports must include:

- Clear reproduction steps, or screenshots/recording that clearly show how the problem happens.
- KOReader logs.
- Plugin version, such as release version, download date, or commit hash.
- KOReader version.
- Device model and OS.
- Expected behavior and actual behavior.

Bug 反馈必须包含：

- 清晰的复现步骤，或能清楚展示问题如何发生的截图/录屏。
- KOReader 日志。
- 插件版本号，例如 release 版本、下载时间或 commit hash。
- KOReader 版本号。
- 设备型号和系统。
- 期望行为和实际行为。

KOReader logs are usually stored as `crash.log` inside the KOReader directory:

- Kindle: `koreader/crash.log`
- Kobo: `.adds/koreader/crash.log`
- PocketBook: `applications/koreader/crash.log`
- Android: use `Menu -> Help -> Bug Report` in KOReader to export logs

KOReader 日志通常是 KOReader 目录下的 `crash.log`：

- Kindle: `koreader/crash.log`
- Kobo: `.adds/koreader/crash.log`
- PocketBook: `applications/koreader/crash.log`
- Android: 在 KOReader 中打开 `菜单 -> 帮助 -> Bug Report` 导出日志

If the issue only happens with a specific book, you may optionally provide:

- WeRead book link.
- Imported book format and details.
- A source book file, only if you have the right to share it publicly.

如果问题只在特定书籍上出现，可以选择提供：

- 微信读书书籍链接。
- 自己导入书籍的格式和特征。
- 书籍源文件，但前提是你有权公开分享它。

Do not publicly upload copyrighted, private, or sensitive book files.

请不要公开上传受版权保护、包含隐私或不方便分享的书籍源文件。

### Privacy / 隐私

Never include these in issues, logs, screenshots, or PRs:

- API keys, including `wrk-...`.
- Cookies, including `wr_skey`, `wr_rt`, `wr_vid`, `ptcz`.
- `x-wrpa-*` headers.
- Full cURL commands copied from browser developer tools.
- Account IDs, private notes, or private book content.

HTTP failure logs include the original response body for diagnostics. Review
and remove sensitive or private response content before sharing `crash.log`.

不要在 issue、日志、截图或 PR 中包含：

- API key，例如 `wrk-...`。
- Cookie，例如 `wr_skey`、`wr_rt`、`wr_vid`、`ptcz`。
- `x-wrpa-*` 请求头。
- 从浏览器开发者工具复制的完整 cURL。
- 账号信息、私人笔记或私人书籍内容。

HTTP 失败日志会记录服务端原始响应体。分享 `crash.log` 前必须先检查并删除其中的
敏感信息或私人内容。

## Pull Requests / 提交 PR

Please keep PRs focused. Large features should be discussed in an issue before implementation.

请让 PR 尽量聚焦。较大的功能建议先开 issue 讨论，再开始实现。

Every PR must describe what it fixes or adds.

每个 PR 都必须说明它解决了什么问题，或新增了什么特性。

### Bugfix PRs / Bug 修复 PR

Bugfix PRs must include at least one of:

- A linked issue, such as `Fixes #123`.
- Clear reproduction steps for the original bug.

Bug 修复 PR 必须至少提供以下其中一项：

- 关联 issue，例如 `Fixes #123`。
- 原 bug 的清晰复现步骤。

Also describe how you verified the fix.

同时请说明你如何验证修复有效。

### Feature PRs / 新功能 PR

Feature PRs must describe:

- What feature was added.
- What user problem or workflow it improves.
- Screenshots or screen recording if it changes UI, menus, dialogs, layout, or interaction.

新增功能 PR 必须说明：

- 新增了什么功能。
- 它改善了什么用户问题或使用流程。
- 如果涉及 UI、菜单、弹窗、排版或交互，需要提供截图或录屏。

### Project conventions / 项目约定

- Code, variable names, and commit messages should be in English.
- All project-owned Lua modules must live under the `weread/` namespace: non-UI code in `weread/lib/` using `require("weread.lib.<module>")`, and UI code in `weread/ui/` using `require("weread.ui.<module>")`.
- Do not add project-owned modules to root-level `lib/` or `ui/`, or load them through bare `lib.*` / `ui.*` module keys. KOReader-owned imports such as `require("ui/widget/menu")` are exempt.
- Use `require("weread.lib.logger")` for project logging. Do not require KOReader's `logger` directly or manually add a `[WeRead]` prefix.
- User-facing strings should use `_()` and be translated in `weread/lib/i18n.lua`.
- If menu items are added, removed, renamed, or moved, update `weread/ui/menu.lua` (or the owning feature UI module), `weread/lib/i18n.lua`, and the README menu tree together.
- When bumping the release version, keep `_meta.lua` and `main.lua` in sync and add the matching `## [X.Y.Z]` section to `CHANGELOG.md`.
- For non-public WeRead Web APIs, include a standalone reproducible Python verification script in `scripts/` before implementing it in Lua.
- Do not commit KOReader `settings/weread.lua`, generated EPUB/cache files, API keys, cookies, anti-abuse headers, or private book content.
- Keep `settings/weread.lua` limited to small, bounded configuration and critical state. Downloaded content, annotations, thoughts, catalogs, history, and other growing collections must use dedicated SQLite databases under the plugin data directory.

项目约定：

- 代码、变量名和 commit message 使用英文。
- 所有项目自有 Lua 模块必须位于 `weread/` 命名空间下：非 UI 代码放在 `weread/lib/`，并使用 `require("weread.lib.<module>")`；UI 代码放在 `weread/ui/`，并使用 `require("weread.ui.<module>")`。
- 不要在根目录新增项目自有的 `lib/` 或 `ui/` 模块，也不要使用裸 `lib.*` / `ui.*` 模块键。`require("ui/widget/menu")` 等 KOReader 自带依赖不受此限制。
- 项目日志统一使用 `require("weread.lib.logger")`，不要直接引用 KOReader 的 `logger`，也不要手动添加 `[WeRead]` 前缀。
- 用户可见文本需要使用 `_()`，并在 `weread/lib/i18n.lua` 中添加中文翻译。
- 如果新增、删除、重命名或移动菜单项，需要同时更新 `weread/ui/menu.lua`（或对应功能的 UI 模块）、`weread/lib/i18n.lua` 和 README 菜单结构。
- 发布版本升级时，需要同步修改 `_meta.lua` 和 `main.lua`，并在 `CHANGELOG.md` 中添加匹配的 `## [X.Y.Z]` 段落。
- 涉及非公开 WeRead Web API 时，必须先在 `scripts/` 中提交可独立运行、可复现的 Python 验证脚本，再实现 Lua 版本。
- 不要提交 KOReader 的 `settings/weread.lua`、生成的 EPUB/cache、API key、cookie、反滥用请求头或私人书籍内容。
- `settings/weread.lua` 只能保存少量、有明确大小上限的配置和关键状态。下载内容、划线、想法、目录、历史记录及其他会持续增长的数据集合，必须存入插件数据目录下相互隔离的 SQLite 数据库。

## Local checks / 本地检查

Before submitting a PR, run the relevant checks if possible:

```bash
bash scripts/run_lua_specs.sh
bash scripts/check_lua_namespace.sh        # needs a PCRE2-enabled ripgrep
luacheck main.lua _meta.lua weread integrations spec
python3 -m py_compile scripts/*.py
python3 scripts/test_mock_weread.py
bash scripts/package_release.sh /tmp/weread.koplugin-release-test.zip
bash scripts/check_secrets.sh              # needs a PCRE2-enabled ripgrep
# Linux x86_64: the emulator scenarios CI runs as the `integration` check
bash scripts/fetch_koreader_emulator.sh /tmp/koreader
python3 scripts/run_emulator_scenarios.py --koreader /tmp/koreader --out /tmp/weread-emulator
# unit diff coverage (LuaCov), the first gate of `tests-policy`
bash scripts/run_lua_coverage.sh && python3 scripts/coverage_tools.py diff coverage/unit.report.out --base origin/main
```

提交 PR 前，如果可以，请运行相关检查：

```bash
bash scripts/run_lua_specs.sh
bash scripts/check_lua_namespace.sh        # needs a PCRE2-enabled ripgrep
luacheck main.lua _meta.lua weread integrations spec
python3 -m py_compile scripts/*.py
python3 scripts/test_mock_weread.py
bash scripts/package_release.sh /tmp/weread.koplugin-release-test.zip
bash scripts/check_secrets.sh              # needs a PCRE2-enabled ripgrep
# Linux x86_64: the emulator scenarios CI runs as the `integration` check
bash scripts/fetch_koreader_emulator.sh /tmp/koreader
python3 scripts/run_emulator_scenarios.py --koreader /tmp/koreader --out /tmp/weread-emulator
# unit diff coverage (LuaCov), the first gate of `tests-policy`
bash scripts/run_lua_coverage.sh && python3 scripts/coverage_tools.py diff coverage/unit.report.out --base origin/main
```

See [docs/testing.md](docs/testing.md) for the test layers, required regression
coverage, and the pinned KOReader PluginLoader integration test.

测试分层、回归测试要求和固定 KOReader 版本的 PluginLoader 集成测试说明，见
[docs/testing.md](docs/testing.md)。

Release packaging, manual artifacts, and automatic version-based publishing
are documented in [docs/releasing.md](docs/releasing.md).

发布包结构、手动打包和基于版本号的自动发布流程，见
[docs/releasing.md](docs/releasing.md)。
