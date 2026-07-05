with Ada.Directories;
with Ada.Text_IO;

procedure Backup_Legacy_Scripts_Tests is
   Failures : Natural := 0;

   procedure Check
     (Condition : Boolean;
      Name      : String)
   is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Name);
      end if;
   end Check;

   function Exists_In_Project (Path : String) return Boolean is
   begin
      return Ada.Directories.Exists (Path)
        or else Ada.Directories.Exists ("../" & Path);
   end Exists_In_Project;

   procedure Removed (Name : String) is
   begin
      Check
        (not Exists_In_Project ("src/" & Name),
         Name & " legacy shell launcher was removed");
   end Removed;

begin
   Removed ("run_phase10_integration.sh");
   Removed ("run_phase11_integration.sh");
   Removed ("run_phase12_integration.sh");
   Removed ("run_phase13_integration.sh");
   Removed ("run_phase21_remote_integration.sh");

   Check
     (Exists_In_Project ("tools/src/check_all.adb"),
      "release checks are Ada code");
   Check
     (Exists_In_Project ("tools/src/check_s3_compatibility.adb"),
      "remote compatibility checks are Ada code");

   if Failures /= 0 then
      raise Program_Error;
   end if;

   Ada.Text_IO.Put_Line ("backup legacy script audit passed: legacy shell launchers were removed");
end Backup_Legacy_Scripts_Tests;
