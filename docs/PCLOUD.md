# pCloud Remote Backend

`backup` can store archives and the remote inventory index in pCloud through the pCloud HTTP/JSON API. pCloud is not S3-compatible, so it is configured as a separate remote backend with `pcloud://` URLs.

## URL Forms

Two namespace forms are supported:

```sh
pcloud://0/backups/
pcloud://0/backups/nightly.zip
pcloud://Backups/project-a/
pcloud://Backups/project-a/nightly.zip
```

A numeric first component is treated as a pCloud folder id. `0` is the pCloud root folder. The remaining path is stored as part of the managed file name, so `pcloud://0/backups/nightly.zip` writes a file named `backups/nightly.zip` in folder id `0`.

A non-numeric namespace is treated as a pCloud folder path. Backup resolves it with `listfolder` for reads and creates it with `createfolderifnotexists` for writes. For example, `pcloud://Backups/project-a/nightly.zip` stores `nightly.zip` inside the pCloud folder path `Backups/project-a`.

Object names remain backup-managed archive names. Do not point multiple unrelated backup jobs at the same namespace unless they are meant to share one remote inventory.

## Authentication

Create a pCloud OAuth access token and provide it with one of these remote config keys:

```conf
pcloud_access_token=TOKEN
pcloud_access_token_file=/secure/path/pcloud-token
pcloud_access_token_env=BACKUP_PCLOUD_TOKEN
pcloud_token_cache_file=/secure/path/pcloud-refreshed-token
pcloud_refresh_token=REFRESH_TOKEN
pcloud_client_id=CLIENT_ID
pcloud_client_secret=CLIENT_SECRET
pcloud_token_uri=https://api.pcloud.com/oauth2_token
pcloud_region=auto
pcloud_upload_progress=true
pcloud_poll_progress=false
pcloud_check_quota=true
pcloud_create_parents=true
pcloud_clean_recursive=false
```

The default region setting is `pcloud_region=auto`, which probes `userinfo` on the US endpoint and then the EU endpoint when a token is available and no explicit API base is configured. Use `pcloud_region=us` or `pcloud_region=eu` to select a documented endpoint without probing. The explicit API-base form is still supported and takes precedence:

```conf
pcloud_api_base=https://api.pcloud.com
```

EU accounts can use either `pcloud_region=eu` or:

```conf
pcloud_api_base=https://eapi.pcloud.com
```

Scheduled jobs use the same keys with the `remote_` prefix, for example `remote_pcloud_access_token_env`, `remote_pcloud_api_base`, `remote_pcloud_region`, `remote_pcloud_token_cache_file`, `remote_pcloud_upload_progress`, `remote_pcloud_poll_progress`, `remote_pcloud_check_quota`, `remote_pcloud_create_parents`, and `remote_pcloud_clean_recursive`.

### Creating And Rotating Tokens

For non-interactive backup jobs, create a pCloud API application in the pCloud developer console and use the OAuth 2.0 authorization flow to obtain an access token. The pCloud developer docs expose an `authorize` endpoint for user approval and an `oauth2_token` endpoint for exchanging the authorization response. Backup can print the authorization URL with:

```sh
backup --pcloud-oauth-url CLIENT_ID REDIRECT_URI
```

Open the printed URL in a browser, approve the app, and exchange the returned authorization code with:

```sh
backup --pcloud-oauth-token CLIENT_ID CLIENT_SECRET CODE REDIRECT_URI
backup --pcloud-oauth-token CLIENT_ID CLIENT_SECRET CODE REDIRECT_URI https://eapi.pcloud.com
```

The command prints the provider token JSON plus ready-to-use access-token and refresh-token config snippets. Store the resulting access token in a secret manager or a file readable only by the backup user, then reference it with `pcloud_access_token_env` or `pcloud_access_token_file`. When the provider response includes a refresh token, scheduled jobs can instead use `pcloud_refresh_token` with `pcloud_client_id`, optional `pcloud_client_secret`, and optional `pcloud_token_uri`; backup exchanges it for a short-lived access token before pCloud requests. Set `pcloud_token_cache_file` to write the refreshed access token to a protected file so later runs can use it before falling back to refresh-token exchange. The cache is written through a temporary file and permission-hardened to mode `0600` on Unix-like platforms. Native Windows builds keep the atomic temp-and-rename write path and map the same `0600` request to `icacls.exe /inheritance:r /grant:r CURRENT_USER:(R,W)` so the refreshed token cache is restricted to the current Windows user when `icacls.exe` is available.

