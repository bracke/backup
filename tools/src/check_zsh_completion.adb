with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_Zsh_Completion is
   --  backup zsh completion smoke
begin
   Backup_Tool_Support.Require_File ("share/completions/_backup");
   Backup_Tool_Support.Require_Contains ("share/completions/_backup", "#compdef backup", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/_backup", "--compression", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/_backup", "aes256-gcm", "completion check failed");
   Backup_Tool_Support.Require_Contains ("share/completions/_backup", "_files", "completion check failed");
   Ada.Text_IO.Put_Line ("backup completion check passed: share/completions/_backup");
exception
   when Program_Error =>
      null;
end Check_Zsh_Completion;
