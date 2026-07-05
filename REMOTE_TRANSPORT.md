# Remote transport support

Phase 21 adds a typed remote transport layer in `Backup.Remote`.

## Implemented transports

Implemented transports are `file://`, HTTP/HTTPS object URLs, S3-compatible
object storage, Google Drive, pCloud, SSH/SFTP, and Proton Drive SDK-backed remotes. The file transport is intended for repeatable tests, mounted
network filesystems, synchronized directories, and as the deterministic reference
implementation for network protocols.

A `file://` URL may name either a namespace or a concrete object:

- `file:///backup/remote/` stores the archive under the local archive basename.
- `file:///backup/remote/nightly.zip` stores the archive as `nightly.zip`.

Remote object names are validated and may not contain path separators, control
characters, `.` or `..`. Retention and synchronization plans operate only inside
the parsed namespace and never across the parent directory.

## HTTP, HTTPS, S3, Google Drive, and pCloud object transports

HTTP and HTTPS object remotes are implemented through the sibling `httpclient`
crate. S3 object remotes use the same HttpClient execution path with AWS SigV4
request signing. The transport layer does not embed a custom HTTP stack and does
not shell out to `curl`, `wget`, or provider CLIs.

HTTP/HTTPS URLs may name either a namespace or a concrete object:

- `https://example.test/backups/` stores the archive under the local archive basename.
- `https://example.test/backups/nightly.zip` stores the archive as `nightly.zip`.

S3 URLs use `s3://BUCKET/PREFIX/` or `s3://BUCKET/PREFIX/OBJECT.zip` and are
mapped to path-style HTTP object requests against `s3_endpoint`. Provider-specific
setup notes for IDrive e2 are in `docs/IDRIVE_E2.md`:

- `s3://my-bucket/backups/` stores the archive under the local archive basename.
- `s3://my-bucket/backups/nightly.zip` stores the archive as `nightly.zip`.
- with `s3_endpoint=https://s3.example.test`, object `nightly.zip` is addressed as
  `https://s3.example.test/my-bucket/backups/nightly.zip`.

S3 requests are signed with AWS Signature Version 4 using
`x-amz-content-sha256: UNSIGNED-PAYLOAD`, which keeps archive upload streaming
without pre-hashing the file. Ordinary single-object S3 PUT uploads send
`x-amz-checksum-crc32` using S3's native base64-encoded CRC32 header. Multipart
uploads initiate with `x-amz-checksum-algorithm: CRC32`, send
`x-amz-checksum-crc32` on each `UploadPart`, and include `<ChecksumCRC32>` in
`CompleteMultipartUpload`. S3 verification/fallback metadata probes request
checksum metadata with `x-amz-checksum-mode: ENABLED` where the provider
supports it. Backup still performs its own GET readback size/CRC32 verification
after upload. The implementation supports static access keys,
standard AWS environment credentials, shared AWS credentials/config profiles,
`credential_process`, AWS SSO cached-token profiles, ECS/EC2 metadata
credentials, optional session tokens, path-style addressing, virtual-hosted
addressing, presigned object URLs, and
optional S3 server-side encryption headers for SSE-S3 (`AES256`) and SSE-KMS
(`aws:kms`). Multipart S3 upload is used automatically when the archive size is
at or above `s3_multipart_threshold`; individual parts are uploaded with
fixed-length streaming `UploadPart` requests, then completed with S3's
`CompleteMultipartUpload` API. Initiate, part upload, and complete requests use
the configured retry policy. Non-final parts must be at least 5 MiB, and uploads
that would exceed S3's 10,000-part limit are rejected before transfer. When
resume mode is enabled, backup looks for an existing multipart upload for the
same key, follows paginated S3 multipart-upload and part listings, loads already
uploaded contiguous parts, and continues from the next part.

