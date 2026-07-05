with Ada.Command_Line;
with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_CLI_Surface is
   Model : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1)
      else "tools/cli_surface.conf");
   Tmp : constant String := Backup_Tool_Support.Env ("TMPDIR", "/tmp") & "/backup-cli-surface-check";

   procedure Check (Artifact : String) is
   begin
      if not Backup_Tool_Support.Same_File (Tmp & "/" & Artifact, Artifact) then
         Backup_Tool_Support.Fail ("generated CLI surface artifact differs: " & Artifact);
      end if;
   end Check;
begin
   Backup_Tool_Support.Remove_Tree (Tmp);
   Backup_Tool_Support.Run
     ("generate CLI surface", "tools/bin/generate_cli_surface",
      (1 => new String'(Model), 2 => new String'(Tmp)), Quiet => True);
   Check ("share/man/man1/backup.1");
   Check ("share/backup/messages.catalog");
   Check ("src/backup-cli_surface.ads");
   Check ("src/backup-cli_surface.adb");
   Check ("docs/CLI_SURFACE.md");
   Check ("share/completions/backup.bash");
   Check ("share/completions/backup.fish");
   Check ("share/completions/backup.ps1");
   Check ("share/completions/_backup");
   Backup_Tool_Support.Remove_Tree (Tmp);
   Ada.Text_IO.Put_Line ("backup CLI surface generation check passed");
exception
   when Program_Error =>
      null;
end Check_CLI_Surface;
