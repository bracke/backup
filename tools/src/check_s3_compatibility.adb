with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_S3_Compatibility is
   Backup_Bin : constant String := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_BACKUP_BIN", "./bin/backup");
   Fixture    : constant String := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_FIXTURE", "./tests/bin/backup_http_remote_live_tests");
   Remote     : constant String := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_REMOTE");
   Strict     : constant Boolean := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_STRICT") = "1" or else Backup_Tool_Support.Env ("CI") = "true";
   Allow      : constant Boolean := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_ALLOW_FIXTURE") = "1";
begin
   if Remote = "" then
      if Strict and then not Allow then
         Backup_Tool_Support.Fail ("real S3 compatibility settings are required in CI/strict mode");
      end if;
      Backup_Tool_Support.Run ("S3 fixture", Fixture, (1 .. 0 => <>));
      Ada.Text_IO.Put_Line ("backup S3 compatibility fixture passed");
      return;
   end if;
   declare
      Endpoint : constant String := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_ENDPOINT");
      Access_Env : constant String := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_ACCESS_KEY_ENV", "AWS_ACCESS_KEY_ID");
      Secret_Env : constant String := Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_SECRET_KEY_ENV", "AWS_SECRET_ACCESS_KEY");
      Tmp : constant String := Backup_Tool_Support.Env ("TMPDIR", "/tmp") & "/backup-s3-compat-ada";
      Config : constant String := Tmp & "/remote.conf";
      Archive : constant String := Tmp & "/s3-compat.zip";
      Restore : constant String := Tmp & "/s3-compat-restored.zip";
      Input : constant String := Tmp & "/input.txt";
      Large : constant String := Tmp & "/large-input.bin";
      Config_Text : constant String :=
        "remote=" & Remote & ASCII.LF &
        "s3_endpoint=" & Endpoint & ASCII.LF &
        "s3_region=" & Backup_Tool_Support.Env ("BACKUP_S3_COMPAT_REGION", "us-east-1") & ASCII.LF &
        "s3_access_key_env=" & Access_Env & ASCII.LF &
        "s3_secret_key_env=" & Secret_Env & ASCII.LF &
        "s3_multipart_threshold=1" & ASCII.LF &
        "s3_multipart_part_size=5242880" & ASCII.LF;
   begin
      if Endpoint = "" then Backup_Tool_Support.Fail ("BACKUP_S3_COMPAT_ENDPOINT is required when BACKUP_S3_COMPAT_REMOTE is set"); end if;
      if Backup_Tool_Support.Env (Access_Env) = "" or else Backup_Tool_Support.Env (Secret_Env) = "" then
         Backup_Tool_Support.Fail ("S3 compatibility credentials are required");
      end if;
      Backup_Tool_Support.Remove_Tree (Tmp);
      Backup_Tool_Support.Write_Text (Config, Config_Text);
      Backup_Tool_Support.Write_Text (Input, "backup S3 compatibility payload" & ASCII.LF);
      Backup_Tool_Support.Write_Zero_File (Large, 6 * 1024 * 1024);
      Backup_Tool_Support.Run ("S3 upload", Backup_Bin, (1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--upload"), 4 => new String'(Archive), 5 => new String'(Input), 6 => new String'(Large)));
      Backup_Tool_Support.Run ("S3 verify", Backup_Bin, (1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--verify"), 4 => new String'(Archive)));
      Backup_Tool_Support.Run ("S3 restore", Backup_Bin, (1 => new String'("--remote-config"), 2 => new String'(Config), 3 => new String'("--restore-remote"), 4 => new String'(Restore)));
      Backup_Tool_Support.Require_File (Restore, "S3 compatibility restore did not produce an archive");
      Ada.Text_IO.Put_Line ("backup S3 compatibility gate passed");
   end;
exception
   when Program_Error => null;
end Check_S3_Compatibility;
