# Phase 16 Completeness Pass — Archive Verification

This pass adds archive verification and integrity-check functionality on top of the Phase 15 backup crate, then tightens the first Phase 16 implementation for correctness, diagnostics, and test coverage.

## Implemented

- Added `Backup.Verify` as a dedicated verification package.
- Added ZIP EOCD parsing and central-directory traversal.
- Added EOCD comment-length validation so stray signatures are not accepted as a valid archive terminator.
- Added ZIP64 locator / ZIP64 EOCD handling when classic ZIP32 sentinel values are present.
- Added central-directory ZIP64 extra-field parsing for sizes and local-header offsets.
- Added local-header validation against central-directory metadata.
- Added Phase 2 archive path invariant checks for every central-directory path.
- Added duplicate archive-path detection.
- Added stored entry payload validation.
- Added method 8 validation for the deterministic raw-deflate stored-block payloads emitted by the existing Phase 9 writer.
- Added payload-boundary checks so entry data cannot overlap the central directory.
- Added CRC32 validation over decompressed/original bytes.
- Added detection for malformed structures, invalid offsets, truncated payloads, metadata mismatches, invalid ZIP64 structures, unsupported compression methods, CRC mismatches, and invalid deflate payloads.
- Added explicit missing/unopenable archive diagnostics through `Verify_Open_Failed`.
- Added symlink recognition from ZIP external attributes used by Phase 15.
- Added manifest presence detection and backup manifest consistency checks when `.backup/manifest.json` exists.
- Tightened manifest validation from broad substring checks to per-entry object checks for archive path, kind, compression method, CRC32, compressed size, and uncompressed size.
- Added deterministic human-readable and JSON verification report builders.
- Added `--verify` CLI mode.
- Added workflow integration for verification mode.
- Added parser diagnostics for unsupported `--verify` combinations, including archive-creation-only options such as `--prefix`, `--compression`, `--symlinks`, and size limits.
- Preserved JSON output for failed `--verify --list-json` runs without adding the ordinary `backup:` diagnostic prefix.
- Added `backup_verify_tests.adb` coverage for successful stored verification, deflated verification, symlink entries, manifest verification, CRC mismatch detection, duplicate path detection, unsupported compression method diagnostics, missing archive open failure, truncated payload detection, invalid central-directory offset detection, invalid ZIP64 structure detection, unsupported verify option combinations, and deterministic JSON verification output.

## Scope Boundary

The existing project snapshot does not contain a general-purpose Ada zlib inflate package. Phase 16 therefore validates the raw-deflate stored-block method-8 payloads produced by the project’s own Phase 9 ZIP writer. The verifier rejects other method-8 block types with a precise deflate validation diagnostic instead of silently accepting data it cannot validate.

## Not Run Here

`gprbuild` / GNAT tooling is not installed in the execution container (`gprbuild: command not found`, `gnat1: No such file or directory`), so this pass could not be compiled or executed in-container. The changes are packaged for compilation in the normal Ada/GNAT project environment.

## Second completeness pass

Additional Phase 16 tightening performed after the first completeness pass:

- Verification option validation now distinguishes explicit `--compression=auto` and explicit `--symlinks=skip` from their defaults, so `--verify` rejects archive-creation option families even when the supplied value equals the default.
- Removed duplicate unreachable `return False` in CLI validation.
- Manifest verification now requires the `backup-manifest-v1` format marker and checks that the number of manifest entry objects matches the number of non-manifest archive entries, preventing stale extra manifest entries from being silently accepted.
- The verifier still intentionally validates the deterministic raw stored-block deflate form produced by this crate's Phase 9 writer. A full general-purpose DEFLATE decoder is not introduced in this phase because this crate still has no standalone zlib package source in-tree.

As before, this environment does not provide GNAT/GPRbuild, so the Ada code and tests could not be compiled or executed locally here.

## Third completeness pass

Additional tightening performed in this pass:

- Reworked the duplicate archive-entry test fixture so only the second central-directory name is changed from `b.txt` to `a.txt`; local headers and payloads remain untouched, so the test proves duplicate central-directory detection instead of relying on collateral local-header metadata corruption.
- Added explicit local-header empty-name handling before converting local names to Ada `String` values, avoiding a possible `Constraint_Error` path on malformed local headers.
- Added a zero-length-payload placement check: even entries with compressed size 0 must have their payload position at or before the central directory, so a malformed local header cannot silently overlap central-directory space just because the payload length is zero.
- Added test coverage for zero-length stored entries and corrupted zero-length local-header placement.
- Removed the duplicate “stored archive created” assertion that had been left in the Phase 16 test driver.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.

## Fourth completeness pass

Additional tightening performed in this pass:

