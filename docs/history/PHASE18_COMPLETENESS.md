# Phase 18 completeness pass: incremental backup planning

Phase 18 adds an explicit incremental-planning layer without weakening the
previous ZIP, verification, extraction, symlink, ZIP64, ignore, or deterministic
metadata contracts.

## Implemented scope

- Added `Backup.Incremental` as a dedicated planning package.
- Added CLI support for:
  - `--incremental-from ARCHIVE.zip`
  - `--incremental-from=ARCHIVE.zip`
  - `--incremental-from-manifest FILE`
  - `--incremental-from-manifest=FILE`
- Enforced unsupported combinations:
  - incremental archive source and incremental manifest source are mutually
    exclusive;
  - incremental options are rejected with `--verify`;
  - incremental options are rejected with `--extract`;
  - incremental archive and manifest sources must exist and be ordinary files;
  - the output archive may not also be the incremental source.
- Incremental planning compares current scanned entries against trusted prior
  metadata using:
  - normalized archive path;
  - entry kind;
  - ZIP method number;
  - CRC32;
  - uncompressed size;
  - compressed size;
  - stored symlink target text.
- Planning decisions are explicit and deterministic:
  - `added`
  - `modified`
  - `removed`
  - `reused`
  - `skipped` for current ignore-rule exclusions and symlink skips that were reapplied during the current scan.
- Current ignore rules are still reapplied through the normal scanner before
  planning; previous manifests are not used to inherit ignore state.
- Compression policy is applied before planning, so unchanged entries are only
  reused when the current deterministic policy selects metadata compatible with
  the previous backup.
- Previous archives are trusted only after `Backup.Verify.Verify_Archive`
  returns `Verify_Ok`.
- Previous manifests are trusted only after format, path, method, duplicate-path,
  required-field, and string-unescaping checks pass.
- Prior manifest paths are revalidated with the Phase 2 archive-path model.
- Duplicate current or prior archive paths are rejected with explicit planning
  status.
- Dry-run output can now report the incremental plan directly.
- `--list-json` can now emit deterministic `backup-incremental-plan-v1` output
  with a summary and per-entry decisions.
- Normal archive creation remains a valid deterministic full archive. The Phase
  18 execution strategy is named `synthetic-full-archive`: planning records which
  payloads are reusable, while the existing writer emits a normal full ZIP
  result. This preserves Phase 8/9/13/14 ZIP correctness while leaving raw
  payload-copy optimization as an internal writer improvement.

## Completeness pass changes

- Added direct `with Backup.Scanner` and `with Backup.Zip` context clauses to
  the incremental body so it does not rely on visibility from the package spec.
- Replaced duplicated deflate-size prediction logic with a checked helper that
  mirrors the Phase 9 writer's deterministic stored-deflate-block accounting and
  rejects overflow.
- Made prior-manifest parsing less brittle:
  - accepts flexible whitespace after JSON keys;
  - handles escaped JSON strings for archive paths and symlink targets;
  - parses entry objects with nested objects and braces inside strings safely;
  - validates the manifest format field through the same string parser.
- Normalized JSON summary counts to decimal text without Ada image leading
  spaces.
- Added CLI guardrails for empty `--incremental-from=` and
  `--incremental-from-manifest=` values.
- Added validation that `--incremental-from-manifest` cannot name the output ZIP
  path.

## Added tests

- `backup_incremental_tests.adb`
  - unchanged stored file => `reused`;
  - unchanged deflated file => `reused`;
  - modified deflated file => `modified`;
  - new file => `added`;
  - missing previous file => `removed`;
  - manifest-based unchanged file => `reused`;
  - manifest-based symlink target change => `modified`;
  - escaped manifest symlink target => `reused`;
  - missing prior manifest rejection;
  - duplicate prior manifest archive-path rejection;
  - invalid prior manifest archive-path rejection;
  - duplicate current archive-path rejection;
  - deterministic JSON incremental-report marker and reused decision;
  - deterministic dry-run strategy marker.
- CLI tests for:
  - parsing incremental archive option;
  - parsing incremental manifest option;
  - rejecting mutually exclusive incremental sources;
  - rejecting missing incremental archive;
  - rejecting incremental options with `--verify`.

