# Phase 12 Completeness Notes

Phase 12 implements machine-readable JSON listing output and size-limit
enforcement on top of the Phase 11 manifest and dry-run workflow.

## JSON listing contract

`--list-json` emits one deterministic JSON document with stable key ordering and
stable array ordering inherited from the scanner. Archive paths in the JSON use
normalized ZIP-style `/` separators. Source filesystem paths are reported after
the existing filesystem normalization layer.

The top-level JSON object uses format marker `backup-list-v1` and includes:

- `dry_run`
- `output_path`
- `ignored_files_contribute_to_total_size`
- `total_uncompressed_size`
- `limits`
- `included_entries`
- `ignored_entries`
- `manifest`

Included entries report archive path, source path, file kind, selected
compression method, uncompressed size, compressed size when already known, and
CRC32 when it can be computed without writing the archive. Ignored entries report
archive path, kind, matching ignore file, matching line number, original rule
text, pruning status, and descendant reachability.

When `--manifest` is enabled, JSON includes the generated manifest archive path,
method, and deterministic manifest content. In dry-run mode, no output archive is
created or modified.

## Size-limit contract

`--max-file-size BYTES` rejects any included regular file candidate whose
uncompressed size exceeds the configured limit before archive writing begins.

`--max-total-size BYTES` rejects the operation when the sum of uncompressed sizes
for included candidate entries exceeds the configured limit before archive
writing begins.

Ignored files do not contribute to total-size accounting because they are not
candidate archive entries. Generated manifest content is also excluded from the
candidate-entry limit calculation; the limit applies to scanned regular-file
candidates selected for archiving.

## Completeness pass additions

This pass tightened the Phase 12 implementation by adding JSON reporting of
`total_uncompressed_size`, configured `limits`, and ignored descendant
reachability. It also added tests for oversized numeric CLI limits and expanded
Phase 12 integration assertions for the additional JSON fields.
