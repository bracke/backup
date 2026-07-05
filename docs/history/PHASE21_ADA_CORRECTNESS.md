# Phase 21 Ada Correctness Pass

This pass reviewed the Phase 21 remote-transport implementation for Ada-level
correctness issues that are likely to become GNAT compile, runtime-check, or
style failures.

## Fixes applied

- Added explicit body context clauses needed by Phase 21 code:
  - `with Interfaces;` in `backup-remote.adb`.
  - `with Backup.CLI;` and `with Backup.Encryption;` in `backup-jobs.adb`.
- Replaced direct JSON hexadecimal string indexing with a checked
  `Hex_Digit` helper so control-character escaping cannot index the hex table
  at position zero.
- Added quiet search-finalization helper for `Ada.Directories.Search_Type` and
  rewired remote inventory enumeration so exception cleanup does not attempt
  unsafe repeated finalization.
- Tightened managed remote object classification:
  - ordinary managed archives still include `.zip`, `.backupenc`, `.enc`, and
    `.zip.enc` names;
  - partial objects are treated as managed only when the base object name is a
    managed archive name;
  - arbitrary names such as `scratch.partial` are no longer inventoried or
    eligible for remote deletion.
- Removed a duplicated remote CLI assertion in `backup_remote_tests.adb`.
- Added remote tests for unmanaged partial-object rejection.
- Reflowed newly added Phase 21 remote code to avoid very long Ada source
  lines in the touched files.

## Validation limitation

The local container still lacks the GNAT Ada frontend executable `gnat1`, so a
real `gprbuild`/GNAT compile could not be run here. The pass therefore used
source inspection and static consistency checks rather than compiler output.