- Made EOCD discovery comment-length-aware, so an EOCD signature byte sequence inside a ZIP comment does not mask the real EOCD record.
- Added test coverage for a valid archive whose ZIP comment contains the EOCD signature bytes.
- Added explicit rejection of central-directory archive names containing host backslash separators; verification now enforces ZIP archive `/` separators rather than relying on the path normalizer to convert them.
- Added test coverage for a corrupted archive whose local and central names use `dir\a.txt` instead of `dir/a.txt`.
- Added explicit rejection for multi-disk ZIP metadata in classic EOCD and ZIP64 locator/EOCD records.
- Added test coverage for non-zero classic EOCD disk metadata.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.

## Fifth completeness pass

Additional tightening performed in this pass:

- Added explicit `Verify_Unsupported_Feature` status for ZIP features that the verifier intentionally does not support yet, separate from unsupported compression methods.
- Rejected non-zero general-purpose bit flags except the UTF-8 filename flag (`0x0800`), so encrypted entries, data-descriptor entries, and other unsupported feature bits are not silently interpreted using backup's simple local-header layout.
- Added validation that local-header general-purpose flags match the corresponding central-directory flags.
- Hardened ZIP64 extra-field parsing so zero-length extra records no longer risk unsigned underflow while checking record bounds.
- Added ZIP64 EOCD record-size validation against the ZIP64 locator position, with overflow-safe arithmetic.
- Added tests for unsupported general-purpose flags and local/central flag mismatches.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.

## Sixth completeness pass

Additional tightening performed in this pass:

- Moved compressed-payload end-offset calculation behind an explicit `Fits` check so malformed large size fields report `Verify_Truncated_Payload` instead of risking a `Stream_Element_Offset` conversion/range exception path.
- Added backup-specific validation that `.backup/manifest.json` must be stored, matching the Phase 11 manifest writer behavior.
- Added backup-specific validation that symlink entries must be stored, matching the Phase 15 symlink storage contract.
- Tightened manifest validation to require the `manifest_path` marker to match `.backup/manifest.json`.
- Tightened manifest entry counting to count generated manifest entry objects by the exact `source`/`archive_path` field sequence rather than every occurrence of an `archive_path` key-like substring.
- Added regression tests for a manifest entry corrupted to method 8 and a symlink central entry corrupted to method 8.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.

## Seventh completeness pass

Additional tightening performed in this pass:

- Manifest payload capture now keeps the full manifest entry content instead of applying the ordinary small-entry preview limit, so larger valid backup manifests can still be validated.
- Verification reports now retain symlink link-target payloads for symlink entries.
- Manifest consistency validation now checks symlink `link_target` metadata against the stored symlink payload, preserving the Phase 15 symlink metadata contract.
- Manifest consistency validation now requires the manifest-level `manifest_method` marker to be `stored`.
- Human-readable and JSON verification reports now include symlink link targets for verified symlink entries.
- Added regression tests for symlink manifest success, mismatched symlink manifest `link_target`, and mismatched manifest `manifest_method` marker.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.

## Eighth completeness pass

Additional tightening performed in this pass:

- Verification JSON string escaping is now aligned with the project JSON emitters for low control characters, not just quotes, backslashes, tabs, CR, and LF. This prevents symlink targets or other reported text containing control bytes from producing invalid deterministic JSON.
- Central-directory placement is now exact: for classic ZIP archives, the central directory must end immediately before the EOCD; for ZIP64 archives, it must end immediately before the ZIP64 EOCD record. Unexpected bytes inserted between the central directory and its required trailer are rejected as invalid offsets.
- Added local-entry range overlap tracking so a central directory cannot describe two entries whose local-header/payload byte ranges overlap.
- Added regression tests for unexpected bytes between the central directory and EOCD, and for deterministic JSON escaping of low control characters.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.

## Ninth completeness pass

Additional tightening performed in this pass:

- Corrected ZIP64 central-directory local-header offset parsing. ZIP stores this offset as a zero-based file offset, while the verifier uses one-based `Stream_Element_Array` indexing internally; the verifier now converts the parsed ZIP64 offset with `+ 1` and rejects overflow explicitly.
- Added regression coverage for a standards-compliant central-directory ZIP64 extra field that supplies only the local-header offset while the local header itself remains ordinary ZIP32-sized.
- Rejected central-directory records whose per-entry disk-start field is non-zero, closing a remaining multi-disk ZIP acceptance gap.
- Added version-needed validation for local and central headers, accepting only the ZIP versions generated/supported by this crate (`20` for normal stored/deflated entries and `45` for ZIP64 metadata).
- Tightened raw stored-block deflate validation so method 8 payloads must use the canonical byte headers emitted by the Phase 9 writer (`0` for non-final blocks, `1` for the final block). Non-zero padding bits in the block header are now rejected as non-backup deflate payloads.
- Added regression tests for unsupported per-entry disk-start metadata, unsupported version-needed fields, and noncanonical raw stored-block deflate headers.

Compilation/test execution is still pending in a GNAT/GPRbuild environment because this container does not include Ada compiler tooling.