Avoid putting long-lived tokens directly in job files unless the file is already protected as a secret. Rotate tokens by adding the new token to the environment, token file, or refresh-token configuration, running a small restore or `--verify` operation, then revoking the old token from pCloud. Token failures normally surface as pCloud result codes `1000`, `2000`, or `2003` in backup diagnostics, with a region hint to check `https://api.pcloud.com` versus `https://eapi.pcloud.com`.

## Upload Semantics

Archive uploads use pCloud `uploadfile` with a temporary backup-managed name, then publish the final object with `renamefile`. pCloud documents `renamefile` as atomically replacing an existing destination and merging revisions when the destination exists. If `renamefile` fails after a successful temporary upload, backup makes a best-effort `deletefile` call for the temporary file id before returning the write failure. The same path is used for the text inventory object `backup-remote-index-v1`.

Backup verifies uploaded archives with pCloud `checksumfile` when SHA-256, SHA-1, or size metadata is available. The pCloud documentation states that `sha1` is returned by US and Europe API servers, `md5` is US-only, and `sha256` is Europe-only. Backup trusts matching `sha256` when present, then matching `sha1` when SHA-256 is absent, and otherwise falls back to downloading the object and checking size and CRC32.

`pcloud_large_upload_threshold=BYTES` selects the streamed `uploadfile` path for archives at or above the threshold. The pCloud HTTP/JSON `uploadfile` API does not expose a documented byte-offset resumable upload session, so a connection break before pCloud stores the object still requires a fresh stream. When `--remote-resume` is enabled, backup uses a deterministic pCloud temporary name for archive uploads and checks both the already-published final object and the deterministic temporary object with `checksumfile`, size metadata, or readback verification. A matching final object is reused without another `uploadfile` request; a matching temporary object is published with `renamefile`. This recovers runs where the provider accepted the upload but the client stopped before publish, verification, or index update. When `pcloud_upload_progress=true` is left at its default, backup sends a deterministic `progresshash` with each `uploadfile` request so provider-side upload progress can be queried while the request is active. Set `pcloud_poll_progress=true` to start a best-effort live `uploadprogress` monitor while archive `uploadfile` is active and to make a final provider compatibility check after upload completion. The transfer JSON report includes `pcloud_progress_samples` when live samples are observed. The monitor depends on provider response timing and is not a byte-for-byte local progress callback. The pCloud `uploadtransfer` API is intentionally not used because it imports transfer links rather than storing backup objects in the configured folder namespace. pCloud `uploadfile` supports `nopartial`; backup sets it so interrupted uploads are not saved as partial files. Backup also sets `renameifexists=0` for the temporary upload name and relies on the final `renamefile` operation for replacement semantics.

When `pcloud_check_quota=true` is left at its default, backup calls `userinfo` before pCloud uploads and refuses the upload if reported free quota is lower than the archive or index payload size. If pCloud omits quota fields, the check is informational and upload continues.

## Provider Capabilities And Limits

- Folder-id URLs are the most explicit form. `pcloud://0/prefix/` stores managed file names under root folder id `0`.
- Folder-path URLs call `createfolderifnotexists` for writes. When `pcloud_create_parents=true` is left at its default, backup falls back to creating missing folder-path components one at a time from root folder id `0`. Use a folder-id URL if path behavior is ambiguous or the token cannot create folders there.
- Existing destination files are replaced by `renamefile`, not by deleting the old object first. Backup does not manage pCloud revision history because this backend only relies on documented upload, rename, delete, list, checksum, and link methods; pCloud keeps or prunes revisions according to provider-side account behavior and settings.
- Temporary upload names include a per-upload nonce so concurrent uploads of the same archive name and size do not collide with each other or stale temp objects.
- Rate limits and transient provider failures are retried according to `retry_count`; pCloud result codes in the 4000/5000 ranges are treated as retryable.
- Backup does not use pCloud binary protocol, WebDAV, transfer links, or public links.

