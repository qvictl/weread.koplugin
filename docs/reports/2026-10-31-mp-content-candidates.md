# MP article candidate selection (2026-10-31)

## Scope and evidence

The older [MP article failure report](https://github.com/finlater/weread.koplugin/issues/56)
records `candidate_count=2`, `attempts=1` and `missing_body`. The original
response is unavailable; this report does not claim to reproduce that exact
article or establish the cause of its large response.

Independent inspection at fork `4afb5d3` identifies a deterministic defect:
`Content.fetch_mp_article_html` stops at the first nonempty candidate response,
even if it contains no article body. A later existing review/original-id
candidate is therefore never tried, although it can contain the requested
article. A synthetic login/error-page-first response reproduces the failure.

## Minimal correction

Extract the body before declaring a candidate successful. Continue through the
existing de-duplicated candidate list when a nonempty page lacks a body. Keep
only its length/type for the existing `missing_body` diagnostics if all
candidates fail, releasing the failed HTML before the next request. The first usable body still terminates the search immediately.

No endpoint, payload, headers, authentication/renewal condition, public-source
fallback condition or retry count changes. Existing markup selectors and cleanup
remain; cleaned-empty bodies and blank HTML blocks are now explicitly rejected. In particular,
a bodyless response does not introduce a new cookie renewal attempt. Existing
article/image staging, cancellation, account isolation and publication remain
unchanged.

## Verification

- New `content_mp_articles_spec.lua` regression fails on the old production
  function with `Could not extract article body`; the fixed spec passes 60
  checks, including candidate order, usable later content, no added renewal,
  missing-body diagnostics and no failed publication file.
- Mock-service contract tests cover the new synthetic bodyless response; all
  16 tests pass. Only fixture data was added to the existing endpoint.
- Scenario `22_mp_download_responsiveness.lua` uses the actual worker and mock
  HTTP service: bodyless first response, valid original-id second response,
  exactly two content requests, no added renewal, published HTML/local image,
  and a responsive event loop. Existing cancellation, rename failure and
  account-switch checks still execute.
- Fork `v2026.10.q1_emulator`: fixed scenario passed all six steps in 11.2s and
  11.6s. Final maximum heartbeat gap was 118ms (budget 800ms).
- Real negative control reverted only `weread/lib/content.lua`: final step
  failed waiting for the downloaded article to open; the preceding five steps
  completed. Restoring the fix passed the same scenario again.
- An earlier negative attempt was interrupted by a full temporary filesystem;
  it is not counted as a behavior result. Later evidence lives in the workspace.

These are synthetic-account checks, not validation of a private real-world
article, physical Kindle, or the complete release-candidate integration matrix.
All upstream access was read-only. No credentials or private article contents
are included.

Review follow-up: script-only, style-only and whitespace-only bodies now return
no usable content after cleaning, rather than Lua's truthy empty string. All
69 MP unit checks and 16 mock tests pass. The real worker fixture now crosses
three existing candidates (missing body, cleaned-empty body, valid article),
with no added renewal. Six steps pass in 13.9s, maximum UI gap 177ms. Reverting
only this follow-up causes the final article-content assertion to fail after
an empty article is opened; restoring it recovers the valid final candidate.


## Additional review findings (inline and outside diff)

Both were reproduced independently rather than treating a clean inline-thread
list as complete review clearance:

- `<p> </p>`, `&nbsp;` sections and nested blank blocks survived extraction,
  then disappeared during publication. Candidate validation now reuses that
  exact existing cleanup, preserving image-only bodies.
- Retaining the preceding bodyless response across the next HTTP call increased
  live memory. Only diagnostic metadata remains; a generated 4 MiB response
  regression performs full GC at the next request (after warming LuaJIT's
  reusable string buffer), and verifies less than 1 MiB remains above baseline.
- MP HTML collection now has a fixed **8 MiB** cap, checked before accepting
  each chunk regardless of Content-Length. An over-limit response discards all
  partial chunks and raises; another existing candidate can still succeed.
  The wrapper delegates to `socketutil.table_sink`, preserving total-timeout
  enforcement. This does not cap unrelated endpoints or public-source fallback.

Validation of this follow-up:

- 83 MP content checks, 74 client transport checks, 70 client API checks and all
  16 mock contract tests pass. All 146 Lua specs on this pre-#72 branch passed;
  the combined-current-main suite has a separate 147-spec result.
- Unit negative controls reject the old blank-block behavior and old unbounded
  collection. Exact 8 MiB succeeds; 8 MiB + 1 fails, clears partial data, resets
  timeout state, and a subsequent request succeeds.
- Actual scenario 22 now traverses four candidates: missing body, script/blank
  blocks, oversized response with a superficially valid body, and valid article.
  All six steps pass in 14.9s; maximum UI heartbeat gap is 80ms (budget 800ms).
- Independent actual-emulator negative controls revert only blank-block checking
  (11.7s) or only the MP size limit (13.7s). Both open the wrong article and fail
  the published-content assertion; the other five scenario steps pass.

The 8 MiB threshold bounds collected HTML, not total process RSS; parsing still
makes bounded copies. This is not a physical 512 MiB Kindle memory benchmark.


Combined-source verification after the preceding fixes merged: current main
`206f29b` plus this candidate merges cleanly. All 147 Lua specs pass, and real
scenario 09 (nine steps, 7.1s) and scenario 22 (six steps, 15.2s, 111ms maximum
UI heartbeat gap) both pass. Changed-file LuaCheck 1.2.0, LuaJIT syntax,
namespace/secret checks, Python compile, test policy and package validation pass.

Local unit diff coverage is **100% (32/32 executable changed lines)** against
this PR's merge base; all 82 selected specs completed under LuaCov with zero
failures. This uses upstream LuaCov 0.17.0 (`645a984`) with its normal pure-Lua
hook and the unchanged repository configuration/80% threshold. The emulator's
older bundled C hook did not normalize `./` paths and produced empty per-spec
stats; that unsuccessful instrumentation run is not used as coverage evidence.
