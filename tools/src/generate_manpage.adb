with Ada.Command_Line;

with Backup_Tool_Support;

procedure Generate_Manpage is
   Out_Path : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1)
      else "share/man/man1/backup.1");
   Content : constant String :=
      ".TH BACKUP 1 ""2026-06-11"" ""backup 0.1.0-dev"" ""User Commands""" & ASCII.LF &
      ".SH NAME" & ASCII.LF &
      "backup \- Ada command-line backup utility" & ASCII.LF &
      ".SH SYNOPSIS" & ASCII.LF &
      ".B backup" & ASCII.LF &
      "[options] OUT.zip INPUT..." & ASCII.LF &
      ".br" & ASCII.LF &
      ".B backup --list" & ASCII.LF &
      "ARCHIVE.zip [--list-json]" & ASCII.LF &
      ".br" & ASCII.LF &
      ".B backup --verify" & ASCII.LF &
      "ARCHIVE.zip [--list-json]" & ASCII.LF &
      ".br" & ASCII.LF &
      ".B backup --extract" & ASCII.LF &
      "ARCHIVE.zip --output-dir DIR [restore options]" & ASCII.LF &
      ".SH DESCRIPTION" & ASCII.LF &
      "backup scans input trees, applies ignore rules, writes ZIP archives, verifies" & ASCII.LF &
      "archives, restores selected paths, manages catalogs, and can upload or sync to" & ASCII.LF &
      "file, HTTP, HTTPS, S3-compatible, provider, and SSH/SFTP remotes." & ASCII.LF &
      ".SH OPTIONS" & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --manifest" & ASCII.LF &
      "Write a manifest into the archive." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --deterministic" & ASCII.LF &
      "Use deterministic archive metadata where supported." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --compression=auto|store|deflate|bzip2|lzma|ppmd|zstd" & ASCII.LF &
      "Select compression policy. bzip2, bounded ZIP-LZMA, and zstd ZIP creation and unencrypted verification/extraction for classic and ZIP64 metadata are in-process through zlib. ZIP method ids are stable: bzip2=12, lzma=14, zstd=93 for created archives with legacy zstd method 20 accepted on read, and ppmd=98. ppmd ZIP creation and verification/extraction require local 7z support and fail closed when unavailable." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --json-errors" & ASCII.LF &
      "Emit machine-readable failure diagnostics." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --help-advanced" & ASCII.LF &
      "Print a fuller option summary covering remote, catalog, job, incremental, encryption, restore, and diagnostic options." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --catalog FILE" & ASCII.LF &
      "Attach catalog operations or post-run indexing." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --remote URL" & ASCII.LF &
      "Select a file, HTTP, HTTPS, S3-compatible, provider, or SSH/SFTP remote." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --create-job FILE" & ASCII.LF &
      "Write a template job configuration." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --run-job FILE" & ASCII.LF &
      "Run a persisted job configuration." & ASCII.LF &
      ".SH ADVANCED OPTIONS" & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --remote URL" & ASCII.LF &
      "Select a file, HTTP, HTTPS, S3-compatible, provider, or SSH/SFTP remote. SSH and scp-like remote names are resolved through ssh_lib with SFTP transfer workflows." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --remote-config FILE" & ASCII.LF &
      "Read deterministic key=value remote settings including authentication, retry, timeout, TLS, and resume settings." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --upload, --sync, --restore-remote" & ASCII.LF &
      "Upload a newly created archive, reconcile a managed remote namespace, or download a remote archive to a local path." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --catalog FILE" & ASCII.LF &
      "Attach a catalog operation or request post-run indexing after archive creation or verification." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --index ARCHIVE, --query FIELD:VALUE" & ASCII.LF &
      "Import archive metadata into a catalog or query archive and entry metadata. Supported query fields include archive, date, content, source, lineage, remote, remote-verified, verification, manifest, encrypted, size, crc32, method, kind, and retention." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --list-archives, --list-contents, --verify-catalog" & ASCII.LF &
      "List catalog archive records, list catalog entry records, or validate catalog structure and archive references." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --create-job FILE, --run-job FILE, --job FILE" & ASCII.LF &
      "Create or run persisted key=value backup job files." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --retention-policy POLICY" & ASCII.LF &
      "Override the job retention policy for one run. Supported policy families are count, daily, weekly, monthly, and tiered." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --incremental-from ARCHIVE, --incremental-from-manifest FILE" & ASCII.LF &
      "Plan an incremental archive from a previous archive or manifest." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --encrypt, --cipher aes256-gcm" & ASCII.LF &
      "Write an encrypted archive envelope using the selected cipher." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --password-file FILE, --password-env NAME, --password-prompt" & ASCII.LF &
      "Select the password source for encryption or encrypted restore operations." & ASCII.LF &
      ".SH FILES" & ASCII.LF &
      "Example job files are installed below share/examples/backup." & ASCII.LF &
      ".SH SEE ALSO" & ASCII.LF &
      "README.md, REMOTE_TRANSPORT.md, CATALOG.md, JOBS_RETENTION.md" & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --remote-config" & ASCII.LF &
      "See README.md for details." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --remote-require-encrypted" & ASCII.LF &
      "See README.md for details." & ASCII.LF &
      ".TP" & ASCII.LF &
      ".B --verify-catalog" & ASCII.LF &
      "See README.md for details." & ASCII.LF &
      ".SH SHELL COMPLETION" & ASCII.LF &
      "Bash completion is provided by share/completions/backup.bash. Fish completion is provided by share/completions/backup.fish. PowerShell completion is provided by share/completions/backup.ps1. Zsh completion is provided by share/completions/_backup. Install each file into the matching shell completion directory, or source it where that shell supports sourcing, to enable option, enum-value, environment-variable, and file-path completion.";
begin
   Backup_Tool_Support.Write_Text (Out_Path, Content);
end Generate_Manpage;
