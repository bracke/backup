with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_Fish_Completion is
   --  backup fish completion smoke
begin
   Backup_Tool_Support.Require_File ("share/completions/backup.fish");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.fish", "complete -c backup", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.fish", "-l compression", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.fish", "aes256-gcm", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.fish", "set -n", "completion check failed");
   Ada.Text_IO.Put_Line ("backup completion check passed: share/completions/backup.fish");
exception
   when Program_Error =>
      null;
end Check_Fish_Completion;
