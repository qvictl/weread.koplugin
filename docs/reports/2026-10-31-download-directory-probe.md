# Non-destructive download-directory validation (2026-10-31)

## Reproduction

On merged main `573f9cb`, choosing a download directory calls
`validateDownloadDir`, which opens the fixed name `.weread_write_test` in mode
`w` and then deletes it. If that name is already a regular file, the validation
silently truncates and deletes unrelated data while reporting success. Both a
component regression and the actual fork emulator reproduce this behavior
using a synthetic pre-existing file in a temporary selected directory.

This is independent of downloading content, network protocols and archive
image decoding. No real user files or account data were used.

## Ownership and failure behavior

The validator now uses [LuaFileSystem's directory creation API](https://lunarmodules.github.io/luafilesystem/manual.html)
to claim a new scratch directory before opening its probe file. Existing files,
directories and symbolic links are never reused or cleaned. The creation itself
must succeed; a preliminary existence check is not used as proof of ownership.
The probe is opened only inside that newly created directory, and only those
new objects are removed afterward.

At most 16 candidate names are tried. A non-collision creation failure stops
immediately; exhausting all names fails conservatively without modifying any
of them. Failed file opening, closing, removal or directory cleanup is not
reported as successful validation. Stale candidates are not reclaimed because
they might contain user data. The existing directory-creation behavior, literal
shell quoting and translated error messages remain unchanged.

## Validation

- The final component regression fails on baseline main because the existing
  file disappears. Fixed `cache_ui_download_dir_spec.lua`: 92 checks.
- Cases cover regular files, existing scratch directories with user data,
  symbolic-link candidates, bounded collision exhaustion, open/close/removal
  failures, read-only and missing directories, and a file supplied as the
  directory. The in-memory filesystem gains an exclusive `lfs.mkdir` model.
- All 147 normal Lua specs pass. Changed-file LuaCheck has zero warnings/errors;
  namespace, secret scan, package verification and whitespace checks pass.
- Updated real scenario `17_literal_cache_directories.lua` passes on fork
  `v2026.10.q1_emulator` in 1.9 seconds. It keeps the existing real-filesystem
  catalog/EPUB checks and adds pre-existing regular files, a populated folder,
  a dangling symbolic link, repeated validation, exact byte preservation and
  successful probe cleanup. Baseline production fails the same scenario on
  the preservation assertion.

These are synthetic component and emulator results, not physical Kindle or
removable-media validation. Normal required CI, coverage and AI review remain
mandatory. There is no release, version bump, policy waiver or upstream write.
