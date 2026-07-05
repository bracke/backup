# Phase 20 completeness notes — jobs, scheduling, and retention

Phase 20 adds a job/retention layer without changing the correctness contract of the one-shot backup workflow.

## Implemented scope

- Added `Backup.Jobs` as the automated execution layer.
- Added persisted job configuration loading using a deterministic line-oriented format:
  - `format=backup-job-v1`
  - repeated `source=PATH`
  - repeated `ignore=PATH`
  - `output=PATH`
  - `output_naming=exact|sequence`
  - `compression=auto|store|deflate|bzip2|lzma|ppmd|zstd`
  - `symlinks=skip|store-link|follow`
  - `deterministic=true|false`
  - `manifest=true|false`
  - `list_json=true|false`
  - `dry_run=true|false`
  - `max_file_size=BYTES`
  - `max_total_size=BYTES`
  - `incremental_from=ARCHIVE`
  - `incremental_from_manifest=MANIFEST`
  - `encrypt=true|false`
  - `password_file=PATH`
  - `password_env=NAME`
  - `password_prompt=true|false`
  - `cipher=aes256-gcm`
  - `verify_after=true|false`
  - `retention_after=true|false`
  - `retention=none|count:N|age-days:N|tiered:daily=N,weekly=N,monthly=N`
  - `schedule=external|manual|disabled|interval-hours:N|daily-at:HH:MM`
- Added CLI job-management support:
  - `--job FILE`
  - `--job=FILE`
  - `--run-job FILE`
  - `--run-job=FILE`
  - `--create-job FILE`
  - `--create-job=FILE`
  - `--retention-policy POLICY` and `--retention-policy=POLICY` for run-job retention override.
- Added deterministic job execution reporting as a machine-readable JSON object listing explicit phases.
- Added post-backup verification as an explicit job phase. Dry-run job executions report verification as skipped instead of attempting to verify an archive that was intentionally not created.
- Added retention selection with deterministic newest-first ordering and path tie-breaking.
- Added count-based retention, age-days retention, and tiered retention. Tiered retention keeps newest daily representatives first, then distinct age-week representatives, then distinct calendar-month representatives, and prunes the rest deterministically.
- Added destination archive naming policies:
  - `exact` writes the configured `output` path.
  - `sequence` writes `BASE-000001.zip`, `BASE-000002.zip`, and so on, choosing the first missing sequence path deterministically.
- Added safety validation that retention selection refuses unmanaged candidates.
- Added managed-set retention cleanup limited to ordinary files in the output archive directory. Exact-naming jobs only manage `BASE.zip`; sequence-naming jobs manage `BASE.zip` and `BASE-NNNNNN.zip` sequence archives.
- Added job-side validation mirroring one-shot CLI invariants that are otherwise bypassed by persisted job execution:
  - required output and source entries;
  - duplicate normalized source rejection;
  - output path must not also be a source path;
  - incremental source must exist, be an ordinary file, and must not be the output archive;
  - incremental manifest source must exist, be an ordinary file, and must not be the output archive;
  - ignore files must exist and be ordinary files;
  - encrypted deterministic jobs are rejected;
  - encrypted jobs require an explicit password source;
  - password-file sources must exist and be ordinary files;
  - password source values must be non-empty;
  - only one incremental source mode is accepted;
  - duplicate scalar configuration keys are rejected instead of silently using the last value.
- Added explicit status values for malformed jobs, unsupported values, failed backup, failed verification, retention failure, and interrupted jobs.
- Added `.running` execution markers so a later run detects an interrupted prior execution and fails explicitly instead of silently skipping or overwriting it.
- Extended job execution JSON reports with the planned output path and dry-run-safe phase wording (`planned` rather than `created`).
- Retention cleanup honors job dry-run mode: candidate selection is still reported, but files are not deleted.
- Duplicate job-file options such as `--job A --run-job B` are rejected instead of silently replacing the job file path.

## Scheduling boundary

Phase 20 intentionally separates scheduling orchestration from backup correctness. The `schedule=` field is parsed and persisted as constrained metadata for an external scheduler or a future scheduler adapter. Accepted values are `external`, `manual`, `disabled`, `interval-hours:N` with `N > 0`, and `daily-at:HH:MM` in the `00:00..23:59` range. The actual backup execution path is explicit: `backup --run-job FILE`. This preserves the existing scan, ignore, compression, deterministic metadata, ZIP64, symlink, verification, extraction, incremental, and encryption invariants.

## Retention safety model

Retention evaluation works on an explicit `Managed_Backup` candidate set. `Select_Retention_Deletions` fails if any candidate is not marked managed. The filesystem cleanup path constructs its candidate set only from ordinary files in the configured output directory. For `output_naming=exact`, the managed set is only the exact configured archive name. For `output_naming=sequence`, the managed set is the configured base archive name plus six-digit sequence archives derived from that base. It never walks arbitrary directories and never deletes paths outside the computed managed set.

## Tests added

`backup_jobs_tests.adb` covers:

- loading a valid job configuration;
- repeated source and ignore entries;
- compression and symlink parsing;
- manifest, list-json, dry-run, verification, and retention flags;
- job size-limit parsing;
- sequence archive naming and deterministic next-path selection;
- generated template creation and reload;
- count-based retention parsing and selection;
- age-based retention parsing and selection;
- tiered retention parsing and pruning selection;
- deterministic oldest-candidate deletion;
- unmanaged retention candidate rejection;
- malformed-job diagnostics for duplicate normalized sources;
- malformed-job diagnostics for output/input path conflicts;
- malformed-job diagnostics for encrypted deterministic jobs;
- malformed-job diagnostics for missing format declarations;
- malformed-job diagnostics for empty tiered retention policies;
- loading encrypted scheduled jobs with password-file validation;
- loading incremental scheduled jobs and mapping them into CLI configuration;
- malformed-job diagnostics for duplicate scalar job keys;
- malformed-job diagnostics for missing incremental archives;
- malformed-job diagnostics for non-ordinary-file incremental manifests;
- dry-run scheduled execution JSON output including the planned output path;
- dry-run scheduled jobs skipping post-backup verification;
- dry-run retention reporting planned deletions without deleting archives;
- exact-naming retention does not prune sequence-named sibling archives;
- schedule metadata validation and acceptance of interval schedules;
- CLI parsing for `--run-job`;
- CLI parsing for `--create-job`;
- diagnostic rejection of positional paths with job-management commands;
- diagnostic rejection of duplicate job-file options;
- CLI parsing for run-job retention override;
- diagnostic rejection of `--retention-policy` outside job execution;
- interrupted execution marker detection.


## Documentation pass additions

This pass added dedicated user-facing and API-facing documentation for Phase 20:

- `JOBS_RETENTION.md` documents the job-management CLI, full job-file key reference, examples, archive naming policies, retention policies, retention safety model, scheduling metadata boundary, execution markers, JSON job reports, and failure semantics.
- `src/backup-jobs.ads` now contains GNATdoc-style comments for the public Phase 20 job API, including status values, retention policy records, managed backup candidates, loading, template writing, CLI conversion, planned output selection, retention deletion planning, and execution.
- `src/backup-cli.ads` now documents how job-management mode is represented in the CLI configuration and how it is kept mutually exclusive from one-shot archive operations.

The main missing documentation found before this pass was that `PHASE20_COMPLETENESS.md` summarized implementation coverage but did not provide a complete end-user contract for the persisted job file or GNATdoc-style comments for the new public package.

## Compile note

The project was source-reviewed and packaged in an environment where `gcc` advertises Ada support but cannot execute `gnat1`; GNAT compilation and test execution were therefore not possible in this container.
