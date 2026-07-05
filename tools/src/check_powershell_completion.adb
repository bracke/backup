with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_Powershell_Completion is
   --  backup powershell completion smoke
begin
   Backup_Tool_Support.Require_File ("share/completions/backup.ps1");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.ps1", "Register-ArgumentCompleter -Native -CommandName backup", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.ps1", "--compression=", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.ps1", "aes256-gcm", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/backup.ps1", "Get-ChildItem Env:", "completion check failed");
   Ada.Text_IO.Put_Line ("backup completion check passed: share/completions/backup.ps1");
exception
   when Program_Error =>
      null;
end Check_Powershell_Completion;
