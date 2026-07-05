# backup

`backup` is an Ada command-line backup utility. It scans input trees, applies ignore rules, writes ZIP archives, supports manifests, incremental planning, direct archive listing, verification, filtered restore workflows, retention jobs, and local remote-style synchronization helpers.

## CLI Basics

```sh
backup --help
backup --help-advanced
backup --version
backup --encrypt --password-prompt OUT.benc INPUT
```

## Build

Use Alire GNAT 15 only. The root and tests manifests pin
`gnat_native = "=15.2.1"`. Confirm with:

```sh
alr exec -- gnatls --version
```

Do not run plain system `gnat*`, `gnatmake`, `gnatls`, `gnatprove`,
`gprbuild`, or `gprinstall` in this workspace. Use `alr exec -- ...` for
compiler, prover, installer, and builder commands so PATH cannot select a
different GNAT installation.

```sh
alr build
```

The executable is written to `bin/backup`.

`backup` depends on the sibling `zlib`, `cryptolib`, `ssh_lib`, `httpclient`, `terminal_styles`, and `i18n` crates.
The ZIP container layout, local headers, central directory records, and ZIP data
descriptors remain in `backup`; raw Deflate payload writing, size calculation,
and CRC32 helpers are provided by zlib. Proton Drive metadata hashing/MAC helpers are provided by cryptolib. SSH remote-name parsing is provided by
ssh_lib. Human-facing terminal help and diagnostics use terminal_styles and render
localized text through i18n; JSON outputs remain unstyled for scripts. Archive transfer operations are enabled for `file://` remotes, HTTP/HTTPS object
URLs, S3-compatible object storage, and pCloud HTTP/JSON storage; HTTP/HTTPS/S3/pCloud object uploads stream
archive bytes through HttpClient fixed-length request bodies. SSH/SFTP `--remote-resume` appends the missing suffix to a shorter remote object through `ssh_lib`; pCloud `--remote-resume` can reuse matching provider-side final or temporary objects, while mid-stream pCloud HTTP/JSON uploads still restart if the provider did not store the object. Remote transports require the
application link options for OpenSSL (`-lssl -lcrypto`).
For real archive creation, deflated files are prepared once as reusable
raw-Deflate payloads so manifest/report size metadata and ZIP emission share
the same compressed bytes. Dry-run and direct metadata helpers may still use
zlib's size-only calculation because no archive payload is emitted there.
Whole-archive `--encrypt` envelopes use cryptolib AES-256-GCM with
BCrypt-PBKDF-derived keys, production-random salt/nonce metadata, and
authentication-before-use handling for verify, restore, catalog indexing, and
incremental planning.

## Tests

```sh
cd tests
alr build
./bin/tests
```

The active release test runner covers all 16 maintained test procedures, including catalog, compression, encryption, incremental, manifest, remote, restore, scanner, verify, workflow, ZIP, path, CLI, ignore-rule, and job-retention coverage.

## Ignore Rules

`--ignore FILE` and discovered `.gitignore` files support anchored rules,
directory-only rules, `!` re-inclusion, `*`, `?`, `**` path components,
bracket character classes such as `[0-9]` and `[!0-9]`, and literal escapes
for leading `#`/`!`, spaces, `?`, `[`, and `]`. Backslashes that do not form
one of those escapes are treated as host path separators, so `obj\*.o`
continues to normalize to `obj/*.o`.

## Restore and Listing

Use `--list ARCHIVE.zip` to inspect archive contents directly. Add `--list-json` for machine-readable output. Add `--json-errors` when scripts need failures emitted as a single `backup-error-v1` JSON object with `status` and `message` fields.

Restore supports path filters and explicit conflict handling:

```sh
backup --extract ARCHIVE.zip --output-dir OUT --only path/in/archive
backup --extract ARCHIVE.zip --output-dir OUT --exclude path/in/archive
backup --extract ARCHIVE.zip --output-dir OUT --skip-existing
backup --extract ARCHIVE.zip --output-dir OUT --overwrite
backup --extract ARCHIVE.zip --output-dir OUT --rename-existing
```

