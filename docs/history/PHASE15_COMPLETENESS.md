# Phase 15 completeness pass — symlink handling

Phase 15 replaces the Phase 14 placeholder rejection for non-default symlink
modes with explicit scanner, ZIP-writer, manifest, dry-run, and JSON behavior.
This follow-up completeness pass tightened the implementation around multi-root
follow semantics, ZIP writer validation, and regression coverage.

Implemented behavior:

- `--symlinks=skip` remains the default and excludes symlink archive entries
  deterministically while recording symlink diagnostics for reporting.
- `--symlinks=store-link` emits symlink entries whose stored payload is the
  link target text returned by the host `readlink` operation. The target text is
  intentionally not canonicalized; it is preserved exactly as observed from the
  link, making the policy deterministic and platform-explicit for POSIX links.
- `--symlinks=follow` resolves symlink targets and archives the target contents
  under the symlink archive path. Followed entries remain subject to ignore
  evaluation, duplicate archive path detection, size accounting, compression
  policy, and ZIP64 handling.
- Follow mode rejects dangling/broken links, traversal cycles, and targets that
  leave all configured scanned input roots. A link in one input root may target
  another configured input root; links outside the complete input-root set are
  rejected with a deterministic diagnostic.
- Symlink chains are followed deterministically, and cycles through chains are
  rejected before unbounded recursion.
- Symlink entries use stored ZIP method 0, normalized timestamps, and Unix
  symlink external attributes in the central directory. The ZIP writer now
  explicitly rejects deflated symlink source entries instead of accidentally
  treating them as file payloads.
- Manifest, dry-run, and JSON listing output include symlink kinds, link targets,
  and symlink action diagnostics for skipped, stored, followed, broken, cyclic,
  and outside-root links.

Additional regression coverage added in this pass:

- Followed links targeting another configured input root are accepted.
- Symlink chains resolve to a regular archived file entry.
- Symlink chain cycles are rejected with `Scan_Symlink_Cycle`.
- Dangling symlinks are archived in store-link mode with exact target text.
- Workflow no longer expects `--symlinks=follow` to be unsupported.
- ZIP writer tests cover stored symlink payloads, Unix symlink attributes, and
  explicit rejection of deflated symlink entries.

Notes:

- The implementation uses POSIX `readlink` via a small C import because the
  existing codebase already uses POSIX symlink helpers in tests and GNAT.OS_Lib
  for symlink detection.
- Link target text in store-link mode is preserved as `readlink` returns it;
  relative targets remain relative and absolute targets remain absolute.
- Broken links are accepted in store-link mode because the link itself can be
  represented; they are rejected in follow mode because there is no target file
  or directory to archive.
- The uploaded environment did not include `gprbuild` or `gnat1`, so I could not
  execute the Ada build/test suite here. A direct `gcc -c -gnat2022` attempt
  failed with `cannot execute 'gnat1'`. Validate in a GNAT-enabled environment
  with `gprbuild -P backup_tests.gpr`.