Google Drive URLs use `gdrive://FOLDER_ID/PREFIX/` or
`gdrive://FOLDER_ID/PREFIX/OBJECT.zip`. The folder id is the Drive folder that
receives backup-managed files; the optional prefix is stored as part of the
Drive file name so backup can share one folder with other backup namespaces.
Google Drive authentication uses OAuth 2.0 bearer credentials. A caller can
provide an access token directly with `google_drive_access_token`, load one from
`google_drive_access_token_env`, or read one from `google_drive_access_token_file`.
Longer-lived OAuth credentials can be supplied with `google_drive_refresh_token`,
`google_drive_client_id`, and `google_drive_client_secret`; backup exchanges the
refresh token at `google_drive_token_uri` or the default
`https://oauth2.googleapis.com/token` before making Drive requests. The default API
endpoints are `https://www.googleapis.com/drive/v3` and
`https://www.googleapis.com/upload/drive/v3`; tests and compatible gateways can
override them with `google_drive_api_base` and `google_drive_upload_base`.
Shared drives can be enabled with `google_drive_supports_all_drives=true`; a
specific shared drive can be selected with `google_drive_drive_id`, which makes
file lookup use `corpora=drive`, `driveId`, `includeItemsFromAllDrives=true`,
and `supportsAllDrives=true`. Drive file lookup escapes Drive query string
literals, follows `nextPageToken` pagination, and refuses an ambiguous namespace
when more than one matching file name exists in the selected folder/prefix.
Drive operations retry transient provider failures according to `retry_count`,
including HTTP `429`, retryable `5xx`, and quota/rate-limit `403` responses whose
JSON body reports `rateLimitExceeded`, `userRateLimitExceeded`, or
`quotaExceeded`.
Archive uploads use the Drive resumable upload protocol: backup starts a
`uploadType=resumable` session with `X-Upload-Content-Type` and
`X-Upload-Content-Length`, then streams the ZIP file to the returned session URL
without loading the archive into memory. Small metadata/index publication still
uses the Drive `files.create`/`files.update` multipart upload API. Downloads use
`files.get?alt=media`, deletion uses `files.delete`, and object
lookup uses `files.list` scoped to the configured parent folder and exact file
name. Google Drive and pCloud are not S3-compatible and are implemented as separate remote
backends. SSH remotes use the sibling `ssh_lib` crate and its SFTP-backed exact-path workflows. Both `ssh://user@host/path/` and scp-like `user@host:path/` remote names are accepted; with `ssh://`, a double slash after the authority keeps an absolute path, for example `ssh://user@host//srv/backups/`. Session options are resolved from OpenSSH-style config through `ssh_lib`, including user, port, identity files, agent use, known-host verification, and `ProxyCommand`. With resume mode enabled, SSH/SFTP probes the remote file size and uses `ssh_lib` byte-offset resume to append only the missing local suffix when the remote object is shorter than the local archive. Equal-size objects are read back for CRC32 before reuse, and larger or mismatched objects fall back to a full atomic SFTP replacement. Proton Drive is also separate: `protondrive://SHARE_ID/PREFIX/` URLs are parsed through the Ada `Proton_Drive` SDK layer; session, user-address, CryptoLib-backed metadata authentication, and explicit provider operation endpoints are validated before transfer.

pCloud URLs use either the folder-id form `pcloud://FOLDER_ID/PREFIX/`
or `pcloud://FOLDER_ID/PREFIX/OBJECT.zip`, or the folder-path form
`pcloud://Backups/project/` or `pcloud://Backups/project/OBJECT.zip`. Numeric
first path components are treated as pCloud folder ids, with root represented by
`0`; the remaining prefix is stored as part of the pCloud file name in that
folder. Non-numeric namespaces are treated as pCloud folder paths. Backup
resolves them with `listfolder` for reads and creates them with
`createfolderifnotexists` for writes, then stores the backup-managed object name
inside that folder. The default `pcloud_region=auto` setting probes the account with `userinfo`
when a token is available; accounts can set `pcloud_region=us`, `pcloud_region=eu`, or
`pcloud_api_base=https://api.pcloud.com` / `https://eapi.pcloud.com` to avoid probing. Authentication
uses a pCloud OAuth access token supplied through `pcloud_access_token`,
`pcloud_access_token_file`, or `pcloud_access_token_env`.
`pcloud_large_upload_threshold=BYTES` marks archives at or above the threshold
for the streamed large-upload path, `pcloud_upload_progress=true` sends a
provider progress hash with `uploadfile`, `pcloud_poll_progress=true` checks
`uploadprogress`, `pcloud_check_quota=true` performs a `userinfo` quota
preflight, and `pcloud_create_parents=true` creates missing folder-path
parents component by component. With resume mode enabled, pCloud archive uploads
use deterministic backup-managed temporary names and reuse a matching final or
temporary provider object by checksum/size/readback before starting a fresh
`uploadfile` request. The pCloud HTTP/JSON API does not provide a documented
byte-offset upload session, so mid-stream connection breaks still restart from
byte zero. pCloud's `uploadtransfer` method is deliberately not used because it
sends transfer links rather than storing backup objects in the selected folder.
pCloud uploads write a temporary object and then publish the final name through
`renamefile`, so the visible destination is not removed before the replacement
upload has succeeded. Scheduled jobs use the same settings with a `remote_`
prefix. See `docs/PCLOUD.md` for setup examples.

