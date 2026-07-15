package Backup_Test_Temp is

   --  The directory tests build their fixtures under: the host's real temporary directory,
   --  with links resolved. It replaced a hardcoded "/tmp", which is wrong on Windows (no
   --  /tmp) and on macOS, where /tmp is a symlink into /private/tmp -- so a fixture built as
   --  "/tmp/x" never string-compares equal to the "/private/tmp/x" backup canonicalises it
   --  to, which failed the restore, verify and workflow suites on macOS with paths that were
   --  really there under the other name.
   function Base return String;

end Backup_Test_Temp;
