# Symlink Handling

`backup` supports three scan-time symlink policies:

- `--symlinks=skip` records a diagnostic and does not archive the link. This is the default.
- `--symlinks=store-link` archives the link target text as a stored symlink entry. Dangling links are allowed because the link payload is the target text, not the referenced file.
- `--symlinks=follow` archives the target contents under the link path. Followed targets must stay inside one of the configured input roots. Broken links, targets outside the input roots, and symlink traversal cycles fail the scan. Tight symlink loops are reported as cycles.

Restore skips symlink entries by default. `--symlinks=store-link` restores stored symlink entries when the runtime supports creating symlinks and the target text is relative and safe. Unix builds call `symlink(2)`. Windows builds use `cmd.exe /C mklink`, so restoration depends on Windows symlink policy, Developer Mode, or account privileges. If the platform rejects link creation, restore fails explicitly instead of writing through or materializing the link target as an ordinary file.