Upload uses HTTP `PUT` to the object URL with a fixed-length streaming request
for ordinary object uploads or S3's multipart upload lifecycle for large S3
archives, and then verifies the uploaded archive with a GET readback by size and
CRC32 before reporting success. Download
and verification use HttpClient file
downloads, and scoped deletion uses HTTP `DELETE`. HTTP status `200`, `201`,
and `204` are accepted for upload; `200` is required for download and
verification.

HTTP/HTTPS inventory is read from the namespace URL as a strict text index.
S3 inventory is normally read from the object `backup-remote-index-v1` under the selected
bucket/prefix. Google Drive inventory is stored as a Drive file named
`backup-remote-index-v1` in the selected folder/prefix namespace. pCloud uses the
same managed index name in the selected folder/prefix namespace. pCloud
verification first probes `checksumfile` metadata and accepts a matching SHA-256
when the provider returns it; otherwise it falls back to the full download CRC32
readback. If that object is missing, backup falls back to native S3
`ListObjectsV2` for the selected prefix and imports managed archive object names
directly under that prefix. Native S3 listings expose size and last-modified
time; backup also sends `x-amz-meta-backup-crc32` on S3 archive creation and
uses signed `HEAD` requests during fallback inventory to recover CRC32 for
objects uploaded by backup. Objects without that metadata still fall back to
CRC32 `0`, so sync may re-upload a matching object once to republish a complete
index. The index response body must start with `backup-remote-index-v1`,
followed by one object per line using tab-separated fields:

```text
backup-remote-index-v1
OBJECT<TAB>SIZE<TAB>CRC32<TAB>TIMESTAMP
```

`OBJECT` is a managed archive object name such as `nightly.zip` or
`nightly.zip.partial`, `SIZE` is the decimal byte count, `CRC32` is the decimal
CRC32 value, and `TIMESTAMP` is either `YYYY-MM-DDTHH:MM:SSZ` or `-` when the
backend cannot expose object modification time. Unmanaged object names are
ignored. Malformed managed rows fail the inventory read so retention never acts
on ambiguous metadata. For HTTP/HTTPS remotes, a missing index (`404`) is treated as an empty inventory.
For S3 remotes, a missing index triggers the native `ListObjectsV2` fallback.

After a successful HTTP/HTTPS/S3/Google Drive/pCloud upload and GET readback
verification, `backup` fetches the current index, upserts the uploaded object
metadata, and publishes the updated index with `PUT` to the namespace URL for
HTTP/HTTPS, to the S3 index object for S3, or with Google Drive multipart upload
to the Drive index file. After a successful scoped HTTP/HTTPS/S3/Google Drive/pCloud
`DELETE`, `backup`
removes that object from the index and publishes the updated index. Index
publication accepts the same `200`, `201`, and `204`
status codes as object upload; an index publication failure makes the remote
operation fail so sync and retention do not proceed with stale inventory. When
the index fetch returns an `ETag`, publication uses `If-Match`; creating a
missing index uses `If-None-Match: *`, so conditional HTTP servers can reject
concurrent stale writers instead of accepting silent overwrites. A `409` or
`412` index publish conflict is handled by refetching the current index,
reapplying the local upsert/delete, and retrying the conditional publish with
the new validator before failing.

## Upload semantics

`Backup.Remote.Upload_Archive` writes to `OBJECT.partial`, then atomically
renames the temporary object into the final object path. If a final object
already exists, it is moved aside and restored on failed replacement. After the
rename, the remote object is verified against the local archive by size and
CRC32 metadata before the upload is reported as reusable.

