# Using backup with IDrive e2

IDrive e2 is S3-compatible object storage. `backup` uses it through the existing
S3 remote backend; there is no separate `idrive://` transport.

## IDrive e2 setup

In the IDrive e2 console:

1. Enable the region you want to use.
2. Create a bucket for backup-managed archives.
3. Create an access key for that region and bucket.
4. Copy the region endpoint URL, access key ID, and secret access key.

IDrive e2 endpoints are region/account specific. Use the exact endpoint shown by
the IDrive e2 console for the enabled region.

## Remote config

Create a remote config file for the backup namespace:

```text
remote=s3://BUCKET/PREFIX/
s3_endpoint=https://YOUR-IDRIVE-E2-ENDPOINT
s3_region=REGION
s3_addressing=path
s3_access_key_env=BACKUP_IDRIVE_E2_ACCESS_KEY
s3_secret_key_env=BACKUP_IDRIVE_E2_SECRET_KEY
retry_count=2
timeout_seconds=300
```

Then export credentials in the shell that runs `backup`:

```sh
export BACKUP_IDRIVE_E2_ACCESS_KEY='access-key-id'
export BACKUP_IDRIVE_E2_SECRET_KEY='secret-access-key'
```

Use a dedicated bucket or prefix for backup-managed objects. For example,
`remote=s3://company-backups/laptop-a/` keeps backup's archive files and
`backup-remote-index-v1` under `laptop-a/`.

## Upload, verify, restore

Create a local archive and upload it to IDrive e2:

```sh
bin/backup --remote-config idrive-e2.conf --upload out.zip /path/to/data
```

Verify the remote archive:

```sh
bin/backup --remote-config idrive-e2.conf --verify out.zip
```

Restore the remote archive to a local ZIP file:

```sh
bin/backup --remote-config idrive-e2.conf --restore-remote restored.zip
```

List the managed remote inventory in JSON:

```sh
bin/backup --remote-config idrive-e2.conf --list-json
```

## Multipart uploads

`backup` automatically uses S3 multipart upload when the archive reaches
`s3_multipart_threshold`. You can tune the threshold and part size:

```text
s3_multipart_threshold=8388608
s3_multipart_part_size=8388608
```

Non-final S3 multipart parts must be at least 5 MiB. Large archives are streamed
from disk and are verified by readback after upload.

## Encryption and retention

For off-site backups, prefer client-side encryption:

```sh
bin/backup --encrypt --password-file backup.pass \
  --remote-config idrive-e2.conf --upload out.zip /path/to/data
```

To require encrypted archives for remote operations, add this to the config:

```text
require_encrypted=true
```

Scheduled retention and sync operate only on backup-managed object names within
the configured `s3://BUCKET/PREFIX/` namespace.

## Provider notes

IDrive e2 is S3-compatible, but it does not support every Amazon S3 API.
`backup` uses ordinary object operations, multipart upload, checksums, metadata,
listing, and signed requests. It does not require S3 ACL APIs for normal backup
operation. If an IDrive e2 account or bucket policy rejects unsupported optional
headers, remove optional S3 settings such as ACL, storage class, tagging, object
lock, or server-side encryption from the config and retest with the minimal
configuration above.

The IDrive e2 documentation describes S3 API compatibility, region-specific
endpoint URLs, bucket/object concepts, and access key credentials:

- https://www.idrive.com/s3-storage-e2/developer-guide
- https://www.idrive.com/s3-storage-e2/faq
