# Testing / 测试

The project uses three test layers. None of them contacts a real WeRead
account, and fixtures must not contain API keys, cookies, account identifiers,
private notes, or book content.

项目使用三层测试。测试不得访问真实微信读书账号；fixture 中不得包含 API key、Cookie、
账号标识、私人笔记或书籍内容。

## 1. Fast checks / 快速检查

Run these before every PR:

```bash
bash scripts/run_lua_specs.sh
bash scripts/check_lua_namespace.sh
luacheck main.lua _meta.lua weread spec
python3 scripts/test_mock_weread.py
```

`run_lua_specs.sh` executes every top-level `spec/*_spec.lua` with LuaJIT.
These standalone tests stub KOReader services and cover pure logic, service
composition, state machines, migration behavior, and regressions.

`plugin_load_spec.lua` is the entry-point smoke test. It loads the real
`main.lua`, initializes the service graph with deterministic fakes, composes
the feature mixins, and verifies that legacy `lib.*` / `ui.*` module keys are
not touched.

`check_lua_namespace.sh` enforces the project module layout:

- non-UI modules belong in `weread/lib/`;
- UI modules belong in `weread/ui/`;
- project modules use `weread.lib.*` or `weread.ui.*`;
- root-level project `lib/` and `ui/` directories are forbidden.

KOReader-owned imports such as `require("ui/widget/menu")` remain valid.

## 2. Unit and component specs / 单元与组件测试

Add or update a regression test whenever behavior changes. Prefer dependency
injection and `package.preload` fakes over live network or UI automation.

High-risk areas that require focused coverage:

- HTTP redirect, timeout, cookie, and credential boundaries in
  `weread/lib/client.lua`;
- settings, authentication schema migrations, and split book storage;
- UTF-8 content decoding, HTML transformation, underlines, and thoughts;
- downloader cancellation, retry, completion callbacks, and standby guards;
- progress mapping and upload/download conflict decisions.

Every top-level spec must exit non-zero on failure and be deterministic when
run independently.

## 3. KOReader integration / KOReader 集成测试

The `Integration` workflow (`.github/workflows/integration.yml`) runs on every
PR, on pushes to `main`, weekly, and on demand (the upstream-sync workflow
also dispatches it for its PR branch). Two aggregate jobs are required status
checks for `main`, and `Release` publishes only after the whole workflow
succeeds on `main`:

