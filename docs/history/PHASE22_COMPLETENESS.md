# Phase 22 completeness pass

Implemented Phase 22 cataloging as a bounded Ada 2022 layer over the existing Phase 16/19/20/21 components.

## Implemented

* Added `Backup.Catalog` spec/body.
* Added deterministic text catalog format with `backup-catalog-v1` header.
* Added typed archive and entry records, including per-entry verification state.
* Added atomic temporary-file catalog save path.
* Added malformed empty-catalog rejection.
* Added archive indexing through Phase 16 verification for plaintext ZIP archives.
* Added conservative Phase 19 encrypted-envelope indexing semantics.
* Added query model for archive name, archive date, contents, source path, incremental lineage, remote location, remote verification, archive/entry verification state, manifest state, compression method, entry kind, and retention group.
* Added deterministic human and JSON catalog reports, including source modification timestamps, archive modification timestamps, entry trust state, and remote verification flags where available.
* Added catalog consistency verification, stale metadata detection, missing-catalog rejection, duplicate-entry rejection during load, incremental parent resolution checks, per-entry trust checking, and interrupted-update recovery diagnostics.
* Added CLI options:
  * `--catalog FILE`
  * `--index ARCHIVE.zip`
  * `--query QUERY`
  * `--list-archives`
  * `--list-contents`
  * `--verify-catalog`
* Added query coverage for encrypted metadata, exact archive/entry size, and exact archive/entry CRC32 metadata.
* Added catalog command validation so catalog management commands do not silently mix with extraction, verification, remote restore, or job-management operations.
* Added `--catalog FILE` support for ordinary backup creation, with automatic post-run indexing.
* Added run metadata attachment for source paths, incremental parent references, remote URL/state, and retention override text.
* Added job-file `catalog=PATH` propagation into scheduled backup execution.
* Added catalog record removal for scheduled retention pruning.
* Added `CATALOG.md` documenting format, trust model, query model, and recovery diagnostics.
* Added `backup_catalog_tests.adb` and registered it in `backup_tests.gpr`.

## Tests added

The new catalog tests cover:

* deterministic verified archive indexing;
* content query execution;
* JSON query reporting, including entry trust state;
* catalog consistency verification, missing-catalog rejection, and interrupted-update recovery diagnostics;
* stale metadata detection;
* encrypted archive envelope indexing without entry disclosure;
* unsupported query diagnostics;
* CLI parsing for catalog-management commands.
* CLI parsing for backup creation with automatic catalog indexing.
* remote, remote-verification, manifest-state, lineage, retention, archive-only, archive-date, verification-state, compression-method, entry-kind, and source-path catalog queries.
* stale/untrusted entry rows under trusted archives, duplicate entry row rejection, missing incremental parent rejection, and leftover `.bak` recovery guidance.
* scheduled job parsing for `catalog=PATH`, rejection for dry-run catalog jobs, and CLI rejection for query/list operations against a missing catalog.

## Notes

The implementation uses the existing `Backup.Verify.Verify_Archive` path for trusted entry indexing and therefore does not require full extraction. Encrypted archives expose only envelope-level metadata when indexed without a password source; password-backed indexing or encrypted archive creation verifies the decrypted work archive and records trusted searchable entry metadata while keeping the archive record marked as an encrypted envelope. Automatic catalog updates run after archive creation and after remote transfer success, so failed upload/sync paths do not mark the catalog record as remotely verified.

## Additional completeness pass

This pass tightened remaining metadata-query semantics:

* Persisted archive file modification timestamps in archive records while retaining read compatibility with older 14-field Phase 22 catalog rows.
* Extended `date:` queries to match both the catalog indexing timestamp and the underlying archive modification timestamp.
* Extended `verification:` queries so they cover both archive records and entry records.
* Added typed entry metadata queries for `method:` and `kind:`.
* Added query-value validation for `remote-verified:`, `verification:`, `manifest:`, `method:`, and `kind:` so invalid values produce deterministic diagnostics instead of silently returning empty results.
* Updated human and JSON catalog reports to expose archive modification timestamps.
* Expanded catalog tests for archive-date queries, archive/entry verification-state queries, method queries, kind queries, and invalid query-value diagnostics.

## Further completeness pass

This pass exposed stored metadata through deterministic queries rather than leaving it report-only:

* Added `encrypted:` queries for archive envelope visibility state.
* Added exact `size:` queries over archive sizes and entry compressed/uncompressed sizes.
* Added exact `crc32:` queries over archive and entry CRC32 metadata.
* Added strict validation diagnostics for invalid `encrypted:`, `size:`, and `crc32:` query values.
* Expanded catalog tests and documentation for these metadata-query paths.


## Additional completeness pass 7

* Removed a Phase 22 Ada-correctness bug by renaming a formal parameter that used the reserved word `entry` by case-insensitive spelling.
* Reformatted the affected conditional expression so each `then` is followed by a line break.
* Added `Backup.Catalog.Record_Verification_Result` for catalog-backed archive verification updates.
* Allowed `--catalog FILE` with `--verify ARCHIVE.zip` so Phase 16 verification can update Phase 22 catalog verification state.
* Added tests for catalog verification-state updates of encrypted envelopes and CLI acceptance of catalog-backed verification.

## Additional completeness pass 8

* Fixed an Ada-correctness regression in `Backup.Catalog.Attach_Run_Metadata`: the entry trust-state update now mutates the local `Catalog_Entry` record instead of referring to a nonexistent `Catalog_Item` identifier.
* Extended the catalog CLI test argument helper to accept six arguments, matching existing catalog command validation tests that pass both `--list-archives` and `--list-contents` in the same invocation.
* Rechecked Phase 22 source for reserved-word identifier regressions and verified the catalog test executable remains registered in `backup_tests.gpr`.