The default restore conflict policy remains conservative: existing destination paths are rejected. `--skip-existing` leaves existing paths untouched, `--overwrite` replaces existing ordinary files only, and `--rename-existing` moves existing destinations to a `.existing.N` sibling before restore. Regular file mtime, Unix executable/file mode, uid/gid ownership metadata, extended attributes, and POSIX ACL xattrs are preserved on restore when supported by the runtime and destination filesystem. Unsupported metadata operations are skipped best-effort so archives remain portable across non-POSIX or restricted targets. Traditional ZipCrypto and WinZip AES-encrypted stored and deflated ZIP entries can be listed, verified, and extracted with `--password-file`, `--password-env`, or `--password-prompt`. Complete split ZIP sets using numbered `.z01`, `.z02`, ... parts plus the final `.zip` file are assembled for listing, verification, and extraction. ZIP bzip2, bounded ZIP-LZMA, and Zstandard creation and unencrypted verification/extraction for classic and ZIP64 metadata are in-process through zlib. ZIP method ids are stable: bzip2 uses method 12, LZMA uses method 14, Zstandard uses method 93 for created archives and accepts legacy method 20 on read, and PPMd uses method 98. ZIP PPMd creation and verification/extraction use a local `7z` executable; if `7z` is unavailable or cannot encode/decode PPMd, backup fails closed.


## Advanced CLI Reference

### Remote Operations

`backup` supports `file://`, HTTP, HTTPS, S3-compatible object remotes, Google Drive, pCloud, SSH/SFTP remotes, and a fail-closed Proton Drive SDK layer. SSH and scp-like remote names are resolved through the sibling `ssh_lib` library and use OpenSSH-style host/user/identity/known-host and `ProxyCommand` configuration.

```sh
backup --upload --remote file:///backups/remote/ OUT.zip INPUT
backup --upload --remote https://example.test/backups/nightly.zip OUT.zip INPUT
backup --upload --remote s3://my-bucket/backups/ OUT.zip INPUT
backup --upload --remote user@example.com:/srv/backups/ OUT.zip INPUT
backup --sync --remote file:///backups/remote/ OUT.zip INPUT
backup --restore-remote --remote https://example.test/backups/nightly.zip LOCAL.zip
backup --verify LOCAL.zip --remote https://example.test/backups/nightly.zip
```

Remote options:

- `--remote URL` selects the remote namespace or object URL.
- `--remote-config FILE` reads deterministic `key=value` remote settings.
- `--upload` creates a local archive and uploads it after creation.
- `--sync` creates a local archive and reconciles managed remote objects.
- `--restore-remote` downloads a remote archive to the local path argument.
- `--remote-require-encrypted` rejects remote upload/sync unless `--encrypt` is active.
- `--remote-resume` promotes matching partial/provider-side uploads where the selected backend supports safe recovery.
- `--list-json` selects machine-readable remote reports where supported.

