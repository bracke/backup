# Phase 21 completeness pass

Implemented:

- Added `Backup.Remote` as a strongly typed transport abstraction layer.
- Added deterministic `file://` remote namespace support.
- Added typed remote status values, transport kinds, transfer reports, archive
  metadata records, inventory vectors, and synchronization plan vectors.
- Added atomic upload semantics using partial objects and final rename.
- Added replacement recovery for existing remote objects.
- Added post-upload remote metadata verification.
- Added interrupted-upload marker handling through `*.partial` inventory items.
- Added resumable file transport behavior for matching `OBJECT.partial` data when `--remote-resume` or `resume=true` is selected.
- Added scoped remote object deletion for managed backup objects and partial markers.
- Preserved remote JSON reports after workflow execution instead of overwriting them with ordinary archive JSON.
- Added scheduled-job remote retention pruning for managed objects inside the configured remote namespace.
- Restricted remote retention candidates by the configured output naming policy so unrelated backup-looking objects in the same namespace are left untouched.
- Added deterministic remote sync planning using archive id, size, CRC32, and
  partial marker state.
- Added remote restore/download support with temporary local replacement and
  verification.
- Added JSON reporting for remote transfer and sync plans.
- Added human-readable remote synchronization dry-run reporting for non-JSON dry runs.
- Added CLI options:
  - `--remote URL`
  - `--remote-config FILE`
  - `--upload`
  - `--sync`
  - `--restore-remote`
  - `--remote-require-encrypted`
  - `--remote-resume`
- Added validation for unsupported remote option combinations.
- Added remote encryption guard semantics both at CLI validation time and inside `Backup.Remote.Upload_Archive`, so direct API callers also cannot upload plaintext when `Require_Encrypted` is set.
- Added `--remote-config` parsing for `remote`/`url`, `require_encrypted`, `resume`, `retry_count`, and `timeout_seconds`.
- Added job configuration keys:
  - `remote=`
  - `upload_after=`
  - `sync_after=`
  - `remote_require_encrypted=`
  - `remote_resume=`
- Wired remote upload and sync into scheduled-job execution through the normal
  workflow path.
- Added `httpclient` as an Alire dependency for future HTTP/HTTPS transports.
- Explicitly rejected HTTP/HTTPS URLs in this build rather than implementing a
  custom stack or shelling out.
- Added `backup_remote_tests.adb` covering URL parsing, upload verification,
  corrupted remote metadata rejection, inventory loading, sync planning,
  partial upload marker handling, scoped partial deletion, resumable partial promotion, plaintext rejection under encrypted-remote policy, timeout rejection, remote-config parsing, workflow upload, remote JSON reporting, human-readable remote sync dry-run reporting, remote restore, and remote retention pruning safety.
- Added retry/timeout policy handling to the file transport reference implementation: zero-second timeout fails deterministically before transfer, and copy operations retry up to the configured retry count before returning a typed copy failure.
- Added `tests/run_phase21_remote_integration.sh` for end-to-end CLI upload, sync, sync dry-run, restore, and remote-config coverage.
- Added remote transport documentation.

Known boundary:

- Network HTTP/HTTPS transport is not enabled in this build. The abstraction and
  dependency boundary are in place, and unsupported URL schemes fail with typed
  diagnostics.

Validation note:

- I could not run `gprbuild` in this execution environment because the GNAT Ada
  frontend (`gnat1`) is not installed. The project files, source, tests, and
  documentation have been updated for a full local build/test run.

Additional completeness pass 4:

- Fixed a malformed duplicate actual-parameter line in `backup_remote_tests.adb` introduced during the timeout/resume test expansion.
- Added `Backup.Remote.Build_Sync_Human_Report` and wired non-JSON remote sync dry-runs to use it instead of emitting JSON unconditionally.
- Normalized the remote transfer JSON `retried` value formatting so it is emitted as a clean decimal number.
- Extended the Phase 21 Ada test and shell integration script to cover human-readable remote sync dry-run output.

## Ada correctness pass addendum

A subsequent Ada correctness pass tightened Phase 21 remote code by adding
explicit body context clauses, fixing checked JSON hex escaping, hardening
remote inventory search finalization, and refusing unmanaged `.partial` object
names. See `PHASE21_ADA_CORRECTNESS.md`.
