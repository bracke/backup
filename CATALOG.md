# Backup catalog format and query model

Phase 22 adds `Backup.Catalog`, a deterministic persistent index for backup archives.

## On-disk format

The catalog is an Ada-native text format headed by:

```text
backup-catalog-v1
```

Records are deterministic, pipe-separated, and percent-escaped. Archive records use `A|...`; entry records use `E|...`. The writer sorts archives by `archive_id` and entries by `(archive_id, archive_path)` before writing. Updates are written to `CATALOG.tmp` first and then renamed into place, so interrupted writes do not intentionally leave a partially rewritten final catalog.

The format stores typed metadata rather than unstructured maps:

* archive id, archive path, archive size, archive CRC32, indexed timestamp, and archive file modification timestamp;
* encryption-envelope presence;
* verification trust state;
* manifest presence and trust state;
* incremental parent id, retention group, remote URL, and remote verification flag;
* archive entry path, source path when known, entry kind, ZIP method, CRC32, compressed and uncompressed sizes, local header offset, source modification timestamp when it was available from the scan that created the archive, and per-entry trust state.

Empty files, invalid headers, unknown record kinds, malformed fields, duplicate archive records, duplicate entry records, entry records that reference missing archives, incremental parent ids that do not resolve to another cataloged archive, and stale file metadata are reported as catalog errors rather than being silently ignored.

## Trust model

Catalog metadata derived from ZIP entries is trusted only after Phase 16 verification succeeds. Each imported entry also carries a per-entry verification state. If verification fails while indexing, an archive-level record is still written with `verification=failed`, but entry records are not imported as trusted contents. `--verify-catalog` rejects a trusted archive whose entry rows are not also marked trusted, preventing old or hand-edited rows from masquerading as verified contents.

Encrypted Phase 19 envelopes are conservative by default. Indexing an encrypted archive without a password records only metadata visible from the outer envelope: archive path, archive id, envelope size, envelope CRC32, indexed timestamp, and encryption-presence metadata. Entry paths, file sizes, and manifest contents remain hidden. When a password source is supplied for encrypted indexing or encrypted backup creation, backup decrypts to a temporary work archive, verifies that plaintext ZIP, and records searchable trusted entry metadata under the encrypted archive id while keeping the archive record marked `encrypted=envelope`.

## Automatic catalog updates

`--catalog FILE` can be used with ordinary backup creation and with `--verify ARCHIVE.zip`. Scheduled job files may also contain `catalog=PATH`; job execution passes that path into the normal workflow. After the archive is created, and after any requested remote upload or synchronization succeeds, the workflow indexes the created archive and attaches run metadata:

* source filesystem paths for entries discovered during the scan;
* incremental parent archive id when `--incremental-from-archive` is used;
* a manifest parent marker when `--incremental-from-manifest` is used;
* remote URL and remote verification/synchronization success state;
* retention override group text when supplied by a scheduled run.

Dry runs reject `--catalog FILE` and job `catalog=PATH` with `dry_run=true` because no archive is created to index. Catalog updates happen after remote success, so failed uploads or failed synchronization do not mark an archive as remotely verified. When scheduled retention deletes a managed local archive, the job removes the matching catalog record. Remote retention deletion attempts the same removal by archive id when the remote inventory exposes only ids.

## Query model

The CLI exposes catalog operations through explicit options:

```text
backup --catalog CATALOG --index ARCHIVE.zip
backup --catalog CATALOG --index ENCRYPTED.benc --password-file PASSFILE
backup --catalog CATALOG --query content:path-fragment
backup --catalog CATALOG --query archive:name-fragment
backup --catalog CATALOG --query date:timestamp-fragment
backup --catalog CATALOG --query source:path-fragment
backup --catalog CATALOG --query lineage:archive-id
backup --catalog CATALOG --query remote:url-fragment
backup --catalog CATALOG --query remote-verified:true
backup --catalog CATALOG --query verification:trusted
backup --catalog CATALOG --query manifest:trusted
backup --catalog CATALOG --query encrypted:true
backup --catalog CATALOG --query encrypted:0
backup --catalog CATALOG --query size:12345
backup --catalog CATALOG --query crc32:305419896
backup --catalog CATALOG --query method:deflate
backup --catalog CATALOG --query kind:file
backup --catalog CATALOG --query retention:group-name
backup --catalog CATALOG --list-archives
backup --catalog CATALOG --list-contents
backup --catalog CATALOG --verify-catalog
```

`--list-archives` reports archive records only, while `--list-contents` reports entry records. `verification:` searches both archive-level and entry-level trust state. `remote-verified:` accepts `true`, `false`, `yes`, `no`, `1`, or `0`. `encrypted:` searches archive envelope visibility state using `true`, `false`, `yes`, `no`, `1`, `0`, `envelope`, or `none`. `size:` searches archive sizes and entry compressed or uncompressed sizes by exact byte count. `crc32:` searches archive and entry CRC32 metadata by exact decimal value. `method:` searches entry ZIP methods using `store`, `stored`, `deflate`, `deflated`, `bzip2`, `lzma`, `zstd`, or a numeric method id. Named method ids are stable: store=0, deflate=8, bzip2=12, lzma=14, legacy zstd=20, and zstd=93. `kind:` searches entry rows by `file`, `directory`, `symlink`, or `manifest`. `--list-json` may be combined with query/list operations to emit deterministic JSON. Exactly one catalog-management command may be selected per invocation. Query and list commands require an existing catalog file; `--index` is the catalog-management operation that may create a new catalog. `--index` may combine with `--password-file`, `--password-env`, or `--password-prompt` to intentionally make encrypted archive contents searchable. Catalog management commands are intentionally separate from extraction, verification, remote-restore, and job-management commands; unsupported combinations produce a diagnostic before mutation. Plain backup creation may combine with `--catalog FILE` for automatic post-run indexing, and encrypted creation uses the configured password source to index verified entry metadata before the plaintext work archive is removed. Archive verification may also combine with `--catalog FILE`; successful encrypted verification with a password source refreshes the searchable encrypted entry metadata, while verification without a password preserves envelope-only metadata.

## Recovery diagnostics

`--verify-catalog` reloads the catalog, rejects malformed records and duplicate archive or entry records, checks that referenced archive files still exist, verifies that incremental parent ids resolve to another cataloged archive and do not self-reference, and detects stale metadata by comparing current archive size and CRC32 with the cataloged values. Diagnostics identify the affected archive or entry. If a `CATALOG.tmp` file remains beside a valid catalog, verification succeeds but reports recovery guidance so the operator can remove the abandoned temporary file after confirming the final catalog. If a `CATALOG.bak` file remains beside a valid catalog, verification also reports cleanup guidance. If only `CATALOG.tmp` exists and the final catalog is absent, load fails with explicit interrupted-update recovery guidance instead of treating the catalog as empty. `--verify-catalog` rejects a missing final catalog path rather than treating it as an empty catalog.
