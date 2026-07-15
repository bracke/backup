# Backup jobs, scheduling metadata, and retention policies

This document describes the Phase 20 automated-job layer. It is intentionally separate from the one-shot archive creation, verification, extraction, incremental-planning, and encryption code paths. A job file is a persisted configuration that is loaded, validated, converted to the existing CLI configuration record, and then executed through the same workflow used by ordinary CLI archive creation.

## CLI entry points

Create a template job file:

```sh
backup --create-job backup.conf
```

Run a job file:

```sh
backup --run-job backup.conf
```

`--job FILE` is an alias for `--run-job FILE`.

Override the job file's retention policy for a single run:

```sh
backup --run-job backup.conf --retention-policy count:14
```

Job-management commands do not accept positional output/input paths and cannot be combined with one-shot archive options such as `--manifest`, `--compression`, `--symlinks`, `--encrypt`, `--verify`, `--extract`, size limits, password options, or incremental options. Those values belong in the job file when a job is being used.

## Job file format

The job file is a deterministic line-oriented `key=value` format. Blank lines and lines whose first non-space character is `#` are ignored. Keys and values are trimmed around the `=` separator. Unknown keys, malformed lines, unsupported values, duplicate scalar keys, and missing required fields are rejected with explicit diagnostics.

Repeated keys are only allowed for:

- `source=PATH`
- `input=PATH` as an alias for `source=PATH`
- `ignore=PATH`

All other keys are scalar and may appear at most once.

A job file must start with, or at least contain, the format marker:

```text
format=backup-job-v1
```

## Complete key reference

| Key | Required | Values | Meaning |
| --- | --- | --- | --- |
| `format` | yes | `backup-job-v1` | Job format marker. |
| `name` | no | text | Name shown in execution reports. |
| `source` / `input` | yes, repeated | filesystem path | Source input path. Duplicate normalized sources are rejected. |
| `ignore` | no, repeated | existing ordinary file | Ignore-rule file. Repeated entries preserve order. |
| `output` | yes | archive path | Base destination archive path. Must not also be an input path. |
| `output_naming` | no | `exact`, `sequence` | Destination naming policy. Default is `exact`. |
| `archive_naming` | no | `exact`, `sequence` | Compatibility alias for `output_naming`. |
| `prefix` | no | valid archive prefix | Prefix applied to archived paths. |
| `compression` | no | `auto`, `store`, `deflate`, `bzip2`, `lzma`, `zstd` | Compression policy. Default is `auto`. BZip2, bounded ZIP-LZMA, and Zstandard ZIP creation are in-process through zlib; unencrypted BZip2, bounded ZIP-LZMA, and Zstandard ZIP verification/extraction, including ZIP64 metadata, are also in-process. ZIP method ids are stable: bzip2=12, lzma=14, zstd=93 for created archives, with legacy zstd method 20 accepted on read. ZIP PPMd (method 98) is not supported: it is PPMd var.I, which zlib does not implement. |
| `symlinks` | no | `skip`, `store-link`, `follow` | Symlink policy. Default is `skip`. |
| `deterministic` | no | `true`, `false` | Enables deterministic-mode validation. Encrypted deterministic jobs are rejected. |
| `manifest` | no | `true`, `false` | Include the backup manifest. |
| `list_json` | no | `true`, `false` | Request machine-readable workflow output where supported. |
| `dry_run` | no | `true`, `false` | Plan without creating or deleting archives. |
| `max_file_size` | no | decimal byte count, or empty | Per-file size limit. Empty means unset. |
| `max_total_size` | no | decimal byte count, or empty | Total uncompressed-size limit. Empty means unset. |
| `incremental_from` | no | existing ordinary archive file | Plan against a previous archive. Mutually exclusive with `incremental_from_manifest`. |
| `incremental_from_manifest` | no | existing ordinary manifest file | Plan against a previous manifest. Mutually exclusive with `incremental_from`. |
| `encrypt` | no | `true`, `false` | Create an encrypted archive envelope. Requires a password source. |
| `password_file` | conditional | existing ordinary file | Password source for encrypted archive creation or encrypted prior archives. |
| `password_env` | conditional | non-empty environment variable name | Environment password source. |
| `password_prompt` | conditional | `true`, `false` | Prompt interactively for the password when the job runs. |
| `cipher` | no | `aes256-gcm` | Cipher identifier. |
| `verify_after` | no | `true`, `false` | Run archive verification after a successful backup. Dry-run reports this phase as skipped. |
| `retention_after` | no | `true`, `false` | Run retention cleanup after backup and optional verification. |
| `retention` | no | see below | Retention policy. Default is `none`. |
| `schedule` | no | see below | Parsed scheduling metadata. It does not cause background execution by itself. |

