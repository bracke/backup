with Backup_Test_Temp;
with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Project_Tools.Files;

with Backup.Manifest;
with Backup.Paths;
with Backup.Scanner;
with Backup.Zip;

procedure Backup_Manifest_Tests is
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Backup.Manifest.Build_Result;
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

   function Root_Path return String is
   begin
      return Ada.Directories.Compose
        (Backup_Test_Temp.Base,
         "backup_manifest_tests");
   end Root_Path;

   procedure Write_Text
     (Path : String;
      Text : String)
   is
   begin
      Project_Tools.Files.Write_Raw_File (Path, Text);
   end Write_Text;

   function One_Entry
     (Source : String;
      Name   : String;
      Size   : Unsigned_64;
      Method : Backup.Zip.Compression_Method)
      return Backup.Scanner.Entry_Vectors.Vector
   is
      Entries : Backup.Scanner.Entry_Vectors.Vector;
      Archive : Backup.Paths.Archive_Path;
      Status  : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path (Name, Archive);
   begin
      pragma Assert (Status = Backup.Paths.Valid, "test archive path valid");
      Entries.Append
        (Backup.Scanner.Discovered_Entry'(Source_Path           =>
             Backup.Paths.Normalize_File_System_Path (Source),
          Archive_Path          => Archive,
          Kind                  => Backup.Scanner.Entry_File,
          Byte_Size             => Size,
          Has_Modification_Time => False,
          Modification_Time     => Ada.Calendar.Time_Of (1901, 1, 1),
          Compression_Method    => Method,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Link_Target           => Ada.Strings.Unbounded.Null_Unbounded_String));
      return Entries;
   end One_Entry;

   Root       : constant String := Root_Path;
   Source     : constant String := Root & "/file.txt";
   Missing    : constant String := Root & "/missing.txt";
   Content    : Unbounded_String;
   Status     : Backup.Manifest.Build_Result;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;
   Ada.Directories.Create_Path (Root);
   Write_Text (Source, "abc" & ASCII.LF);

   Status := Backup.Manifest.Build
     (One_Entry (Source, "file.txt", 4, Backup.Zip.Deflated), Content);
   Check (Status = Backup.Manifest.Build_Ok, "manifest build succeeds");
   Check
     (Index (Content, "backup-manifest-v1") /= 0,
      "manifest contains format marker");
   Check
     (Index (Content, """archive_path""" & ": " & """file.txt""") /= 0,
      "manifest contains normalized archive path");
   Check
     (Index (Content, """compression_method""" & ": " & """deflated""") /= 0,
      "manifest contains compression method");
   Check
     (Index (Content, """crc32""") /= 0,
      "manifest contains CRC32 metadata");
   Check
     (Index (Content, """compressed_size"": ") /= 0,
      "manifest contains deterministic deflate compressed size");
   Check
     (Index (Content, Root) = 0,
      "manifest does not contain absolute host paths");
   Check
     (Index (Content, """source""" & ": " & """<normalized-input>""") /= 0,
      "manifest source metadata is normalized");

   declare
      Prepared : Backup.Scanner.Entry_Vectors.Vector :=
        One_Entry (Source, "prepared.txt", 4, Backup.Zip.Deflated);
      Item : Backup.Scanner.Discovered_Entry :=
        Prepared.Element (Prepared.First_Index);
   begin
      Item.Has_Prepared_Payload := True;
      Item.Prepared_Payload_Path := To_Unbounded_String (Root & "/prepared.deflate");
      Item.Prepared_Compressed_Size := 123;
      Prepared.Replace_Element (Prepared.First_Index, Item);

      Status := Backup.Manifest.Build (Prepared, Content);
      Check
        (Status = Backup.Manifest.Build_Ok,
         "manifest build succeeds with prepared deflate metadata");
      Check
        (Index (Content, """compressed_size"": 123") /= 0,
         "manifest reuses prepared deflate compressed size");
   end;

   Status := Backup.Manifest.Build
     (One_Entry (Missing, "missing.txt", 1, Backup.Zip.Stored), Content);
   Check
     (Status = Backup.Manifest.Build_Unreadable_Source,
      "manifest build reports missing source metadata");

   Status := Backup.Manifest.Build
     (One_Entry (Source, "changed.txt", 1, Backup.Zip.Stored), Content);
   Check
     (Status = Backup.Manifest.Build_Size_Changed,
      "manifest build reports source-size change");

   Project_Tools.Files.Delete_Tree (Root);

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup manifest tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup manifest test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Manifest_Tests;
