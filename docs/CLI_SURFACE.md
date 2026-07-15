# CLI Surface Contract

This file is generated from `tools/cli_surface.conf` by `tools/bin/generate_cli_surface`.
Do not edit it directly.

## Command Modes

| Mode | Selector | Positionals | Notes |
| --- | --- | --- | --- |
| `create` | `default` | `OUT.zip INPUT...` | creates a local archive; may combine with --catalog FILE for post-run indexing |
| `list` | `--list ARCHIVE.zip` | `none` | lists an existing archive; --list-json emits machine-readable output |
| `verify` | `--verify ARCHIVE.zip` | `none` | verifies an existing archive; may combine with --catalog FILE to update trust state |
| `extract` | `--extract ARCHIVE.zip` | `none` | requires --output-dir DIR and restore options only |
| `remote-upload` | `--upload --remote URL` | `OUT.zip INPUT...` | creates a local archive and uploads it after creation |
| `remote-sync` | `--sync --remote URL` | `OUT.zip INPUT...` | creates a local archive and reconciles managed remote objects |
| `remote-restore` | `--restore-remote --remote URL` | `LOCAL.zip` | downloads a remote archive to a local path |
| `catalog` | `--catalog FILE plus catalog command` | `none` | requires exactly one catalog command and no one-shot backup options |
| `job` | `--run-job FILE or --create-job FILE` | `none` | job management commands are mutually exclusive with one-shot backup options |
| `pcloud-oauth` | `--pcloud-oauth-url CLIENT_ID REDIRECT_URI` | `none` | prints a pCloud OAuth authorization URL and exits |
| `pcloud-token` | `--pcloud-oauth-token CLIENT_ID CLIENT_SECRET CODE REDIRECT_URI [API_BASE]` | `none` | exchanges a pCloud OAuth authorization code, prints token JSON and config hints, and exits |
| `proton-drive-login` | `--proton-drive-login SESSION_FILE USER_ADDRESS USERNAME PASSWORD_PROOF [MFA_CODE] [SESSION_LABEL] [APP_VERSION] [API_BASE]` | `none` | runs the configured Proton Drive auth provider flow, updates the session descriptor, and exits |
| `pcloud-clean-temp` | `--pcloud-clean-temp --remote URL` | `none` | deletes stale backup-managed pCloud temporary upload objects and exits |
| `pcloud-check` | `--pcloud-check --remote URL` | `none` | checks pCloud auth, account region, quota metadata, and configured namespace |

## Conflict Groups

| Group | Rule | Members | Diagnostic |
| --- | --- | --- | --- |
| `catalog-command` | `exactly-one` | `--index --query --list-archives --list-contents --verify-catalog` | choose exactly one catalog command |
| `job-command` | `at-most-one` | `--run-job --create-job` | choose only one job management command |
| `remote-direction` | `restore-exclusive` | `--upload --sync --restore-remote` | remote restore cannot be combined with upload or sync |
| `restore-conflict-policy` | `at-most-one` | `--skip-existing --overwrite --rename-existing` | choose only one restore conflict policy |

## Options

| Option | Value kind | Values | Description |
| --- | --- | --- | --- |
| `--help` | `none` |  | Show help |
| `--help-advanced` | `none` |  | Show advanced help |
| `--version` | `none` |  | Show version |
| `--manifest` | `none` |  | Write manifest |
| `--deterministic` | `none` |  | Use deterministic metadata |
| `--dry-run` | `none` |  | Plan without writing archive |
| `--list` | `file` |  | List archive contents |
| `--list-json` | `none` |  | Emit JSON listing |
| `--verify` | `file` |  | Verify archive |
| `--extract` | `file` |  | Extract archive |
| `--output-dir` | `file` |  | Restore output directory |
| `--only` | `text` |  | Restore only path |
| `--exclude` | `text` |  | Exclude restore path |
| `--skip-existing` | `none` |  | Leave existing files |
| `--overwrite` | `none` |  | Overwrite existing regular files |
| `--rename-existing` | `none` |  | Rename existing files |
| `--compression` | `enum` | `auto store deflate bzip2 lzma zstd` | Compression mode |
| `--symlinks` | `enum` | `skip store-link follow` | Symlink handling |
| `--ignore` | `file` |  | Ignore file |
| `--prefix` | `text` |  | Archive prefix |
| `--max-file-size` | `text` |  | Maximum file size |
| `--max-total-size` | `text` |  | Maximum total size |
| `--encrypt` | `none` |  | Encrypt output |
| `--password-file` | `file` |  | Password file |
| `--password-env` | `env` |  | Password environment variable |
| `--password-prompt` | `none` |  | Prompt for password |
| `--cipher` | `enum` | `aes256-gcm` | Encryption cipher |
| `--catalog` | `file` |  | Catalog file |
| `--index` | `file` |  | Catalog index file |
| `--query` | `text` |  | Catalog query |
| `--list-archives` | `none` |  | List catalog archives |
| `--list-contents` | `none` |  | List catalog contents |
| `--verify-catalog` | `none` |  | Verify catalog index |
| `--remote` | `text` |  | Remote URL |
| `--remote-config` | `file` |  | Remote config file |
| `--upload` | `none` |  | Upload archive |
| `--sync` | `none` |  | Sync remote namespace |
| `--restore-remote` | `none` |  | Download remote archive |
| `--remote-require-encrypted` | `none` |  | Require encrypted remote archives |
| `--remote-resume` | `none` |  | Resume remote transfer |
| `--create-job` | `file` |  | Write job file |
| `--run-job` | `file` |  | Run job file |
| `--job` | `file` |  | Run job file |
| `--retention-policy` | `enum` | `count: daily: weekly: monthly: tiered:` | Retention policy |
| `--incremental-from` | `file` |  | Incremental base archive |
| `--incremental-from-manifest` | `file` |  | Incremental base manifest |
| `--json-errors` | `none` |  | Emit JSON errors |
| `--pcloud-oauth-url` | `text` |  | Print pCloud OAuth authorization URL |
| `--pcloud-oauth-token` | `text` |  | Exchange pCloud OAuth code for token JSON and config hints |
| `--proton-drive-login` | `text` |  | Run Proton Drive auth provider flow and update session descriptor |
| `--pcloud-clean-temp` | `none` |  | Delete stale pCloud temporary upload objects |
| `--pcloud-check` | `none` |  | Check pCloud token, region, quota, and namespace |
