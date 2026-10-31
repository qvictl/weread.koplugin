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
that response for the existing `missing_body` diagnostics if all candidates
fail. The first usable body still terminates the search immediately.

No endpoint, payload, headers, authentication/renewal condition, public-source
fallback condition, retry count, or HTML parsing behavior changes. In particular,
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