## Example job file

```text
format=backup-job-v1
name=nightly-home
source=/home/example/Documents
source=/home/example/Pictures
ignore=/home/example/.backupignore
output=/backups/home.zip
output_naming=sequence
compression=auto
symlinks=skip
deterministic=false
manifest=true
list_json=true
dry_run=false
max_file_size=
max_total_size=
incremental_from=
encrypt=true
password_file=/run/secrets/backup-password
password_prompt=false
cipher=aes256-gcm
verify_after=true
retention_after=true
retention=tiered:daily=7,weekly=4,monthly=12
schedule=external
```

## Destination naming

`output_naming=exact` writes exactly the configured `output` path after filesystem path normalization.

`output_naming=sequence` treats the configured `output` path as a base name. For `output=/backups/home.zip`, the first run selects `/backups/home-000001.zip`; the next run selects the first missing six-digit sequence path. The selection is deterministic and only scans for existence of candidate sequence names.

## Retention policies

`retention=none` keeps all managed archives.

`retention=count:N` keeps the newest `N` managed archives and selects the rest for deletion. `count:0` is valid and means delete all managed candidates.

`retention=age-days:N` deletes managed archives whose age is strictly greater than `N` whole days at evaluation time.

`retention=tiered:daily=N,weekly=N,monthly=N` keeps the newest daily representatives first, then distinct age-week representatives, then distinct calendar-month representatives. At least one bucket count must be non-zero. Deletion order is deterministic after newest-first ordering and path tie-breaking.

Retention selection is based on `Ada.Calendar.Time` values and deterministic path ordering for equal timestamps.

## Retention safety model

Retention never receives arbitrary filesystem paths from user-provided globs. The execution path builds a managed candidate set from ordinary files in the configured output directory only.

For `output_naming=exact`, only the exact configured archive name, for example `home.zip`, is managed.

For `output_naming=sequence`, the managed set includes the configured base archive name and six-digit sequence siblings derived from that base, for example `home.zip`, `home-000001.zip`, and `home-000002.zip`.

`Select_Retention_Deletions` also refuses any candidate not explicitly marked as managed, which protects the lower-level retention selector from accidental misuse.

## Scheduling metadata boundary

The `schedule` key is constrained metadata for external scheduler integration or a future scheduler adapter. It is parsed and validated, but it does not start a background daemon and does not make the tool run asynchronously.

Accepted values are:

- `external`
- `manual`
- `disabled`
- `interval-hours:N`, where `N > 0`
- `daily-at:HH:MM`, where `HH:MM` is in the `00:00` through `23:59` range

The explicit execution command remains:

```sh
backup --run-job backup.conf
```

This boundary keeps scheduling orchestration separate from archive correctness. Every job run still uses the existing scan, ignore, compression, deterministic metadata, ZIP64, symlink, verification, extraction compatibility, incremental planning, and encryption invariants.

## Execution marker and interrupted runs

Before running a job, the executor creates `JOB_FILE.running`. If that marker already exists, the run fails with `Job_Interrupted` and reports the marker path. A successful run, backup failure, verification failure, or retention failure removes the marker before returning. This makes an interrupted previous execution visible instead of allowing a later scheduled run to silently overwrite state.

## Job execution report

`Backup.Jobs.Execute` returns structured status through `Job_Status` and places a deterministic JSON report in the diagnostic string for runs that reach workflow execution. The report has stable key ordering:

```json
{
  "job": "nightly-home",
  "output": "/backups/home-000001.zip",
  "phases": [
    {"phase": "backup", "status": "ok", "message": "created /backups/home-000001.zip"},
    {"phase": "verify", "status": "ok", "message": "verified"},
    {"phase": "retention", "status": "ok", "message": "deleted 1"}
  ]
}
```

Dry-run jobs use `planned` backup wording, skip post-backup verification, and report retention deletions as planned without deleting files.

## Failure semantics

A malformed or unsupported job file fails before archive creation. Backup failure stops verification and retention. Verification failure stops retention. Retention failure is reported explicitly and is never silently ignored. Encrypted jobs require exactly one password source through `password_file`, `password_env`, or `password_prompt=true`; `password_file` values must identify existing ordinary files.
