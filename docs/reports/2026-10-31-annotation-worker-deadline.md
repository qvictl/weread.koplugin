# Foreground annotation worker deadline (2026-10-31)

## Reproduction and scope

At fork main `206f29b`, `_runAnnotationNetwork` passes no deadline to the shared
subprocess adapter. That adapter intentionally defaults to `math.huge` because
some callers perform long multi-image or updater tasks. Foreground annotation
HTTP waits publish no progress. A stuck child, or a server that keeps the socket
idle timeout alive by slowly sending bytes, can therefore leave the annotation
progress dialog waiting indefinitely unless the reader explicitly cancels it.

This path differs from annotation prefetch, which already has a 180-second
worker timeout. The broader upstream persistence proposal was an investigation
lead, not a patch imported wholesale. No real account or remote API was used.

## Narrow change

Pass a **90-second monotonic worker deadline per foreground network operation**
using the existing adapter/BackgroundWorker. It starts at worker launch, not
while waiting for shared-process admission, and uses the existing suspend-aware
clock. No new watchdog, process-kill routine or HTTP retry layer is introduced.

A worker deadline failure pauses sync with its actual timeout reason. Saved
batches remain for a manual resume. It is not labeled as a failure to launch.
Intentional Pause/cancel, replaced jobs and account/session ownership checks keep
their existing behavior. The shared process slot remains reserved until waitpid
has collected the terminated child. Unrelated downloads and updater deadlines
are unchanged; this is not a deadline for an entire book or matching stage.

## Evidence

- Actual adapter + BackgroundWorker with a deterministic OS-runner fake: baseline
  leaves the child alive at 90 seconds; the fix does not fire at 89, terminates
  at 90, retains the reservation until exact reaping, and reports the timeout.
  Intentional cancellation still returns silently and also retains the slot
  until reaping. `subprocess_budget_spec`: 178 checks pass.
- Controller/SQLite regression times out after the first saved thought batch,
  preserves that batch, then resumes only the unfinished batch. Existing launch
  failure, manual cancellation, stale-session, partial-chapter and auth tests
  still pass. The annotation network component's 13 checks also pass.
- All 147 Lua specs pass. Changed-file LuaCheck has zero warnings/errors.
- Real fork `v2026.10.q1_emulator`, scenario 09: ten steps pass in 11.4s. The
  synthetic service holds a thought response while the test advances only the
  existing worker clock past the unchanged production deadline. The actual
  child terminates/reaps, its checkpoint remains, the prior completed source is
  not falsely replaced, and resume does not fetch saved underlines again.
- Independent real negative control keeps the same test but restores baseline
  production code: the first nine steps pass, then the dialog still has not
  paused five seconds after the synthetic clock crosses the deadline (13.1s
  total). Test-owned hooks and the held mock response are restored on failure.

The emulator test deliberately fast-forwards a controlled monotonic clock; it
is not a measurement of 90 wall-clock seconds or physical Kindle suspend. No
server protocol, real credentials or paid review was exercised.

Local unit diff coverage is 100% (5/5 changed executable lines), collected from
all 36 selected specs with zero failures under normal LuaCov 0.17.0 and the
unchanged 80% repository threshold. Package/archive validation also passes.

This candidate is based directly on main `206f29b`. Its publication validation
is independent of other unpublished candidates and makes no claim about their
review or merge eligibility.
