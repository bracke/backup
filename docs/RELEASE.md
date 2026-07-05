# Release Verification

Use Alire GNAT 15 only. The root and tests manifests pin
`gnat_native = "=15.2.1"`. Confirm with:

```sh
alr exec -- gnatls --version
```

Do not run plain system `gnat*`, `gnatmake`, `gnatls`, `gnatprove`,
`gprbuild`, or `gprinstall` in this workspace. Use `alr exec -- ...` for
compiler, prover, installer, and builder commands so PATH cannot select a
different GNAT installation.

Run the aggregate release checker from the repository root:

```sh
tools/bin/check_all
```

The checker requires:

- the Windows platform source-selection check compiles with `BACKUP_TARGET_OS=windows`
- root `alr build` succeeds and produces `bin/backup`
- `alr exec -- gprinstall -p -P backup.gpr --prefix=/tmp/backup-install-smoke` succeeds
- the installed `backup --version` executable runs from the temporary install prefix
- installed project/source artifacts exist under `bin`, `include/backup`, and `share/gpr`
- installed user support files exist under `share/backup`, `share/man`, `share/completions`, and `share/examples/backup`
- Bash completion smoke sources `share/completions/backup.bash` and verifies option/value completion
- Fish, Zsh, and PowerShell completion smoke scripts, the S3, Google Drive, and pCloud compatibility gates require real providers in CI unless their explicit `*_ALLOW_FIXTURE=1` escape hatches are set; Linux CI installs Fish, Zsh, and PowerShell before running the release checker, passes `BACKUP_S3_COMPAT_REMOTE`, `BACKUP_S3_COMPAT_ENDPOINT`, `BACKUP_S3_COMPAT_ACCESS_KEY`, `BACKUP_S3_COMPAT_SECRET_KEY`, `BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE`, `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN`, `BACKUP_PCLOUD_COMPAT_REMOTE`, and `BACKUP_PCLOUD_COMPAT_TOKEN` from repository secrets, and the completion scripts fail instead of skipping when `CI=true` or `BACKUP_COMPLETION_STRICT=1`
- release package smoke creates a staged tarball and checksum under `/tmp`
- `alr exec -- gnatprove -P backup.gpr --level=4` succeeds
- `tests/alire.toml` pins the root crate and `tests/tests.gpr` builds the active runner for all 16 test procedures
- `tests/bin/tests` passes the active stable test suite
- `tests/bin/backup_http_remote_live_tests` runs the deterministic local Ada HTTP/HTTPS fixture for upload, download, verify, index, delete, auth, TLS, and retry coverage
- CI is wired to run `tools/bin/check_all` on Linux
- CI checks out every local sibling pin, including `terminal_styles` and `i18n`
- CI builds the main project and runs both maintained test executables on `windows-latest` and `macos-latest`
- the release checker is built through `tools/tools.gpr` against the sibling `project_tools` library
- generated Alire, config, object, binary, proof, and temporary test artifacts are ignored
- checked-in man page, advanced-help catalog entries, shell completions, generated Ada help-order package, and `docs/CLI_SURFACE.md` command-mode contract match `tools/cli_surface.conf` through `tools/bin/generate_cli_surface`
- `docs/CLI_COMPATIBILITY.md` documents the compatibility policy for released options, command modes, enum values, deprecations, and breaking changes
- historical phase-completeness notes live under `docs/history` instead of the repository root

`docs/LEGACY_TESTS.md` documents that no repaired test is currently outside the active release runner.

## S3 CI Provider Secrets

Linux CI expects these repository secrets for the real-provider S3 compatibility gate:

- `BACKUP_S3_COMPAT_REMOTE`, an isolated `s3://BUCKET/PREFIX/` namespace used only by CI
- `BACKUP_S3_COMPAT_ENDPOINT`, the S3-compatible endpoint URL
- `BACKUP_S3_COMPAT_ACCESS_KEY` and `BACKUP_S3_COMPAT_SECRET_KEY`, scoped to that test namespace

Optional secrets are `BACKUP_S3_COMPAT_REGION`, `BACKUP_S3_COMPAT_ADDRESSING`, `BACKUP_S3_COMPAT_SSE`, and `BACKUP_S3_COMPAT_KMS_KEY_ID`. CI intentionally does not set `BACKUP_S3_COMPAT_ALLOW_FIXTURE`; missing provider settings fail the release job instead of silently using the loopback fixture.


## Google Drive CI Provider Secrets

Linux CI expects these repository secrets for the real-provider Google Drive compatibility gate:

- `BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE`, an isolated `gdrive://FOLDER_ID/PREFIX/` namespace used only by CI
- `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN`, an OAuth access token scoped to that test namespace

Instead of `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN`, the gate can read an access token
from `BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_FILE`, or exchange
`BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN` with
`BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_ID` and
`BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_SECRET`. Optional settings are
`BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_URI`, `BACKUP_GOOGLE_DRIVE_COMPAT_SUPPORTS_ALL_DRIVES`,
and `BACKUP_GOOGLE_DRIVE_COMPAT_DRIVE_ID` for shared-drive coverage. CI
intentionally does not set `BACKUP_GOOGLE_DRIVE_COMPAT_ALLOW_FIXTURE`; missing
provider settings fail the release job instead of silently using the loopback fixture.


## pCloud CI Provider Secrets

Linux CI expects these repository secrets for the real-provider pCloud compatibility gate:

- `BACKUP_PCLOUD_COMPAT_REMOTE`, an isolated `pcloud://FOLDER_ID/PREFIX/` or folder-path namespace used only by CI
- `BACKUP_PCLOUD_COMPAT_PATH_REMOTE`, optional but recommended, an isolated folder-path namespace used only by CI
- `BACKUP_PCLOUD_COMPAT_TOKEN`, an OAuth access token scoped to that test namespace
- `BACKUP_PCLOUD_COMPAT_REGION`, optional, usually `auto`, `us`, or `eu`
- `BACKUP_PCLOUD_COMPAT_STRICT`, optional, set to `1` for local release runs that must use the real provider

Instead of `BACKUP_PCLOUD_COMPAT_TOKEN`, the gate can read an access token from `BACKUP_PCLOUD_COMPAT_TOKEN_FILE`. Optional settings are `BACKUP_PCLOUD_COMPAT_PATH_REMOTE` for an additional folder-path provider run, `BACKUP_PCLOUD_COMPAT_REGION=auto/us/eu`, `BACKUP_PCLOUD_COMPAT_STRICT=1` to require real-provider coverage, and `BACKUP_PCLOUD_COMPAT_API_BASE`, normally `https://api.pcloud.com` for US accounts or `https://eapi.pcloud.com` for EU accounts. CI intentionally does not set `BACKUP_PCLOUD_COMPAT_ALLOW_FIXTURE`; missing provider settings fail the release job instead of silently using the loopback fixture.
