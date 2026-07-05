with Ada.Command_Line;
with Ada.Text_IO;

with Backup_Tool_Support;

procedure Check_Manpage is
   Expected : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1)
      else "share/man/man1/backup.1");
   Tmp : constant String := Backup_Tool_Support.Env ("TMPDIR", "/tmp") & "/backup-manpage-check.ada";
begin
   Backup_Tool_Support.Run
     ("generate man page", "tools/bin/generate_manpage",
      (1 => new String'(Tmp)), Quiet => True);
   if not Backup_Tool_Support.Same_File (Tmp, Expected) then
      Backup_Tool_Support.Fail ("generated man page differs from checked-in share/man/man1/backup.1");
   end if;
   Ada.Text_IO.Put_Line ("backup man page generation check passed");
exception
   when Program_Error =>
      null;
end Check_Manpage;
