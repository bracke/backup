# Phase 13 Completeness Notes

Phase 13 implements deterministic archive metadata normalization and reproducible output behavior.

## Normalization policy

The ZIP writer always emits the same normalized ZIP metadata for regular file entries:

- local-header DOS time: `0`
- local-header DOS date: `33` (1980-01-01 in DOS date encoding)
- central-directory DOS time: `0`
- central-directory DOS date: `33`
- central-directory internal file attributes: `0`
- central-directory external file attributes: `0`
- no extra fields, no comments, and no host-specific owner/group/platform metadata

This normalized behavior is used consistently for stored and deflated entries. The parsed `--deterministic` option is therefore fully honored without creating a second, host-metadata-dependent output mode. When `--deterministic` is omitted, the implementation intentionally continues to use the same normalized metadata policy so the default behavior remains reproducible.

## Reproducible generated reports

Manifest, JSON listing, and dry-run output avoid leaking absolute filesystem paths or transient output paths. Source files and ignore-file origins are represented with stable logical placeholders where host paths would otherwise appear. Archive paths remain the normalized ZIP paths established by Phase 2.

## Test coverage added or tightened

The Phase 13 pass adds coverage for:

- byte-for-byte identical ZIP output across repeated runs;
- normalized local-header timestamps;
- normalized central-directory timestamps;
- normalized central-directory internal and external attributes;
- deterministic manifest source metadata;
- absence of absolute host paths in manifests;
- absence of absolute host paths in dry-run output;
- absence of absolute host paths in JSON listing output;
- deterministic mixed stored/deflated archive behavior inherited from Phase 9 and Phase 12 workflow tests;
- explicit `--deterministic` output matching the normalized default output for identical inputs;
- ZIP metadata byte checks in the executable integration script.

ZIP64, signing, encryption, incremental backups, and filesystem snapshot integration remain out of scope for this phase.
