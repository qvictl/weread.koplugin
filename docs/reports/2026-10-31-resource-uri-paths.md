# Percent-encoded archive image references (2026-10-31)

## Reproduction

On merged main `48de1af`, the image rewriter matches XHTML source references
against literal archive names without URI decoding. `first/pic.png%20` does
not select `first/pic.png `, and `chapter%20one/pic.png` does not distinguish
same-named images under directories containing spaces. These are missing or
incorrect-image failures, independent of parsing the TAR name/prefix fields.

## Compatibility boundary

The [URI specification, section 2.4](https://www.rfc-editor.org/rfc/rfc3986#section-2.4)
requires separating URI components before percent decoding and avoiding repeat
decoding. The rewriter now strips query/fragment text first, then decodes valid
escapes once on the reference side only. Archive keys retain their original
bytes. Consequently `%2520` identifies a literal `%20` filename, not a space;
`%3F` and `%23` identify filename bytes rather than new URI components. Plus
signs remain plus signs, not form-encoded spaces. UTF-8 is decoded bytewise.

Both structured source maps and legacy flat basename maps use this rule. Full
paths still take priority over unique basename fallback; an ambiguous basename
never chooses a different image. There is no raw-encoded fallback which could
silently substitute a literal-percent file for a missing decoded source.

For compatibility, malformed escapes retain the whole old literal path rather
than partially decoding it. Encoded slash and NUL references are left unchanged:
a slash inside a URI segment is not a path hierarchy separator, and neither
can be a literal archive filename component. Backslashes remain ordinary name
bytes at this matching boundary. Extraction still uses generated safe output
names; this function does not perform filesystem lookup or write operations.
This is not a general URI resolver, and does not add dot-segment resolution,
HTML parsing, external URL fetching, or archive format support.

## Validation

- Component regressions exercise both in-memory and streaming TAR readers,
  asserting the rewritten source selects the exact original image bytes. Cases
  include spaces in directories/names, UTF-8, `%25`/`%2520`, encoded reserved
  characters, literal/encoded plus, ampersands, malformed escapes, ambiguous
  basenames, unique fallback and legacy flat maps. Chapter-fetch: 321 checks.
- Baseline main fails the new component regression at the first encoded
  directory path; unchanged archive parsing alone cannot fix the reference.
- Python's standard USTAR writer builds an independent mock archive. The HTTP
  contract test uses Python tarfile to verify all 11 original names and bytes.
- Real fork `v2026.10.q1_emulator`, scenario
  `16_resource_archive_rollback.lua`, passes in 2.1 seconds. It downloads that
  archive through the actual client, runs both actual TAR readers, verifies
  every source/byte pair, and retains the rollback/retry and pre-existing-file
  preservation assertions. Baseline production fails the same real scenario
  on the first encoded source after the earlier archive assertions pass.
- All 147 normal Lua specs and 16 mock-service tests pass.

Fixtures are synthetic; no real account, private book, network endpoint change,
physical-device validation, release, version bump or policy waiver is involved.