Partial upload markers are treated as managed remote objects. Synchronization
planning emits a scoped `delete_remote` step for `*.partial` objects, and the
workflow executes deletion only through `Backup.Remote.Delete_Remote_Object`,
which refuses unsafe names and non-backup object names. Unmanaged paths outside
the configured namespace are never deleted. Scheduled retention also filters
remote candidates by the configured output naming policy before deletion, so
objects that do not belong to that backup job are left untouched even when they
look like archive files.

When resume mode is enabled, a matching `OBJECT.partial` file whose size and
CRC32 equal the local archive is promoted into place instead of recopied. A
non-matching partial file is discarded before a fresh atomic upload. SSH/SFTP
resume is different: the final remote object itself is probed and a shorter
remote file is extended in place from the matching byte offset through
`ssh_lib`; it is then verified by full readback before success is reported.

The file transport reference implementation applies the configured retry policy
to payload copy operations. HTTP, HTTPS, S3, pCloud, and SSH/SFTP archive uploads apply the same policy
to fixed-length streaming requests by reopening the local archive for each
attempt where backup owns the retry loop, or by delegating to `ssh_lib` transfer
retries for SSH/SFTP. `retry_count=N` means one initial attempt plus up to `N` retries, with
the retry total reported in machine-readable transfer output where the backend exposes attempt counts.
`timeout_seconds=0` is treated as an immediate deterministic timeout and returns
`Remote_Timeout` before opening or copying payload data. Non-zero timeouts define
the transport policy boundary for later network transports; the local `file://`
copy primitive does not expose cancellable per-byte deadlines.

## Synchronization semantics

`Backup.Remote.Read_Inventory` reads the configured namespace and builds typed
archive metadata for managed archive objects. SSH inventory lists the configured SFTP directory and downloads managed archive objects to a temporary local file to compute backup's CRC32 metadata before planning. `Backup.Remote.Build_Sync_Plan`
compares the local archive against the remote inventory using normalized archive
identifiers, sizes, CRC32 values, and partial markers. The plan is deterministic:
remote inventory entries are sorted by archive identifier before steps are
emitted.

## Restore semantics

`--restore-remote --remote URL LOCAL.zip` downloads a remote archive to a local
path through a temporary object and verifies the restored file against the
remote object. Archive extraction remains the responsibility of the existing
safe restore workflow, so remote transport does not weaken Phase 17 extraction
checks.

## Remote config files

`--remote-config FILE` reads a deterministic key/value file. Supported keys are:

- `remote=` or `url=`
- `require_encrypted=true|false`
- `resume=true|false`
- `retry_count=N`
- `timeout_seconds=N`
- `http_bearer_token=TOKEN`
- `http_basic_user=USER` and `http_basic_password=PASSWORD`
- `http_header_name=NAME` and `http_header_value=VALUE`
- `tls_ca_file=PEM` and `tls_ca_directory=DIR`
- `tls_client_cert=PEM`, `tls_client_key=PEM`, and optional `tls_client_key_passphrase=TEXT`
- `s3_endpoint=URL`
- `s3_region=REGION`
- `s3_profile=PROFILE`, overrides `AWS_PROFILE` / `AWS_DEFAULT_PROFILE` for shared credentials lookup
- `s3_credentials_file=PATH`, overrides `AWS_SHARED_CREDENTIALS_FILE` / `$HOME/.aws/credentials`
- `s3_config_file=PATH`, overrides `AWS_CONFIG_FILE` / `$HOME/.aws/config`
- `s3_web_identity_token_file=PATH`, web-identity token file for STS `AssumeRoleWithWebIdentity`
- `s3_role_arn=ARN`, role ARN for STS `AssumeRoleWithWebIdentity`
- `s3_credential_process=COMMAND`, uses an AWS `credential_process` JSON provider when static/profile credentials are absent
- `s3_sso_session=NAME`, AWS SSO session name used for cached token lookup
- `s3_sso_start_url=URL`, AWS SSO start URL used for cached token lookup
- `s3_sso_region=REGION`, AWS SSO region for role-credential exchange
- `s3_sso_account_id=ID`, AWS SSO account id for role-credential exchange
- `s3_sso_role_name=NAME`, AWS SSO role name for role-credential exchange
- `s3_addressing=path|virtual`
- `s3_server_side_encryption=AES256|aws:kms`
- `s3_sse_kms_key_id=KEY_ID`
- `s3_acl=ACL`, sends `x-amz-acl` on object creation
- `s3_storage_class=CLASS`, sends `x-amz-storage-class` on object creation
- `s3_tagging=QUERY`, sends `x-amz-tagging` on object creation
- `s3_metadata_name=NAME` and `s3_metadata_value=VALUE`, send one `x-amz-meta-NAME` header
- `s3_cache_control=VALUE`, sends `Cache-Control` on object creation
- `s3_content_disposition=VALUE`, sends `Content-Disposition` on object creation
- `s3_content_encoding=VALUE`, sends `Content-Encoding` on object creation
- `s3_object_lock_mode=GOVERNANCE|COMPLIANCE`, sends `x-amz-object-lock-mode`
- `s3_object_lock_retain_until=YYYY-MM-DDTHH:MM:SSZ`, sends `x-amz-object-lock-retain-until-date`; requires `s3_object_lock_mode`
- `s3_object_lock_legal_hold=ON|OFF`, sends `x-amz-object-lock-legal-hold`
- `s3_multipart_threshold=BYTES`, default `67108864`; set `0` to disable multipart upload
- `s3_multipart_part_size=BYTES`, default `8388608`; if more than one part is needed, non-final parts must be at least `5242880` bytes
- `s3_access_key=KEY` or `s3_access_key_env=ENV_NAME`
- `s3_secret_key=SECRET` or `s3_secret_key_env=ENV_NAME`
- `s3_session_token=TOKEN` or `s3_session_token_env=ENV_NAME`

