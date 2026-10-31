# Resource archive image identities (2026-10-31)

## Reproduction and scope

Fork main `206f29b` correctly assigns unique output filenames to images from
different archive directories, but its source map keeps only the basename and
the generated output name. Extracting `img/pic.png` and `other/pic.png`, with
different bytes, stores both images and then rewrites both XHTML references to
the second image. The same source-map logic is used by in-memory TAR, streamed
TAR and ZIP extraction.

This is independent of the filename allocation/performance fixes in fork #62
and upstream #219. Existing tests checked distinct files but explicitly expected
the last basename to win; they did not check that the original XHTML references
still selected their own files. Upstream #38 was an investigation lead, not a
confirmed reproduction: its original book/input is unavailable here. This fix
does not claim to resolve that report or all missing-image cases.

## Narrow change

- Keep original archive paths separately from basename fallback, resolving an
  exact source path first. Normalize a leading `./` on either side.
- Keep the existing query/fragment stripping and `&amp;` decoding for XHTML
  sources. Existing callers supplying flat maps remain supported.
- Permit basename fallback only when it identifies one image. An ambiguous
  unmatched source is left unchanged rather than silently pointing elsewhere.
- Do not treat generated filenames as original source names: a collision suffix
  such as `pic-2.png` may itself be a different real archive source.

Filename allocation, stored image bytes, remote request behavior, extraction
limits, rollback and checkpoint formats are unchanged. The map is consumed
immediately when rewriting a chapter; it is not persisted. This does not infer
relative paths from an unknown chapter directory or guess among ambiguous
sources.

## Evidence

- The initial two-image unit regression fails on baseline with `distinct archive
  paths were aliased to the last basename match`.
- `content_chapter_fetch_spec`: 220 checks pass, including all three extractors,
  exact and ambiguous names, unique fallback, dot/query/fragment paths and
  root/nested/generated-suffix collisions in both archive orders.
- `download_disk_assets_spec`: 21 checks pass, including bounded retained memory
  and ordinary unique TAR/ZIP source references.
- Independently reverting each of the three extractor implementations, while
  keeping the new rewrite function and tests, fails its corresponding source
  identity regression. The fix is required in all three paths.
- All 147 Lua specs pass. Changed-file LuaCheck has zero warnings/errors.
- Unit diff coverage is 100% (18/18 executable changed lines), collected from
  all 77 affected specs with zero failures under normal LuaCov 0.17.0. The
  repository's unchanged 80% threshold passes; partial selection is not an
  overall-plugin coverage measurement.
- Real fork `v2026.10.q1_emulator`, scenario 16, passes in 1.9s. Actual Client
  downloads synthetic resources from the local mock; actual streaming TAR and
  filesystem operations preserve all 512 distinct image payloads and verify
  that each original source path selects its own output. Existing truncation,
  rollback, retry, worker-state serialization and cover-name checks still pass.
- Independent real negative control uses the same scenario with baseline
  production code. It fails in 1.9s at the first source reference:
  `directory-1/existing.png` is rewritten to `existing-515.png`, not the expected
  `existing-4.png`. Physical image extraction itself still succeeds.
- Namespace, secret scan, Python compilation, 16 mock-service contract tests,
  release-package validation, test-policy and whitespace checks pass.

No real account, private book, external WeRead request, paid review, release or
reader installation was used. ZIP identity coverage here is unit/component
coverage with an archive-reader fake; the real-runtime archive case is TAR.
