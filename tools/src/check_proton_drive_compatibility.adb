with Ada.Text_IO;
with Backup_Tool_Support;

procedure Check_Proton_Drive_Compatibility is
   --  Live-check knobs: BACKUP_PROTON_DRIVE_COMPAT_REMOTE BACKUP_PROTON_DRIVE_COMPAT_STRICT
   --  BACKUP_PROTON_DRIVE_COMPAT_ALLOW_FIXTURE BACKUP_PROTON_DRIVE_COMPAT_SESSION_FILE
   Backup_Bin : constant String := Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_BACKUP_BIN", "./bin/backup");
   Fixture    : constant String := Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_FIXTURE", "./tests/bin/backup_http_remote_live_tests");
   Remote     : constant String := Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_REMOTE");
   Strict     : constant Boolean := Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_STRICT") = "1" or else Backup_Tool_Support.Env ("CI") = "true";
   Allow      : constant Boolean := Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_ALLOW_FIXTURE") = "1";
begin
   if Remote = "" then
      if Strict and then not Allow then
         Backup_Tool_Support.Fail ("real Proton Drive compatibility settings are required in CI/strict mode");
      end if;
      Backup_Tool_Support.Run ("proton-drive fixture", Fixture, [1 .. 0 => <>]);
      Ada.Text_IO.Put_Line ("backup Proton Drive compatibility fixture passed");
      return;
   end if;
   declare
      Tmp : constant String := Backup_Tool_Support.Env ("TMPDIR", "/tmp") & "/backup-proton-drive-compat-ada";
      Config : constant String := Tmp & "/remote.conf";
      Archive : constant String := Tmp & "/remote-compat.zip";
      Restore : constant String := Tmp & "/remote-restored.zip";
      Input : constant String := Tmp & "/input.txt";
      Session_File : constant String := Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_SESSION_FILE");
      Text : constant String :=
        "remote=" & Remote & ASCII.LF &
        (if Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_API_BASE") /= "" then "proton_drive_api_base=" & Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_API_BASE") & ASCII.LF else "") &
        (if Session_File /= "" then "proton_drive_session_file=" & Session_File & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_USER_ADDRESS") /= "" then "proton_drive_user_address=" & Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_USER_ADDRESS") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_OPERATION_BASE_URL") /= "" then "proton_drive_operation_base_url=" & Backup_Tool_Support.Env ("BACKUP_PROTON_DRIVE_COMPAT_OPERATION_BASE_URL") & ASCII.LF else "") &
        "proton_drive_live_check=true" & ASCII.LF &
        "retry_count=1" & ASCII.LF;
   begin
      if Session_File = "" then
         Backup_Tool_Support.Fail ("Proton Drive compatibility credentials are required: set BACKUP_PROTON_DRIVE_COMPAT_SESSION_FILE");
      end if;
      Backup_Tool_Support.Remove_Tree (Tmp);
      Backup_Tool_Support.Write_Text (Config, Text);
      Backup_Tool_Support.Write_Text (Input, "backup Proton Drive compatibility payload" & ASCII.LF);
      Backup_Tool_Support.Run ("proton-drive upload", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--upload"), 4 => new String'(Archive), 5 => new String'(Input)]);
      Backup_Tool_Support.Run ("proton-drive verify", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--verify"), 4 => new String'(Archive)]);
      Backup_Tool_Support.Run ("proton-drive restore", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--restore-remote"), 4 => new String'(Restore)]);
      Backup_Tool_Support.Require_File (Restore, "Proton Drive compatibility restore did not produce an archive");
      Ada.Text_IO.Put_Line ("backup Proton Drive compatibility gate passed");
   end;
exception
   when Program_Error => null;
end Check_Proton_Drive_Compatibility;