| Required check | Jobs | KOReader |
| --- | --- | --- |
| `integration` | `Emulator · qvictl/koreader fork build (shard 1-3/3)` + `PluginLoader (pinned KOReader)` | the [qvictl/koreader](https://github.com/qvictl/koreader) fork's emulator build (release `nightly`), in the `koreader/kobase:5.0.0-22.04` container; LuaCov coverage for `tests-policy` |
| `integration-official` | `Emulator · official KOReader v2026.07.1 (shard 1-2/2)` | the official `koreader-linux-x86_64-v2026.07.1` release, which many devices still run; plain runner with SDL 2, no coverage |

`Integration` 工作流在每个 PR、`main` 推送、每周定时和手动触发时运行（upstream-sync 也会为
同步分支触发）。`integration`（qvictl/koreader 分支构建的模拟器场景，在
`koreader/kobase:5.0.0-22.04` 容器中运行，并采集覆盖率；以及固定版本 PluginLoader）和
`integration-official`（同一组场景在官方 KOReader v2026.07.1 上运行）都是 `main` 的必需检查。

### 3.1 Emulator scenarios / 模拟器场景

`scripts/run_emulator_scenarios.py` starts the real KOReader application
(`reader.lua`) headless (SDL dummy video driver; `--xvfb` uses `xvfb-run`)
once per scenario with:

- a fresh, isolated `KO_HOME` (never the user's profile);
- the candidate release package built by `scripts/package_release.sh`;
- the test-only driver plugin `spec/emulator/wereadtest.koplugin`, which runs
  one scenario from `spec/emulator/scenarios/` as a coroutine on the real
  UIManager loop (`spec/emulator/harness.lua`: steps, waits, real tap
  gestures, screenshots, metrics);
- its own `scripts/mock_weread.py` instance; the plugin runs in its built-in
  mock environment, so no real account, credential or WeRead/GitHub request
  is involved.

Current scenarios (`python3 scripts/run_emulator_scenarios.py --list`):

| Scenario | Covers |
| --- | --- |
| `01_plugin_load` | real start-up, PluginLoader, namespaced modules, isolated mock environment, menu entry |
| `02_qr_login` | logout, QR dialog + forked long poll, OTP (wrong then right code), expired QR saves nothing |
| `03_library` | shelf sync, 26 books over 3 pages (next/previous), groups, taps before first paint, book detail and 6-chapter list |
| `04_download` | download chapter and read; full-book download cancelled mid-way resumes without refetching completed chapters; valid EPUB |
| `05_memory_gate` | fake `/proc/meminfo` via the downloader's injectable reader: wait-then-recover, pause with checkpoint, resume |
| `06_network_loss` | link loss pauses (no fork busy loop, offline restart refused), server timeouts pause after 2 attempts, resume |
| `07_reader_progress_sync` | open the EPUB, page turns, conflict dialog dismissal uploads nothing, cloud never moves backwards |
| `08_read_report_suspend` | report timer stops on Suspend with zero network requests, re-arms on Resume and reports again |
| `09_annotations_thoughts` | annotation sync, underline drawn, tap opens the thought popup, popup paging and close |
| `10_updater` | updater against a mocked GitHub release: notes dialog, SHA-256 mismatch rejected, install with backup |
| `11_budget_200_chapters` | 200-chapter download: peak RSS growth, Lua heap growth, late/early per-chapter time, packaging and total time budgets |
| `12_harness_taps` | the harness itself: taps wait for a dialog's painted position, also when it was shown in the predicate's own UI tick |

Every scenario exits non-zero on failure. Evidence per scenario: `crash.log`
(KOReader output), `requests.jsonl` (mock requests), `result.json` (steps,
timings, metrics), screenshots; plus `summary.md` / `summary.json`. CI uploads
them as `emulator-evidence-shard-*` (fork build) and
`emulator-official-evidence-shard-*` (official build) artifacts and shows the
summary table on the run page.

KOReader builds (`scripts/fetch_koreader_emulator.sh`,
`KOREADER_EMULATOR_SOURCE=fork|official|auto`):

- `fork` (the `integration` check): the `qvictl/koreader` fork's rolling
  emulator build, release `nightly`, asset
  `koreader-emulator-x86_64-latest.tar.xz` (`KOREADER_FORK_RELEASE=v2026.10.q1`
  or the workflow's `fork_release` input selects a stable fork tag instead).
  The asset is checked against the release's `SHA256SUMS` and must pass a
  plugin-load probe (scenario 01); otherwise the script exits non-zero and the
  job fails - there is no fallback. The build links the system's SDL3, so it
  runs in KOReader's `koreader/kobase:5.0.0-22.04` image (or any Linux with
  SDL 3 installed). The job summary shows the fork version, commit and build
  date (`build-info.json`). The fork nightly is rebuilt daily when its `main`
  changes, so every run picks up the newest fork build.
- `official` (the `integration-official` check): the official
  `koreader-linux-x86_64-v2026.07.1.tar.xz`; needs SDL 2 (`libsdl2-2.0-0`).
- `auto` (default, local convenience only; CI never uses it): `fork` if it
  starts on this machine, otherwise `official` with a warning.

Run locally (Linux x86_64; macOS: use a Linux VM or container). The fork
build, as in CI:

```bash
docker run --rm -it -v "$PWD:/w" -w /w koreader/kobase:5.0.0-22.04 bash -c '
  KOREADER_EMULATOR_SOURCE=fork bash scripts/fetch_koreader_emulator.sh /tmp/koreader &&
  python3 scripts/run_emulator_scenarios.py --koreader /tmp/koreader/fork/extract \
      --out /tmp/weread-emulator [--scenario 04_download]'
```

The official build on the host (needs `libsdl2-2.0-0`, `zip`, `unzip`):

```bash
KOREADER_EMULATOR_SOURCE=official bash scripts/fetch_koreader_emulator.sh /tmp/koreader   # prints runtime=...
python3 scripts/run_emulator_scenarios.py --list
python3 scripts/run_emulator_scenarios.py --koreader /tmp/koreader/official/extract/lib/koreader \
    --out /tmp/weread-emulator [--scenario 04_download]
```

Writing a scenario: add `spec/emulator/scenarios/NN_name.lua` returning
`function(H) ... end` with `-- @title` and `-- @timeout` header lines. Drive
the plugin through `H.call` / `H.tap_exact` / `H.tap_text` (UI-loop context,
like a user event), assert with `H.check` / `H.wait_until`, record budgets with
`H.metric`. Extend `scripts/mock_weread.py` (and its contract test
`scripts/test_mock_weread.py`) instead of stubbing plugin code.

Tap through `H.tap_exact` / `H.tap_text`, never by reading a widget's `dimen`
and calling `H.tap_at`: a dialog shown earlier in the same UI tick is not
painted yet, and its Buttons' init-time `dimen` reads as `x = 0, y = 0`, so the
tap lands in the top-left corner and dismisses the dialog. The helpers repaint
pending windows, accept only a position `paintTo` stored, search the window
that actually receives the tap, and find and tap in one UI task. A
`wait_until` timeout (and the scenario watchdog) logs the window stack,
pending repaints, scheduled tasks and the downloader state, also stored as
`diagnostics` in `result.json`. To shake out such races, set
`WEREAD_TEST_POLL_INTERVAL=0` (poll every UI tick) and run scenarios
repeatedly, ideally under CPU contention (`docker run --cpus=1`, parallel runs).

新增场景：在 `spec/emulator/scenarios/` 添加返回 `function(H)` 的 Lua 文件，通过
`H.call`/`H.tap_exact`/`H.tap_text` 在 UI 循环中操作插件，用 `H.check`/`H.wait_until`
断言。需要新接口时扩展 mock 服务及其契约测试，不要替换被测插件代码。点击一律用
`H.tap_exact`/`H.tap_text`，不要自己读 `dimen` 再 `H.tap_at`：同一个 UI tick 里刚弹出的
对话框尚未绘制，按钮的 `dimen` 还是占位的 (0, 0)，点击会落在左上角并关掉对话框。
排查这类竞争可设置 `WEREAD_TEST_POLL_INTERVAL=0` 并在 CPU 争用下反复运行。

### 3.2 PluginLoader at the pinned KOReader commit / 固定版本 PluginLoader

The `plugin-loader` job uses KOReader's own Busted environment,
`commonrequire.lua`, and real `PluginLoader`. It verifies discovery and
loading against the pinned KOReader commit without initializing an account or
making a WeRead request. It runs inside KOReader's official
`koreader/kobase:1.0.0-22.04` build image; the KOReader build is cached.

To run it locally:

```bash
git clone https://github.com/koreader/koreader.git /path/to/koreader
git -C /path/to/koreader checkout 1e2fa5f1239028ab4b37acae833cdc86a71e5258
KOREADER_DIR=/path/to/koreader bash scripts/run_koreader_integration.sh
```

KOReader's test launcher requires Bash 4 or newer. The Bash 3.2 bundled with
macOS is not sufficient; install Homebrew Bash and ensure `bash` resolves to
that version before running the script.

The runner temporarily links this plugin into KOReader's `plugins/` directory,
copies the integration spec into KOReader's test tree, runs only that Busted
file, and removes both temporary entries on exit. It refuses to overwrite an
existing plugin or spec.

When updating the pinned KOReader commit, update all three locations together:

- `scripts/run_koreader_integration.sh`;
- `.github/workflows/integration.yml`;
- this document.

## 4. PR policy and coverage / PR 测试策略与覆盖率

The `PR policy` workflow's `tests-policy` job is a required check:

- **Test rule** (`scripts/check_test_policy.py`): a PR that changes Lua code
  in `main.lua`, `weread/` or `integrations/` must also change `spec/`; a
  user-visible feature or fix (PR title `feat...`/`fix...`) must add or
  update an emulator scenario. Waivers: `no-tests-needed` (maintainers;
  docs, comments or log wording only), `upstream-sync`.
- **Coverage gates** (`scripts/coverage_tools.py gate`, thresholds and dated
  targets in `.ci/coverage-policy.json`): unit diff coverage ≥ 80%, unit +
  emulator diff coverage ≥ 90%, overall unit and combined coverage not below
  `main`'s baseline, and dated targets (overall unit, overall combined, a
  per-file unit floor for `weread/lib/*`) that turn blocking on their date.
  See [CONTRIBUTING.md](../CONTRIBUTING.md#coverage-policy--覆盖率策略) and the
  roadmap in [coverage-plan.md](coverage-plan.md); the tooling itself is
  tested by `python3 scripts/test_coverage_tools.py`.

How coverage is measured:

- unit: `scripts/run_lua_coverage.sh` runs every `spec/*_spec.lua` under
  LuaCov (JIT off), merges per-spec stats and adds untested plugin files with
  zero hits;
- emulator: `scripts/run_emulator_scenarios.py --coverage` installs
  `spec/emulator/luacov_patch.lua` as an early KOReader userpatch, so LuaCov
  runs inside the real app from before plugin loading, including forked
  download/login workers (per-PID stats). `@no_coverage` scenarios (timing
  budgets) run without it. CI measures it on the fork build only and uploads
  `coverage-emulator-shard-*` (the official-build job collects no coverage);
- the gate waits for the PR's `Integration` run, merges both and reports diff
  unit, diff combined, overall, ratchet, targets and the trend on `main`.

Locally (LuaCov checkout on `LUA_PATH`):

```bash
export LUA_PATH="/path/to/luacov/src/?.lua;;"
bash scripts/run_lua_coverage.sh
python3 scripts/run_emulator_scenarios.py --koreader /tmp/koreader/fork/extract --out /tmp/emu \
    --coverage --luacov-src /path/to/luacov/src   # in kobase, as above
python3 scripts/coverage_tools.py merge --all-files --out coverage/combined.stats.out \
    coverage/unit.stats.out /tmp/emu/coverage/emulator.stats.out
python3 scripts/coverage_tools.py report coverage/combined.stats.out coverage/combined.report.out
python3 scripts/coverage_tools.py gate --unit coverage/unit.report.out \
    --combined coverage/combined.report.out --base origin/main
```

修改 Lua 代码的 PR 必须修改 `spec/`，`feat`/`fix` 类 PR 必须新增或更新模拟器场景；改动行
覆盖率单元 ≥ 80%、单元 + 模拟器 ≥ 90%，整体覆盖率不得低于 `main`，并按日期执行整体目标。

## Updater simulator regression / 更新弹窗模拟器回归

使用包含 `luajit` 和 `reader.lua` 的已构建 KOReader 运行目录，测试目录必须不存在：

```bash
python3 scripts/test_updater_simulator.py \
    --koreader /path/to/koreader-runtime --run-dir /tmp/weread-updater-test
```

测试会打包当前代码到隔离副本，在 HTTP 边界注入合成版本和更新包，保留真实控件、
子进程、校验、解压和安装流程。覆盖长说明滚动、固定按钮、提醒去重、设置落盘、
手动更新、校验失败与重试；截图和日志保存在 `evidence/`。不会更新日常使用的插件。
加 `--width 1072 --height 1448 --dpi 300` 可复测大屏；加 `--interactive` 会生成
`WeReadUpdateTest.app`，打开后可进行真实窗口点击测试。每次使用新的 `--run-dir`。

## Release UI acceptance / 发版前界面验收

Before every release, follow [macOS simulator release testing](macos-release-testing.md).
It defines isolated candidate-package setup, synthetic inputs, core and
change-dependent cases, ComputerUse steps, pass criteria, evidence, and the
remaining Kindle checks. This is a release acceptance procedure; the existing
PluginLoader runner does not execute that UI matrix automatically.

每次发版先按 [macOS 模拟器发版前测试](macos-release-testing.md) 执行并记录结果。
脚本替身测试、真实离屏渲染、ComputerUse 窗口操作与真实服务验证应分别报告；
不能将未执行或缺少夹具的场景标成通过。自动测试使用合成内容，不访问真实账号。

已有 [本地 WeRead mock 服务](mock-weread.md)，提供无第三方依赖的 HTTP 服务、
隔离候选包启动器和 `--smoke` 真实下载/渲染检查。基础服务契约进入普通 CI；
ComputerUse 操作流程与故障注入命令见该文档。
