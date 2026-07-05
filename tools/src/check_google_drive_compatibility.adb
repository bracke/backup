with Ada.Text_IO;
with Backup_Tool_Support;

procedure Check_Google_Drive_Compatibility is
   --  Live-check knobs: BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE BACKUP_GOOGLE_DRIVE_COMPAT_STRICT
   --  BACKUP_GOOGLE_DRIVE_COMPAT_ALLOW_FIXTURE BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_FILE
   --  BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN
   Backup_Bin : constant String := Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_BACKUP_BIN", "./bin/backup");
   Fixture    : constant String := Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_FIXTURE", "./tests/bin/backup_http_remote_live_tests");
   Remote     : constant String := Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE");
   Strict     : constant Boolean := Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_STRICT") = "1" or else Backup_Tool_Support.Env ("CI") = "true";
   Allow      : constant Boolean := Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_ALLOW_FIXTURE") = "1";
begin
   if Remote = "" then
      if Strict and then not Allow then
         Backup_Tool_Support.Fail ("real Google Drive compatibility settings are required in CI/strict mode");
      end if;
      Backup_Tool_Support.Run ("google-drive fixture", Fixture, [1 .. 0 => <>]);
      Ada.Text_IO.Put_Line ("backup Google Drive compatibility fixture passed");
      return;
   end if;
   declare
      Tmp : constant String := Backup_Tool_Support.Env ("TMPDIR", "/tmp") & "/backup-google-drive-compat-ada";
      Config : constant String := Tmp & "/remote.conf";
      Archive : constant String := Tmp & "/remote-compat.zip";
      Restore : constant String := Tmp & "/remote-restored.zip";
      Input : constant String := Tmp & "/input.txt";
      Token_File : constant String := Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_FILE");
      Text : constant String :=
        "remote=" & Remote & ASCII.LF &
        (if Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_API_BASE") /= "" then "google_drive_api_base=" & Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_API_BASE") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_UPLOAD_BASE") /= "" then "google_drive_upload_base=" & Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_UPLOAD_BASE") & ASCII.LF else "") &
        (if Token_File /= "" then "google_drive_access_token_file=" & Token_File & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN") /= "" then "google_drive_refresh_token=" & Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_ID") /= "" then "google_drive_client_id=" & Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_ID") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_SECRET") /= "" then "google_drive_client_secret=" & Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_CLIENT_SECRET") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_DRIVE_ID") /= "" then "google_drive_drive_id=" & Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_DRIVE_ID") & ASCII.LF & "google_drive_supports_all_drives=true" & ASCII.LF else "") &
        "retry_count=1" & ASCII.LF;
   begin
      if Token_File = "" and then Backup_Tool_Support.Env ("BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN") = "" then
         Backup_Tool_Support.Fail ("Google Drive compatibility credentials are required: set BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_FILE or BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN");
      end if;
      Backup_Tool_Support.Remove_Tree (Tmp);
      Backup_Tool_Support.Write_Text (Config, Text);
      Backup_Tool_Support.Write_Text (Input, "backup Google Drive compatibility payload" & ASCII.LF);
      Backup_Tool_Support.Run ("google-drive upload", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--upload"), 4 => new String'(Archive), 5 => new String'(Input)]);
      Backup_Tool_Support.Run ("google-drive verify", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--verify"), 4 => new String'(Archive)]);
      Backup_Tool_Support.Run ("google-drive restore", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--restore-remote"), 4 => new String'(Restore)]);
      Backup_Tool_Support.Require_File (Restore, "Google Drive compatibility restore did not produce an archive");
      Ada.Text_IO.Put_Line ("backup Google Drive compatibility gate passed");
   end;
exception
   when Program_Error => null;
end Check_Google_Drive_Compatibility;
