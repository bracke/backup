with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_Bash_Completion is
begin
   Backup_Tool_Support.Require_File ("share/completions/backup.bash");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.bash", "complete -F _backup_complete backup", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.bash", "--compression=", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.bash", "aes256-gcm", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.bash", "compgen -A variable", "completion check failed");
   Ada.Text_IO.Put_Line ("backup completion check passed: share/completions/backup.bash");
exception
   when Program_Error =>
      null;
end Check_Bash_Completion;