## Notes

The local container does not include `gprbuild` or `gnat1`, so I could not run
GNAT compilation here. A direct attempt to invoke `gcc-14 -c -gnat2022` fails
because the Ada front end executable is unavailable. The code follows the
existing project style and updates `backup_tests.gpr` to include the new test
executable.

## Completeness pass 2 changes

- Tightened prior metadata validation before incremental comparison:
  - stored file entries must have `compressed_size = uncompressed_size`;
  - deterministic deflated entries must match the Phase 9 stored-deflate-block
    size prediction;
  - symlink entries must be stored, size-consistent, and CRC-consistent with
    their stored target text.
- Added explicit dry-run and JSON trust-model fields so reports state that prior
  archive metadata is trusted only after archive verification and prior manifest
  metadata is trusted only after manifest validation.
- Added explicit dry-run and JSON payload-reuse strategy fields. The current
  execution strategy records semantic reuse decisions and emits a deterministic
  synthetic full archive through the existing ZIP writer; raw compressed-payload
  copying remains a future writer-level optimization rather than an implicit
  promise.
- Read validated archive-path temporary values in assertions to avoid
  warning-as-error builds complaining about validation-only temporaries.
- Added non-empty value checks for separated `--incremental-from` and
  `--incremental-from-manifest` option forms, matching the existing `--opt=`
  checks.
- Extended tests for conflicting prior symlink metadata, empty incremental
  `--opt=` forms, and incremental report payload/trust markers.


## Completeness pass 3 changes

- Closed the reporting gap where incremental dry-run/JSON output replaced the
  normal scanner report and therefore did not expose current ignored entries or
  skipped symlink diagnostics.
- Added `Append_Skipped_From_Report` so the incremental plan appends deterministic
  `skipped` decisions for current ignored files/directories/symlinks and for
  symlinks skipped, broken, cyclic, or outside the input root.
- Added a `directory` plan kind for skipped ignored directories so JSON and
  dry-run output do not mislabel pruned directories as files.
- Kept duplicate-path protection when appending skipped diagnostics so a skipped
  diagnostic cannot shadow an added, modified, reused, or removed archive entry.
- Tightened the unsupported method rendering to avoid Ada image leading spaces.
- Added unit coverage for skipped ignored-directory and skipped-symlink reporting
  in deterministic incremental JSON output.

## Completeness pass 4 changes

- Fixed a current-policy reporting ambiguity for prior paths that are absent from
  the current archive because they are now ignored or skipped by symlink policy.
  Such paths are now represented as `skipped` rather than only `removed`, so the
  incremental plan reflects the Phase 6/15 current scan decision instead of only
  the historical archive difference.
- Added count rebasing for that transition: converting an existing `removed`
  item to `skipped` decrements the removed count, increments the skipped count,
  and does not append a duplicate plan item.
- Preserved duplicate-path safety for already-added, modified, or reused entries:
  scanner diagnostics with the same archive path do not shadow an included current
  entry.
- Added unit coverage for a prior manifest entry that is now ignored by the
  current scan report, including decision rebasing and count preservation.

## Completeness pass 5 changes

- Hardened previous-manifest key discovery so `"archive_path"` and other field
  names are only recognized as JSON object keys, not as escaped text inside
  string values such as symlink targets.
- Replaced reverse object-start detection with a string-aware brace stack so
  braces inside earlier string fields cannot corrupt entry object boundaries.
- Removed the now-unused plain substring helper and its context clause to keep
  warning-as-error builds clean.
- Added unit coverage for:
  - symlink targets containing key-like escaped text such as `"archive_path"`;
  - manifest entry objects that contain braces inside string fields before the
    real `archive_path` key.

Completeness pass 6:
- Fixed the incremental manifest parser to respect Ada string slice lower bounds when searching for JSON keys inside entry-object slices.
- Restricted prior-manifest entry discovery to the top-level `entries` array instead of accepting stray `archive_path` objects elsewhere in the document.
- Added string-aware JSON array-boundary detection for the manifest `entries` array.
- Added regression tests for stray `archive_path` metadata outside `entries` and missing `entries` arrays.

