# Phase 14 completeness pass — ZIP64 support and large archive handling

This pass completes and tightens the Phase 14 ZIP64 implementation while preserving Phase 13 deterministic output behavior and ZIP32-compatible output for small archives.

## Implementation updates

- Replaced the remaining ZIP32-only public writer failures with Phase 14-appropriate failures:
  - `Write_Archive_Name_Too_Long` for the ZIP format's still-16-bit filename length field;
  - `Write_Size_Overflow` for internal 64-bit size-accounting overflow.
- Kept all archive size, compressed size, uncompressed size, local-header offset, central-directory offset, central-directory size, and entry-count accounting in explicit `Interfaces.Unsigned_64` values where ZIP64 can represent them.
- Preserved rejection of archive names longer than `Unsigned_16'Last`, because ZIP64 does not extend the filename-length field.
- Added guarded deflate-size prediction that avoids unchecked `Unsigned_64` overflow for very large inputs.
- Added guarded compressed-size calculation in manifest generation so large metadata is either represented correctly or rejected through an explicit manifest build result.
- Fixed ZIP64 final-record activation for entry-level ZIP64 triggers. A single large entry or an entry whose local-header offset exceeds the ZIP32 field now causes ZIP64 EOCD and ZIP64 locator emission even when the classic EOCD entry count and central-directory fields would otherwise fit.
- Retained ZIP32-compatible output for small archives by suppressing ZIP64 extra fields, ZIP64 EOCD, and ZIP64 locator records unless a ZIP64 trigger is present.
- Continued deterministic metadata normalization from Phase 13: DOS time/date, central-directory attributes, stable entry ordering, and repeatable output remain unchanged.

## ZIP64 structures covered

- Local ZIP64 extended information extra fields for entries whose compressed or uncompressed size exceeds the ZIP32 field.
- Central-directory ZIP64 extended information extra fields for entries whose compressed size, uncompressed size, or local-header offset exceeds the ZIP32 field.
- ZIP64 end-of-central-directory record with 64-bit entry count, central-directory size, and central-directory offset.
- ZIP64 end-of-central-directory locator pointing to the ZIP64 EOCD.
- Classic EOCD sentinel fields where the corresponding classic ZIP field overflows.

## Tests added or retained

- Empty ZIP remains classic ZIP32 and emits no ZIP64 EOCD.
- Small stored ZIP remains classic ZIP32 and emits no ZIP64 EOCD.
- Stored, deflated, empty-deflated, multi-block deflated, and mixed stored/deflated archives retain valid ZIP headers and deterministic metadata.
- Duplicate archive paths, invalid archive paths, unreadable sources, and too-long archive names return explicit statuses.
- Large entry-count archive with more than 65,535 generated entries emits ZIP64 EOCD and ZIP64 locator and uses ZIP64 entry counts.
- Repeated large entry-count ZIP64 generation is byte-for-byte deterministic.

## Verification note

`gprbuild` and `gnatmake` are not installed in this execution environment, so I could not run the Ada build or tests here. The project has been updated for local GNAT/Alire verification with:

```sh
gprbuild -P backup_tests.gpr
./bin/backup_zip_tests
./bin/backup_manifest_tests
./bin/backup_workflow_tests
```
