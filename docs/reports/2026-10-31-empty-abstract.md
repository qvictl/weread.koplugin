# Whitespace-only popup abstracts (2026-10-31)

A review follow-up on the malformed-batch recovery change identified one
remaining shape: a string containing only spaces/tabs/newlines is not a useful
abstract, but Lua considers it truthy and the existing empty-string check accepts
it. It can therefore hide a useful `contextAbstract` in the first valid popup
thought. If both fields are whitespace, the popup should have no abstract.

The two validity checks now require at least one non-whitespace character.
Accepted text remains unchanged; content, author, matching, storage and network
behavior are not modified.

Evidence against merged baseline `3464e79`:

- Updated `annotation_payload_spec.lua` fails before the change and passes all
  71 checks afterward, including whitespace primary/context fallback and both
  fields unusable.
- The actual SQLite resume specification now persists a whitespace primary
  abstract with valid context text and verifies the reopened popup record.
- Real fork `v2026.10.q1_emulator` scenario 09 fails at its first saved-batch
  assertion without the production change. With the change, all eight steps
  pass in 5.8 seconds, retaining the context quote after SQLite recovery.

This is a narrowly scoped fix-forward: the previous malformed-batch change was
already merged automatically when the outside-diff review finding was inspected.
Its merge is not evidence that this whitespace case was fixed. This follow-up
keeps a manual merge hold until all latest-head review feedback, including
outside-diff findings, has been inspected. No real-account or physical-device
acceptance is claimed.