Completeness pass 7:
- Tightened prior-manifest JSON key lookup to use direct object depth rather than first matching key text.
- The manifest `format` and `entries` fields are now accepted only as top-level manifest object keys; nested metadata fields cannot satisfy the trust model.
- Entry metadata such as `archive_path`, `kind`, `compression_method`, sizes, CRC, and `link_target` is now read only from direct fields of each entry object.
- Prior manifest planning now enumerates direct objects inside the top-level `entries` array, so nested objects inside metadata cannot create phantom prior entries.
- Added rejection for non-object values inside the `entries` array.
- Removed obsolete reverse object-start and generic key-search helpers after replacing entry discovery with direct array object enumeration.
- Added regression tests for nested `entries` metadata, nested-only `format`, and scalar values inside the entries array.

Completeness pass 8:
- Replaced permissive manifest `entries` object discovery with direct array-value parsing.
- Every top-level value in the manifest `entries` array must now be an object; scalar values before a later valid object are rejected instead of skipped.
- Added separator validation for the `entries` array so trailing commas and invalid separators are rejected as malformed prior manifests.
- Removed the now-obsolete direct-array-object search helper to keep the incremental parser smaller and avoid unused code in warning-as-error builds.
- Added regression tests for scalar-before-object entries and trailing-comma entries.

## Completeness pass 9

- Tightened prior-manifest scalar parsing so required string and numeric fields
  must end at a valid object-field delimiter instead of accepting a valid prefix
  followed by junk text.
- Numeric manifest fields now reject malformed numeric spellings such as
  `0x0` and leading-zero forms like `00`; only unsigned decimal integers are
  accepted for CRC and size metadata.
- String manifest fields now reject invalid trailing tokens immediately after
  the closing quote.
- Added regression tests for malformed scalar values in prior manifests.

## Completeness pass 10

- Added single-root-object validation for prior manifests. Incremental planning
  now rejects empty manifests, non-object roots, malformed root objects, and
  trailing non-whitespace content after the root object instead of allowing key
  discovery to continue into concatenated JSON text.
- Added duplicate direct-key validation for trusted manifest metadata:
  - the top-level `format` field must occur exactly once;
  - the top-level `entries` field must occur exactly once;
  - every entry object must contain exactly one `archive_path`, `kind`,
    `compression_method`, `crc32`, `compressed_size`, and `uncompressed_size`;
  - symlink entry objects must contain exactly one direct `link_target` field.
- Removed the unused manifest-entry key position temporary left behind by the
  earlier parser hardening, keeping `-gnatwa -gnatwe` builds cleaner.
- Added regression tests for non-object manifest roots, trailing concatenated
  JSON roots, duplicate top-level `format`, duplicate top-level `entries`,
  duplicate entry `archive_path`, and duplicate required entry metadata.

## Completeness pass 11

- Fixed two compile-level regressions in the Phase 18 incremental code:
  - removed an accidental duplicated `function Contains` declaration in the
    incremental test executable;
  - corrected an invalid two-character backslash character literal in the
    direct JSON-key counter.
- Added direct-object field-separator validation for trusted prior manifests.
  The manifest root and each entry object now reject missing commas between
  fields before key extraction is allowed to trust the metadata.
- Added JSON string/value skipping helpers used only for structural validation,
  so separator checks remain string-aware and do not treat escaped quotes or
  braces inside strings as syntax boundaries.
- Added regression tests for malformed prior manifests with:
  - missing comma between top-level `format` and `entries` fields;
  - missing comma between direct fields inside an entry object.

## Completeness pass 12

- Tightened prior symlink metadata validation so a trusted symlink entry must
  have `uncompressed_size` equal to the decoded `link_target` byte length, in
  addition to stored-method, compressed-size, and CRC consistency checks.
- Tightened prior-manifest kind-specific field validation:
  - file entries now reject any direct `link_target` field;
  - symlink entries must contain exactly one direct, valid `link_target` field.
- Added regression tests for:
  - a symlink manifest entry whose CRC matches the target but whose size does
    not match the decoded target text;
  - a file manifest entry incorrectly carrying `link_target` metadata;
  - a symlink manifest entry with duplicate `link_target` fields.