Remote config files support `remote=`/`url=`, `require_encrypted=`, `resume=`,
`retry_count=`, `timeout_seconds=`, HTTP bearer/basic/custom-header settings,
HTTPS trust/client-certificate settings, S3 settings (`s3_endpoint=`,
`s3_region=`, `s3_profile=`, `s3_credentials_file=`, `s3_config_file=`,
`s3_web_identity_token_file=`, `s3_role_arn=`, `s3_credential_process=`,
`s3_sso_session=`, `s3_sso_start_url=`, `s3_sso_region=`,
`s3_sso_account_id=`, `s3_sso_role_name=`, `s3_addressing=`,
`s3_server_side_encryption=`, `s3_sse_kms_key_id=`, `s3_acl=`,
`s3_storage_class=`, `s3_tagging=`, `s3_metadata_name=`,
`s3_metadata_value=`, `s3_cache_control=`, `s3_content_disposition=`,
`s3_content_encoding=`, `s3_object_lock_mode=`,
`s3_object_lock_retain_until=`, `s3_object_lock_legal_hold=`,
`s3_multipart_threshold=`,
`s3_multipart_part_size=`, `s3_access_key=`/`s3_access_key_env=`,
`s3_secret_key=`/`s3_secret_key_env=`, `s3_session_token=`/`s3_session_token_env=`).
Remote backends include file, HTTP/HTTPS, S3-compatible storage,
`gdrive://FOLDER_ID/PREFIX/` Google Drive remotes, and
`pcloud://FOLDER_ID/PREFIX/` pCloud remotes. See `REMOTE_TRANSPORT.md`
for the full transport contract, HTTP index format, authentication keys,
retry/timeout semantics, and scheduled remote retention behavior.
`docs/IDRIVE_E2.md` provides an IDrive e2 S3-compatible configuration example. `docs/PROTON_DRIVE.md` documents the Proton Drive SDK layer and its current fail-closed backend status.  `docs/PCLOUD.md` describes pCloud folder-id and folder-path URL forms, OAuth token setup, the `--pcloud-oauth-url` and config-hinting `--pcloud-oauth-token` helpers, refresh-token setup, troubleshooting, and provider-specific behavior. pCloud remotes use `pcloud_region=auto/us/eu` or `pcloud_api_base=https://api.pcloud.com` / `https://eapi.pcloud.com` for explicit account-region selection plus `pcloud_access_token`, `pcloud_access_token_file`, `pcloud_access_token_env`, or refresh-token keys; `pcloud_large_upload_threshold=BYTES` selects the streamed large-upload path, `pcloud_upload_progress=true` sends pCloud upload progress hashes, `pcloud_poll_progress=true` polls `uploadprogress`, `pcloud_check_quota=true` enables quota preflight, `pcloud_create_parents=true` creates missing path parents, `pcloud_token_cache_file=PATH` stores refreshed tokens, `--pcloud-check` validates token/region/quota/namespace settings, and `--pcloud-clean-temp` removes stale backup-managed pCloud upload temporaries.

### Catalog Operations

`--catalog FILE` attaches an explicit catalog operation or requests automatic
post-run indexing after archive creation/verification.

```sh
backup --catalog catalog.db --index archive.zip
backup --catalog catalog.db --index encrypted.benc --password-file pass.txt
backup --catalog catalog.db --query content:path-fragment
backup --catalog catalog.db --query verification:trusted --list-json
backup --catalog catalog.db --list-archives
backup --catalog catalog.db --list-contents
backup --catalog catalog.db --verify-catalog
backup --catalog catalog.db OUT.zip INPUT
backup --verify OUT.zip --catalog catalog.db
```

Catalog commands:

- `--index ARCHIVE.zip` imports or updates one archive record.
- `--query FIELD:VALUE` searches catalog archive and entry records.
- `--list-archives` lists archive records only.
- `--list-contents` lists entry records.
- `--verify-catalog` validates catalog structure and referenced archive metadata.

Supported query fields are `archive`, `date`, `content`, `source`, `lineage`,
`remote`, `remote-verified`, `verification`, `manifest`, `encrypted`, `size`,
`crc32`, `method`, `kind`, and `retention`. `remote-verified` accepts
`true`/`false`, `yes`/`no`, or `1`/`0`; `encrypted` accepts the same boolean
forms plus `envelope` and `none`; `method` accepts `store`, `deflate`, `bzip2`,
`lzma`, `zstd`, `ppmd`, or a numeric method id (`0`, `8`, `12`, `14`, `20`,
`93`, or `98` for the built-in named methods); and `kind` accepts `file`,
`directory`, `symlink`, or `manifest`. Catalog management commands are mutually
exclusive with extraction, remote restore, and job-management commands.
Encrypted archive indexing may combine `--index` with a password source to
record verified searchable entry metadata while keeping the archive marked as an
encrypted envelope. See `CATALOG.md` for the on-disk format, trust model, query
semantics, and interrupted-update recovery diagnostics.

