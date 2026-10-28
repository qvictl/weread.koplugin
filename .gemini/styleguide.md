# Review style guide — qvictl/weread.koplugin

Used by Gemini Code Assist (second-opinion reviewer). CodeRabbit, the primary
reviewer, has the same priorities in `.coderabbit.yaml`. The merge policy is in
`REVIEW_POLICY.md`.

## Language

- Write the PR summary in Simplified Chinese (简体中文). Inline review comments
  may be in English when that is more precise.
- Be direct: cite the file and line, say what breaks and on which device, and
  propose a fix. Mark real defects as **HIGH** / **CRITICAL** so they are not
  lost among style remarks; keep style nits to a minimum.
- Every comment that reports a potential bug must be either fixed or answered
  with a justification before the thread is resolved (see `REVIEW_POLICY.md`).

## Context

KOReader runs on e-ink devices down to Kindles with **512 MB RAM** shared with
the vendor framework, in a **single-threaded event loop** (`UIManager`).
Releases reach devices through auto-update, so a merged bug ships to readers.

## Priorities (in order)

1. **Memory on 512 MB Kindles.** Unbounded tables, caches or queues; whole-file
   or whole-response reads where streaming or a limit is possible; string
   building with `..` in loops (use `table.concat`); references kept to closed
   documents, widgets or BlitBuffers; BlitBuffers / images not freed. Ask for a
   bound or an eviction rule.
2. **Never block the UI thread.** Event handlers (`onXxx`), menu callbacks,
   `paintTo` and `UIManager:scheduleIn` callbacks must not do synchronous
   network I/O, DNS resolution (`socket.dns.toip` can block for the whole
   resolver timeout on Kindle), large disk I/O, heavy SQLite queries,
   `os.execute` or `io.popen`. Expect a subprocess
   (`Trapper:dismissableRunInSubprocess`, `util.runInSubProcess`) or chunked
   scheduled work.
3. **Subprocess / fork safety.** After `fork` the child must not touch the UI,
   framebuffer, input or SDL, flush settings, or reuse the parent's SQLite
   connections, and must exit the way the codebase does. The parent must reap
   children, bound and validate what it reads from pipes, and cope with a child
   that never starts or dies early.
4. **Suspend / resume lifecycle.** `onSuspend`, `onResume`, `onCloseDocument`,
   `onCloseWidget` and `onFlushSettings` must cancel timers
   (`UIManager:unschedule`), stop workers and release resources. After resume
   Wi-Fi may be off and the clock may jump.
5. **Lua pitfalls.** Accidental globals (missing `local`); nil dereference of
   optional fields and API / JSON data; Lua patterns built from data without
   escaping magic characters or without `plain = true` in `string.find`; `#`
   on tables with holes; `pcall` swallowing errors; shadowing `_` (gettext).
6. **KOReader widget lifecycle.** `dimen` computed before `paintTo` /
   `setDirty`; correct `setDirty` widget and region; resources freed in
   `onCloseWidget`; no painting after close, no widget shown twice.
7. **Tests vs the coverage policy** (`CONTRIBUTING.md`). Code changes need
   tests under `spec/`; a bug fix needs a regression test that fails without
   the fix; a user-visible change needs an emulator integration scenario;
   changed lines must meet the diff-coverage gates (unit ≥ 80%, unit +
   integration ≥ 90%). Flag tests that assert nothing or only exercise mocks.
8. **Sensitive paths need a human.** CI workflows, `.ci/`, policy files
   (`REVIEW_POLICY.md`, `CONTRIBUTING.md`, `.coderabbit.yaml`, `.gemini/`),
   release and version tooling, updaters and credential code. In workflows
   flag `pull_request_target` / `workflow_run` jobs that run PR code, secrets
   reachable from untrusted code, `${{ github.event.* }}` interpolated into
   `run:`, broadened `permissions:` and anything that would let a PR approve or
   merge itself.

## weread.koplugin specifics

- **Secrets and privacy.** Cookies (`wr_skey`, `wr_vid`, `wr_rt` …),
  `x-wrpa-*` headers, Bearer tokens, API keys, account ids, QR-login state and
  private book content must never be logged, committed, shown in errors or
  crash logs, or sent to hosts other than WeRead's. Use
  `require("weread.lib.logger")`, never KOReader's `logger` directly.
- **i18n.** Every user-visible string goes through `_()` and gets a Simplified
  Chinese translation in `weread/lib/i18n.lua`; use `T(_("… %1"), value)`
  instead of concatenating translated fragments; loop variables are `_i`, not
  `_`; menu changes update `weread/ui/menu.lua`, `weread/lib/i18n.lua` and the
  README menu tree together and leave no unused keys.
- **Namespace.** Project modules live in `weread/lib/` (non-UI) and
  `weread/ui/` (UI) and are required as `weread.lib.*` / `weread.ui.*`.
- **Storage.** `settings/weread.lua` holds only small bounded configuration;
  growing collections belong in the plugin's SQLite databases with migrations.
- `UIManager:scheduleIn(0)` blocks the event loop; use ≥ 0.1 s.
- Non-public WeRead APIs need a reproducible Python script in `scripts/` first.
- The in-app updater (`weread/lib/updater.lua`, `weread/ui/updater.lua`) and
  the version in `_meta.lua` / `main.lua` / `CHANGELOG.md` decide what reaches
  devices: always a human decision.