## Example

```conf
remote=pcloud://Backups/server-a/
pcloud_region=auto
pcloud_api_base=https://api.pcloud.com
pcloud_access_token_env=BACKUP_PCLOUD_TOKEN
# or: pcloud_refresh_token=... with pcloud_client_id=...
pcloud_large_upload_threshold=104857600
pcloud_upload_progress=true
pcloud_poll_progress=false
pcloud_check_quota=true
pcloud_create_parents=true
pcloud_clean_recursive=false
retry_count=3
timeout_seconds=120
```

Then run:

```sh
export BACKUP_PCLOUD_TOKEN=...
backup --remote-config backup-pcloud.conf --remote pcloud://Backups/server-a/ --pcloud-check
backup --remote-config backup-pcloud.conf --upload archive.zip /data
backup --remote-config backup-pcloud.conf --restore-remote archive.zip restored.zip
backup --remote-config backup-pcloud.conf --remote pcloud://Backups/server-a/ --pcloud-clean-temp
```

## Release Compatibility Gate

`tools/bin/check_pcloud_compatibility` is part of `tools/bin/check_all`. Offline development runs use the loopback pCloud fixture unless strict provider settings are requested. CI and strict release runs should provide:

```sh
BACKUP_PCLOUD_COMPAT_REMOTE=pcloud://0/backups-ci/
BACKUP_PCLOUD_COMPAT_PATH_REMOTE=pcloud://Backups/backup-ci-path/
BACKUP_PCLOUD_COMPAT_TOKEN=...
BACKUP_PCLOUD_COMPAT_API_BASE=https://api.pcloud.com
BACKUP_PCLOUD_COMPAT_STRICT=1
```

Use `BACKUP_PCLOUD_COMPAT_TOKEN_FILE` instead of `BACKUP_PCLOUD_COMPAT_TOKEN` when the token is stored in a file. Set `BACKUP_PCLOUD_COMPAT_PATH_REMOTE` to add a real-provider folder-path run alongside the main compatibility namespace. Set `BACKUP_PCLOUD_COMPAT_ALLOW_FIXTURE=1` only when a strict run is intentionally allowed to use the local fixture instead of the real provider.

## Troubleshooting

- `pCloud access token is required`: set `pcloud_access_token_env`, `pcloud_access_token_file`, or `pcloud_access_token`.
- Authentication failures with result `1000`, `2000`, or `2003`: check that the token is current, scoped to the account, and sent to the right US/EU API base.
- `Directory does not exist` or result `2005`: for folder-id URLs, verify the numeric folder id; for folder-path URLs, verify parent folder existence and token permissions.
- `Invalid file/folder name` or result `2001`: check the pCloud namespace and the generated archive object name. Backup-managed object names cannot contain path separators except the pCloud namespace prefix model.
- Quota failures with result `2008` or a local `pCloud quota preflight failed` diagnostic: free space, select a different account, disable `pcloud_check_quota` only for providers that omit quota fields incorrectly, or reduce archive size before retrying.
- Leftover `.backup-upload-...` objects: backup deletes temporary objects when final `renamefile` fails, but an interrupted process or network outage can leave a temp object behind. It is safe to remove backup-managed temp objects after confirming no backup process is running. Use `backup --remote-config backup-pcloud.conf --remote pcloud://0/backups/ --pcloud-clean-temp` to delete stale `.backup-upload-...` objects in a namespace. Set `pcloud_clean_recursive=true` only for isolated backup namespaces where child folders should also be scanned.
- Wrong API region: use `https://api.pcloud.com` for US accounts and `https://eapi.pcloud.com` for EU accounts. A valid token on the wrong API base can look like an authentication or missing-object failure.

## API References

The implementation follows the pCloud HTTP/JSON API methods `oauth2_token`, `userinfo`, `uploadfile`, `uploadprogress`, `renamefile`, `deletefile`, `listfolder`, `createfolderifnotexists`, `checksumfile`, and `getfilelink`; pCloud resume recovery uses these same documented methods. pCloud responses are decoded through the shared `Project_Tools.JSON` reader for nested metadata, arrays, escaped strings, numbers, booleans, and provider error fields. See the pCloud developer documentation for method-level error codes and response shapes.
