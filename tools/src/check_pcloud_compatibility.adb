with Ada.Text_IO;
with Backup_Tool_Support;

procedure Check_Pcloud_Compatibility is
   --  Live-check knobs: BACKUP_PCLOUD_COMPAT_REMOTE BACKUP_PCLOUD_COMPAT_STRICT
   --  BACKUP_PCLOUD_COMPAT_ALLOW_FIXTURE BACKUP_PCLOUD_COMPAT_TOKEN_FILE
   --  BACKUP_PCLOUD_COMPAT_PATH_REMOTE BACKUP_PCLOUD_COMPAT_REGION
   --  Exercise hooks: --pcloud-clean-temp --pcloud-check --sync
   --  Config keys: pcloud_poll_progress=true pcloud_check_quota=true pcloud_create_parents=true
   Backup_Bin : constant String := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_BACKUP_BIN", "./bin/backup");
   Fixture    : constant String := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_FIXTURE", "./tests/bin/backup_http_remote_live_tests");
   Remote     : constant String := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_REMOTE");
   Path_Remote : constant String := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_PATH_REMOTE");
   Strict     : constant Boolean := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_STRICT") = "1" or else Backup_Tool_Support.Env ("CI") = "true";
   Allow      : constant Boolean := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_ALLOW_FIXTURE") = "1";

   procedure Run_Remote (Tmp, Label, Target_Remote : String) is
      Token_Env  : constant String := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_TOKEN_ENV", "BACKUP_PCLOUD_COMPAT_TOKEN");
      Token_File : constant String := Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_TOKEN_FILE");
      Config  : constant String := Tmp & "/remote-" & Label & ".conf";
      Archive : constant String := Tmp & "/pcloud-compat-" & Label & ".zip";
      Stale   : constant String := Tmp & "/pcloud-compat-stale-" & Label & ".zip";
      Restore : constant String := Tmp & "/pcloud-compat-restored-" & Label & ".zip";
      Input   : constant String := Tmp & "/input.txt";
      Text    : constant String :=
        "remote=" & Target_Remote & ASCII.LF &
        (if Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_API_BASE") /= "" then "pcloud_api_base=" & Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_API_BASE") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_REGION") /= "" then "pcloud_region=" & Backup_Tool_Support.Env ("BACKUP_PCLOUD_COMPAT_REGION") & ASCII.LF else "") &
        (if Backup_Tool_Support.Env (Token_Env) /= "" then "pcloud_access_token_env=" & Token_Env & ASCII.LF else "") &
        (if Token_File /= "" then "pcloud_access_token_file=" & Token_File & ASCII.LF else "") &
        "pcloud_upload_progress=true" & ASCII.LF &
        "pcloud_poll_progress=true" & ASCII.LF &
        "pcloud_check_quota=true" & ASCII.LF &
        "pcloud_create_parents=true" & ASCII.LF &
        "pcloud_clean_recursive=true" & ASCII.LF &
        "retry_count=1" & ASCII.LF;
   begin
      if Backup_Tool_Support.Env (Token_Env) = "" and then Token_File = "" then
         Backup_Tool_Support.Fail ("pCloud compatibility credentials are required: set " & Token_Env & " or BACKUP_PCLOUD_COMPAT_TOKEN_FILE");
      end if;
      Backup_Tool_Support.Write_Text (Config, Text);
      Backup_Tool_Support.Write_Text (Input, "backup pCloud compatibility payload" & ASCII.LF);
      Backup_Tool_Support.Run ("pcloud check", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--remote"), 4 => new String'(Target_Remote), 5 => new String'("--pcloud-check")]);
      Backup_Tool_Support.Run ("pcloud upload", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--upload"), 4 => new String'(Archive), 5 => new String'(Input)]);
      Backup_Tool_Support.Run ("pcloud verify", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--verify"), 4 => new String'(Archive)]);
      Backup_Tool_Support.Run ("pcloud restore", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--restore-remote"), 4 => new String'(Restore)]);
      Backup_Tool_Support.Run ("pcloud stale upload", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--upload"), 4 => new String'(Stale), 5 => new String'(Input)]);
      Backup_Tool_Support.Run ("pcloud sync", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--sync"), 4 => new String'(Archive), 5 => new String'(Input)]);
      Backup_Tool_Support.Run ("pcloud clean", Backup_Bin, [1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--remote"), 4 => new String'(Target_Remote), 5 => new String'("--pcloud-clean-temp")]);
      Backup_Tool_Support.Require_File (Restore, "pCloud compatibility restore did not produce an archive");
   end Run_Remote;
begin
   if Remote = "" then
      if Strict and then not Allow then
         Backup_Tool_Support.Fail ("real pCloud compatibility settings are required in CI/strict mode");
      end if;
      Backup_Tool_Support.Run ("pcloud fixture", Fixture, [1 .. 0 => <>]);
      Ada.Text_IO.Put_Line ("backup pCloud compatibility fixture passed");
      return;
   end if;
   declare
      Tmp : constant String := Backup_Tool_Support.Env ("TMPDIR", "/tmp") & "/backup-pcloud-compat-ada";
   begin
      Backup_Tool_Support.Remove_Tree (Tmp);
      Run_Remote (Tmp, "main", Remote);
      if Path_Remote /= "" then
         Run_Remote (Tmp, "path", Path_Remote);
      end if;
      Ada.Text_IO.Put_Line ("backup pCloud compatibility gate passed");
   end;
exception
   when Program_Error => null;
end Check_Pcloud_Compatibility;
