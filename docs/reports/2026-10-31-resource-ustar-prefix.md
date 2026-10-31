# USTAR image source paths (2026-10-31)

## Reproduction

Review of the archive source-identity fix raised a nonblocking USTAR concern.
It is reproducible on merged main `76914ee`: both TAR readers only used the
100-byte name field. Two entries with name `pic.png` and different USTAR
prefixes were therefore registered as the same source path. Their complete
XHTML paths did not select their own images; a bare `pic.png` could select the
last entry instead.

The [GNU TAR format reference](https://www.gnu.org/software/tar/manual/html_node/Standard.html)
defines the POSIX magic at byte offset 257 and the 155-byte prefix at offset 345.
The fix shares prefix/name decoding between both readers and recognizes only
the POSIX `ustar` plus NUL magic. Old GNU headers use that area for other
metadata and are not interpreted as POSIX prefixes. Prefix bytes, including
spaces and a full 155-byte non-NUL-terminated field, are preserved.

This changes source identity only. Extraction paths remain generated safe
basenames. Image bytes, filename allocation, archive limits, rollback and
network/API behavior are unchanged. PAX/GNU long-name extensions are not newly
supported by this change.

## Tests

- The new component regression fails on main at the first prefixed source;
  fixed chapter-fetch spec passes 231 checks, disk-assets spec passes 21.
- Cases cover both in-memory and streaming readers, colliding prefixes,
  unchanged ambiguous bare references, empty prefixes, 155-byte prefixes,
  100-byte names, significant prefix spaces, and old GNU magic.
- The mock fixture uses Python's standard `TarInfo.tobuf(USTAR_FORMAT)` writer.
  Its HTTP contract test verifies the actual name, magic and prefix bytes,
  then independently reads both full paths and payloads with Python tarfile.
- Real fork `v2026.10.q1_emulator`, updated scenario
  `16_resource_archive_rollback.lua`, passes in 2.0 seconds. Both actual TAR
  readers fetch the same synthetic archive through the real client and retain
  separate source paths and image bytes. Existing rollback/retry checks pass.
- Same real scenario with baseline production code fails in 1.8 seconds at
  USTAR streaming source selection after the prior rollback/identity checks.
- All 147 normal Lua specs pass. Python reports 120 tests passing with two
  existing platform skips. Changed-file LuaCheck reports no warnings/errors;
  namespace, secrets, Python syntax, package and whitespace checks pass.

These are synthetic fixtures, not real-account/private-book or physical-device
evidence. Ordinary PR CI, unit coverage and review gates still apply; no
release, version bump, protection change or gate waiver is part of this fix.