Command-line `--remote URL` takes precedence over a `remote=` value in the file.
Unknown keys and malformed values are rejected with line-specific diagnostics.


## HTTP and S3 authentication

HTTP and HTTPS remotes can attach request-specific authentication headers from
remote configuration. `http_bearer_token=TOKEN` sends `Authorization: Bearer
TOKEN`. `http_basic_user=USER` with `http_basic_password=PASSWORD` sends a
validated HTTP Basic `Authorization` header. `http_header_name=NAME` with
`http_header_value=VALUE` sends one validated custom header for deployments that
use gateway-specific credentials. Scheduled jobs use the same settings with a
`remote_` prefix, for example `remote_http_bearer_token=TOKEN`.

Authentication headers are applied to object upload, readback verification,
download, delete, inventory reads, and conditional index publication. Invalid
credential/header values fail before the HTTP request is sent. S3 credentials are
only applied to parsed `s3://` remotes, so an HTTP remote config may contain S3
keys without changing ordinary HTTP authentication behavior.

S3 remotes require an access key and secret key. Credentials may be supplied
inline, through explicit environment-variable keys, from standard AWS environment
variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional
`AWS_SESSION_TOKEN`), from the AWS shared credentials file, from the AWS shared
config file, from AWS SSO cached-token profiles, from STS
`AssumeRoleWithWebIdentity`, from an AWS `credential_process` JSON provider
with quoted/escaped command arguments, or
from ECS/EC2 metadata credentials. SSO profile support reads `sso_session`,
`sso_start_url`, `sso_region`, `sso_account_id`, and `sso_role_name` from the
selected AWS config profile and `[sso-session NAME]` sections, scans
`AWS_SSO_CACHE_DIR` or `$HOME/.aws/sso/cache` for a matching non-expired cached
`accessToken`, prefers exact `sso_session` cache matches over `sso_start_url`
fallback matches, and exchanges the token through AWS SSO role credentials.
Shared profile lookup uses
`s3_profile`, `AWS_PROFILE`,
`AWS_DEFAULT_PROFILE`, or `default`, in that order. File lookup uses
`s3_credentials_file`, `AWS_SHARED_CREDENTIALS_FILE`, or
`$HOME/.aws/credentials` for credentials and `s3_config_file`,
`AWS_CONFIG_FILE`, or `$HOME/.aws/config` for config. Missing or empty explicitly referenced
environment variables are rejected when the config/job file is loaded. `s3_region`
defaults to `us-east-1` and `s3_endpoint` defaults to
`https://s3.amazonaws.com` when omitted; S3-compatible providers such as MinIO
generally require an explicit endpoint. The endpoint must be an `http://` or
`https://` URL without a query string or fragment. Virtual-hosted addressing also
requires an endpoint without a path prefix because the bucket is moved into the
host name. The bucket part of the `s3://` URL must be non-empty and contain only
letters, digits, `.`, `-`, or `_`. `s3_sse_kms_key_id` requires
`s3_server_side_encryption=aws:kms`. S3 Object Lock settings require a bucket
with Object Lock enabled by the provider; backup signs and sends the object
creation headers but does not create or reconfigure bucket-level Object Lock.

