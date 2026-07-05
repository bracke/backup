# Testing

The active release test command is:

```sh
cd tests
alr build
./bin/tests
```

The active runner covers all 16 test procedures under `tests/src`, including catalog, compression, encryption, incremental planning, manifest generation, remote synchronization, restore, scanner, verify, workflow, ZIP, path, CLI, ignore-rule, and job-retention coverage.

The aggregate release command is:

```sh
tools/bin/check_all
```


`tests/tests.gpr` builds the AUnit runner in `tests.adb`; `All_Suites` aggregates `Backup_Suite`, which registers every maintained backup test procedure as an AUnit routine. `docs/LEGACY_TESTS.md` should remain empty unless a future test is deliberately moved out of the active release runner.

## HTTP Remote Live Test

`backup_http_remote_live_tests` starts an Ada loopback HTTP fixture with `GNAT.Sockets` and exercises HTTP remote upload, GET verification, download, delete, inventory reads, and index publishing. `tools/bin/check_all` runs it after the active unit-style test runner.

CI runs both `tests` and `backup_http_remote_live_tests` on `windows-latest` and `macos-latest` after building the test project, so Windows and macOS coverage are execution coverage rather than build-only coverage.

## Always-On Provider Simulation

`tools/bin/check_all` always runs the loopback HTTP remote live test and all compatibility gate binaries. Offline development runs therefore exercise maintained provider simulators for S3, Google Drive, pCloud, and Proton Drive fail-closed behavior without requiring cloud credentials. Strict CI runs can still require real-provider credentials, but fixture fallback must remain an explicit, tested path for local release checks.

## S3 Compatibility Gate

`tools/bin/check_all` runs `tools/bin/check_s3_compatibility` as part of every release check. Local offline runs without `BACKUP_S3_COMPAT_REMOTE` execute the maintained loopback S3 fixture in `backup_http_remote_live_tests`, which covers SigV4 request signing, SSE headers, multipart upload, index publication, inventory reads, download, and delete without requiring cloud credentials.

CI and strict release runs require real-provider settings unless `BACKUP_S3_COMPAT_ALLOW_FIXTURE=1` is set as an explicit offline exception. Set `BACKUP_S3_COMPAT_STRICT=1` to enforce the same policy outside CI. For a real S3-compatible provider, set `BACKUP_S3_COMPAT_REMOTE=s3://BUCKET/PREFIX/`, `BACKUP_S3_COMPAT_ENDPOINT=URL`, and credentials through `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or `BACKUP_S3_COMPAT_ACCESS_KEY_ENV`/`BACKUP_S3_COMPAT_SECRET_KEY_ENV`. Optional settings include `BACKUP_S3_COMPAT_REGION`, `BACKUP_S3_COMPAT_SESSION_TOKEN_ENV`, `BACKUP_S3_COMPAT_ADDRESSING`, `BACKUP_S3_COMPAT_SSE`, and `BACKUP_S3_COMPAT_KMS_KEY_ID`. Real-provider mode uploads a multipart archive, verifies the remote object, and restores it to prove end-to-end compatibility.


## Google Drive Compatibility Gate

`tools/bin/check_all` runs `tools/bin/check_google_drive_compatibility` as part of every release check. Local offline runs without `BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE` execute the maintained loopback Google Drive fixture in `backup_http_remote_live_tests`, which covers OAuth bearer auth, file lookup, upload/update, index publication, inventory reads, download, delete, shared-drive query flags, and retry handling without requiring cloud credentials.

CI and strict release runs require real-provider settings unless `BACKUP_GOOGLE_DRIVE_COMPAT_ALLOW_FIXTURE=1` is set as an explicit offline exception. Set `BACKUP_GOOGLE_DRIVE_COMPAT_STRICT=1` to enforce the same policy outside CI. For real Google Drive, set `BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE=gdrive://FOLDER_ID/PREFIX/` and provide OAuth credentials through `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN`, an alternate variable named by `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_ENV`, `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_FILE`, or refresh-token credentials (`BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN`, `BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_ID`, `BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_SECRET`, and optional `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_URI`). Optional settings include `BACKUP_GOOGLE_DRIVE_COMPAT_API_BASE`, `BACKUP_GOOGLE_DRIVE_COMPAT_UPLOAD_BASE`, `BACKUP_GOOGLE_DRIVE_COMPAT_SUPPORTS_ALL_DRIVES`, and `BACKUP_GOOGLE_DRIVE_COMPAT_DRIVE_ID`. Project remote configs support the same token-file and refresh-token credential modes. Real-provider mode uploads an archive, verifies the remote object, and restores it to prove end-to-end compatibility. Release CI should run with `BACKUP_GOOGLE_DRIVE_COMPAT_STRICT=1`; fixture fallback is only for explicit offline development runs.


## pCloud Compatibility Gate

`tools/bin/check_all` runs `tools/bin/check_pcloud_compatibility` as part of every release check. Local offline runs without `BACKUP_PCLOUD_COMPAT_REMOTE` execute the maintained loopback pCloud fixture in `backup_http_remote_live_tests`, which covers OAuth bearer auth, folder-path creation with `createfolderifnotexists`, file lookup, temporary upload plus `renamefile` publication, index publication, inventory reads, download, delete, token-file auth, JSON response parsing, `progresshash` upload tracking, `uploadprogress` polling, quota preflight, parent-folder fallback creation, token-cache writes, recursive temporary cleanup, pCloud preflight checks, and provider result-code diagnostics without requiring cloud credentials.

CI and strict release runs require real-provider settings unless `BACKUP_PCLOUD_COMPAT_ALLOW_FIXTURE=1` is set as an explicit offline exception. Set `BACKUP_PCLOUD_COMPAT_STRICT=1` to enforce the same policy outside CI. For real pCloud, set `BACKUP_PCLOUD_COMPAT_REMOTE=pcloud://FOLDER_ID/PREFIX/` or a folder-path URL such as `pcloud://Backups/backup-ci/` and provide OAuth credentials through `BACKUP_PCLOUD_COMPAT_TOKEN`, an alternate variable named by `BACKUP_PCLOUD_COMPAT_TOKEN_ENV`, or `BACKUP_PCLOUD_COMPAT_TOKEN_FILE`. Optional settings include `BACKUP_PCLOUD_COMPAT_PATH_REMOTE` for an additional real-provider folder-path namespace, `BACKUP_PCLOUD_COMPAT_REGION=auto/us/eu`, and `BACKUP_PCLOUD_COMPAT_API_BASE`, normally `https://api.pcloud.com` for US accounts or `https://eapi.pcloud.com` for EU accounts. Real-provider mode uploads an archive, verifies the remote object, and restores it to prove end-to-end compatibility. Release CI should run with `BACKUP_PCLOUD_COMPAT_STRICT=1`; fixture fallback is only for explicit offline development runs.
