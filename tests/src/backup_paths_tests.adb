with Ada.Command_Line;
with Ada.Text_IO;

with Backup.Paths;

procedure Backup_Paths_Tests is
   use type Backup.Paths.Archive_Path;
   use type Backup.Paths.Validation_Status;

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

   procedure Check_Status
     (Actual   : Backup.Paths.Validation_Status;
      Expected : Backup.Paths.Validation_Status;
      Name     : String)
   is
   begin
      Check (Actual = Expected, Name);
   end Check_Status;

   function Archive
     (Text : String)
      return Backup.Paths.Archive_Path
   is
      Path   : Backup.Paths.Archive_Path;
      Status : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path (Text, Path);
   begin
      Check (Status = Backup.Paths.Valid, "make archive path " & Text);
      return Path;
   end Archive;

   function FS
     (Text : String)
      return Backup.Paths.File_System_Path
   is
   begin
      return Backup.Paths.Normalize_File_System_Path (Text);
   end FS;

   Path_A : Backup.Paths.Archive_Path;
   Path_B : Backup.Paths.Archive_Path;
   Status : Backup.Paths.Validation_Status;
   Inputs : Backup.Paths.File_System_Path_Vectors.Vector;
   Set    : Backup.Paths.Archive_Path_Sets.Set;
begin
   Status := Backup.Paths.Make_Archive_Path ("dir\file.txt", Path_A);
   Check_Status
     (Status, Backup.Paths.Valid, "backslash archive separator accepted");
   Check
     (Backup.Paths.To_String (Path_A) = "dir/file.txt",
      "archive separators normalize to slash");

   Check_Status
     (Backup.Paths.Validate_Prefix ("root/name"),
      Backup.Paths.Valid,
      "valid prefix fragment");
   Check_Status
     (Backup.Paths.Validate_Prefix ("root\name"),
      Backup.Paths.Invalid_Prefix,
      "backslash prefix rejected");
   Check_Status
     (Backup.Paths.Validate_Prefix (""),
      Backup.Paths.Empty_Path,
      "empty prefix rejected by normal validation");
   Check_Status
     (Backup.Paths.Validate_Prefix ("/root"),
      Backup.Paths.Absolute_Path,
      "absolute prefix rejected");
   Check_Status
     (Backup.Paths.Validate_Prefix ("root/../name"),
      Backup.Paths.Parent_Component,
      "parent prefix component rejected");
   Check_Status
     (Backup.Paths.Validate_Prefix ("root/"),
      Backup.Paths.Empty_Component,
      "trailing slash prefix rejected");

   Status := Backup.Paths.Apply_Prefix
     ("backup/root", Archive ("src/main.adb"), Path_A);
   Check_Status (Status, Backup.Paths.Valid, "prefix application succeeds");
   Check
     (Backup.Paths.To_String (Path_A) = "backup/root/src/main.adb",
      "prefix application result");

   Check_Status
     (Backup.Paths.Make_Archive_Path ("/absolute", Path_A),
      Backup.Paths.Absolute_Path,
      "absolute archive path rejected");
   Check_Status
     (Backup.Paths.Make_Archive_Path ("a/./b", Path_A),
      Backup.Paths.Current_Component,
      "current archive component rejected");
   Check_Status
     (Backup.Paths.Make_Archive_Path ("a/../b", Path_A),
      Backup.Paths.Parent_Component,
      "parent archive component rejected");
   Check_Status
     (Backup.Paths.Make_Archive_Path ("a//b", Path_A),
      Backup.Paths.Empty_Component,
      "empty archive component rejected");

   Inputs.Append (FS ("src"));
   Inputs.Append (FS ("./src"));
   Check
     (Backup.Paths.Contains_Duplicate_File_System_Path (Inputs),
      "duplicate normalized filesystem inputs detected");

   Check
     (Backup.Paths.Insert_Archive_Path (Set, Archive ("a.txt")),
      "first archive insert succeeds");
   Check
     (not Backup.Paths.Insert_Archive_Path (Set, Archive ("a.txt")),
      "duplicate archive entry detected");

   Path_A := Archive ("b/file.txt");
   Path_B := Archive ("a/file.txt");
   Check (Path_B < Path_A, "archive path ordering is lexical and stable");

   Status := Backup.Paths.Derive_Archive_Path
     (FS ("file.txt"), FS ("file.txt"), Path_A);
   Check_Status
     (Status, Backup.Paths.Valid, "derive archive path for file input");
   Check
     (Backup.Paths.To_String (Path_A) = "file.txt",
      "file input archive path uses base name");

   Status := Backup.Paths.Derive_Archive_Path
     (FS ("src"), FS ("src/lib/unit.adb"), Path_A);
   Check_Status
     (Status, Backup.Paths.Valid,
      "derive archive path for directory descendant");
   Check
     (Backup.Paths.To_String (Path_A) = "src/lib/unit.adb",
      "directory descendant archive path keeps root name and relative path");

   Status := Backup.Paths.Derive_Archive_Path
     (FS ("src"), FS ("other/lib/unit.adb"), Path_A);
   Check_Status
     (Status, Backup.Paths.Escapes_Root,
      "derive archive path rejects descendant outside input root");

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup path tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup path test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Paths_Tests;