Scheduled jobs use the same settings with a `remote_` prefix, for example
`remote_s3_endpoint=URL`, `remote_s3_region=REGION`,
`remote_s3_profile=PROFILE`, `remote_s3_credentials_file=PATH`,
`remote_s3_config_file=PATH`, `remote_s3_web_identity_token_file=PATH`,
`remote_s3_role_arn=ARN`, `remote_s3_credential_process=COMMAND`,
`remote_s3_sso_session=NAME`, `remote_s3_sso_start_url=URL`,
`remote_s3_sso_region=REGION`, `remote_s3_sso_account_id=ID`,
`remote_s3_sso_role_name=NAME`, `remote_s3_addressing=path|virtual`,
`remote_s3_server_side_encryption=AES256|aws:kms`,
`remote_s3_sse_kms_key_id=KEY_ID`,
`remote_s3_acl=ACL`, `remote_s3_storage_class=CLASS`,
`remote_s3_tagging=QUERY`, `remote_s3_metadata_name=NAME`,
`remote_s3_metadata_value=VALUE`, `remote_s3_cache_control=VALUE`,
`remote_s3_content_disposition=VALUE`, `remote_s3_content_encoding=VALUE`,
`remote_s3_object_lock_mode=GOVERNANCE|COMPLIANCE`,
`remote_s3_object_lock_retain_until=YYYY-MM-DDTHH:MM:SSZ`,
`remote_s3_object_lock_legal_hold=ON|OFF`,
`remote_s3_multipart_threshold=BYTES`, `remote_s3_multipart_part_size=BYTES`,
`remote_s3_access_key_env=ENV_NAME`, `remote_s3_secret_key_env=ENV_NAME`, and
optional `remote_s3_session_token_env=ENV_NAME`.

HTTPS remotes can configure custom trust anchors with `tls_ca_file` and
`tls_ca_directory`, which are passed to HttpClient's TLS transport before the
request is executed. HTTPS remotes can also configure mutual TLS with
`tls_client_cert` and `tls_client_key`; the optional
`tls_client_key_passphrase` is passed to HttpClient for encrypted PEM private
keys. The client certificate is scoped to the request's HTTPS origin before the
request is executed, so it is not a broad default credential for unrelated
origins. Scheduled jobs use the same settings with a `remote_` prefix, for
example `remote_tls_ca_file=PEM` and `remote_tls_client_cert=PEM`.

## Encryption boundary

`--remote-require-encrypted` and `remote_require_encrypted=true` require
`--encrypt` / `encrypt=true` for upload and synchronization operations. The
transport API also checks `Remote_Options.Require_Encrypted` before copying any
object, so direct calls fail with `Remote_Encryption_Required` rather than
uploading plaintext. Encryption and authentication remain handled by Phase 19;
the remote layer only transports the completed archive object.

## Machine-readable reports

Remote upload, restore, and verification reports use `backup-remote-v1` JSON.
Synchronization planning uses `backup-remote-sync-v1` JSON when `--list-json` is selected. Non-JSON remote sync dry-runs use a human-readable synchronization plan. The machine-readable reports include
transport kind, object name, local path, size, CRC32, atomicity, resume state, retry count, and verification
status. Workflow execution preserves the remote JSON report for remote upload,
restore, and sync operations instead of replacing it with the ordinary archive
creation report.

## Scheduled jobs and remote retention

Job files may use `remote=`, `upload_after=true`, or `sync_after=true` with the
existing `retention_after=true` policy. For remote jobs, retention inventory is
read from the configured remote namespace and candidates are limited to managed
archive names for the job's `output=` and `output_naming=` policy. Deletion is
performed only through `Backup.Remote.Delete_Remote_Object`, preserving the same
name validation and namespace boundary checks as synchronization cleanup.

The `file://` transport exposes remote object modification timestamps in
inventory metadata, and HTTP/HTTPS/S3 indexes may expose the same timestamps in
the fourth field. Scheduled remote retention uses those timestamps for count,
age, and tiered planning. Index rows that use `-` for timestamp fall back to
deterministic lexical ordering so pruning remains stable and independent of
backend enumeration order.
