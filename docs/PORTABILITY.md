# Portability

`backup` writes standard ZIP payloads plus a private central-directory metadata extra field for POSIX-oriented metadata. File contents, archive paths, compression, manifests, and listings remain portable ZIP data.

The following metadata is restored best-effort when the runtime and filesystem support it:

- regular file modification time
- Unix executable/file mode
- uid/gid ownership
- extended attributes
- POSIX ACL data exposed by the platform as xattrs, such as `system.posix_acl_access`

Stored symlink entries are restored only when `--symlinks=store-link` is selected. Unix builds call `symlink(2)`. Windows builds invoke `mklink` through `cmd.exe`, which may require Developer Mode or account privileges depending on the host policy. A denied symlink operation is reported as an explicit restore failure.

If a target platform, mount option, or permission set rejects an ownership, mode, xattr, or ACL operation, restore continues after writing and validating file contents. This keeps archives usable on Windows and other non-POSIX targets, while preserving richer metadata on Linux filesystems that support it.

For secret cache files, backup maps owner-only mode requests to the closest platform primitive. Unix-like builds call `chmod`; native Windows builds use `icacls.exe` for `0600` token-cache writes and return unsupported for other POSIX-style modes.

## Build Source Selection

`backup.gpr` selects `src/unix` or `src/windows` through `BACKUP_TARGET_OS`, defaulting to Alire's host OS. Release verification compiles the Windows-selected source set on the host to ensure the main program no longer depends on POSIX-only symbols outside the Unix platform body. CI also builds the main project and runs both maintained test executables on `windows-latest`.