### Job And Retention Operations

Jobs persist backup configuration in a deterministic `key=value` file and run
through the same workflow as ordinary archive creation.

```sh
backup --create-job backup.conf
backup --run-job backup.conf
backup --job backup.conf
backup --run-job backup.conf --retention-policy count:14
```

Job options:

- `--create-job FILE` writes a template job file.
- `--run-job FILE` executes a job file.
- `--job FILE` is an alias for `--run-job FILE`.
- `--retention-policy POLICY` overrides the job retention policy for one run.

Job files support repeated `source=`/`input=` and `ignore=` keys plus scalar
settings for `output=`, `output_naming=`, `compression=`, `symlinks=`,
`manifest=`, `deterministic=`, size limits, incremental sources, encryption,
post-backup verification, retention, remote upload/sync, catalog indexing, and
`schedule=` metadata. `schedule=` is validated metadata only; it does not install
or start a daemon or host scheduler task. See `JOBS_RETENTION.md` for the
complete key reference, retention policies, execution marker behavior, and
failure semantics.

## Installed User Files

The install target includes user-facing support files under `share`: localized
messages at `share/backup/messages.catalog`, a man page at
`share/man/man1/backup.1`, Bash, Fish, PowerShell, and Zsh completions under `share/completions`,
and an example job file under `share/examples/backup`.
`tools/bin/package_release` stages the installed tree, writes a manifest, creates
a tarball, and records a checksum for release-package smoke testing. The installed man page, advanced-help catalog entries, shell completions, generated Ada help-order package, and `docs/CLI_SURFACE.md` command-mode contract are generated from `tools/cli_surface.conf` by `tools/bin/generate_cli_surface` and checked by `tools/bin/check_cli_surface` during release verification. Bash completion can be enabled by sourcing `share/completions/backup.bash` or by
installing it into a system Bash completion directory. Fish completion is
provided as `share/completions/backup.fish`; PowerShell completion is
provided as `share/completions/backup.ps1`; Zsh completion is provided as
`share/completions/_backup`.

## Release Check

```sh
alr exec -- gnatprove -P backup_spark.gpr --level=4
alr exec -- gprbuild -P tools/tools.gpr
tools/bin/check_all
```

`backup --help-advanced` prints localized remote, catalog, job, incremental, encryption, restore, and diagnostic options without requiring the README as the only local reference.

`tools/bin/check_all` builds the crate, runs an install smoke with `gprinstall`, runs the installed `backup --version`, runs the GNATprove level-4 proof, builds the active test runner, runs the active tests, and verifies the expected release documentation and generated-artifact hygiene surface. CI also builds the main project and runs both maintained test executables on `windows-latest` and `macos-latest`. Completion smoke tests fail in CI if Fish, Zsh, or PowerShell are unavailable, while local runs may still skip missing optional shells. The checker is built through `tools/tools.gpr` and uses the sibling `project_tools` library, matching the local project layout used by the other Ada crates.

## Documentation

- `docs/RELEASE.md` documents release verification.
- `docs/CLI_SURFACE.md` is the generated command-mode, conflict-group, and option contract.
- `docs/CLI_COMPATIBILITY.md` documents CLI compatibility, deprecation, and breaking-change policy.
- `docs/PORTABILITY.md` documents platform-specific metadata behavior and the Windows source-selection check.
- `docs/IDRIVE_E2.md` documents how to use IDrive e2 through the S3-compatible backend.
- `docs/TESTING.md` describes the active and legacy test split.
- `docs/SPARK.md` documents the current GNATprove release gate.
- `docs/LEGACY_TESTS.md` records that no repaired tests are currently outside release readiness.
- `docs/SYMLINKS.md` documents symlink archive and restore behavior.
- `docs/history/` keeps older phase-completeness notes out of the root release surface.
