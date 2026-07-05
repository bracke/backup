with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

with Backup.CLI;
with Backup.Zip;
with Backup.Paths;

package Backup.Scanner is
   type Entry_Kind is
     (Entry_File,
      Entry_Symlink);

   type Scan_Status is
     (Scan_Ok,
      Scan_Missing_Input,
      Scan_Unreadable_Input,
      Scan_Unreadable_Directory,
      Scan_Invalid_Archive_Path,
      Scan_Duplicate_Archive_Path,
      Scan_Output_Inside_Input,
      Scan_Symlink_Broken,
      Scan_Symlink_Cycle,
      Scan_Symlink_Target_Outside_Input,
      Scan_Ignore_File_Error);

   type Discovered_Entry is record
      Source_Path           : Backup.Paths.File_System_Path;
      Archive_Path          : Backup.Paths.Archive_Path;
      Kind                  : Entry_Kind := Entry_File;
      Byte_Size             : Interfaces.Unsigned_64 := 0;
      Has_Modification_Time : Boolean := False;
      Modification_Time     : Ada.Calendar.Time :=
        Ada.Calendar.Time_Of (1901, 1, 1);
      Compression_Method    : Backup.Zip.Compression_Method :=
        Backup.Zip.Deflated;
      Has_Prepared_Payload  : Boolean := False;
      Prepared_Payload_Path : Ada.Strings.Unbounded.Unbounded_String;
      Prepared_Compressed_Size : Interfaces.Unsigned_64 := 0;
      Link_Target           : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Entry_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Discovered_Entry);

   type Ignored_Kind is
     (Ignored_File,
      Ignored_Directory,
      Ignored_Symlink);

   type Ignored_Diagnostic is record
      Archive_Path             : Ada.Strings.Unbounded.Unbounded_String;
      Kind                     : Ignored_Kind := Ignored_File;
      Matching_Ignore_File     : Ada.Strings.Unbounded.Unbounded_String;
      Matching_Line_Number     : Positive := 1;
      Matching_Original_Text   : Ada.Strings.Unbounded.Unbounded_String;
      Pruned_Descendants       : Boolean := False;
      Descendants_Unreachable  : Boolean := False;
   end record;

   package Ignored_Diagnostic_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Ignored_Diagnostic);

   type Symlink_Action is
     (Symlink_Skipped,
      Symlink_Stored,
      Symlink_Followed,
      Symlink_Broken,
      Symlink_Cycle,
      Symlink_Outside_Input);

   type Symlink_Diagnostic is record
      Archive_Path : Ada.Strings.Unbounded.Unbounded_String;
      Source_Path  : Ada.Strings.Unbounded.Unbounded_String;
      Target_Text  : Ada.Strings.Unbounded.Unbounded_String;
      Action       : Symlink_Action := Symlink_Skipped;
   end record;

   package Symlink_Diagnostic_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Symlink_Diagnostic);

   type Scan_Report is record
      Entries             : Entry_Vectors.Vector;
      Ignored_Diagnostics : Ignored_Diagnostic_Vectors.Vector;
      Symlink_Diagnostics : Symlink_Diagnostic_Vectors.Vector;
   end record;

   function Scan
     (Config     : Backup.CLI.Configuration;
      Report     : out Scan_Report;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Scan_Status;

   function Scan
     (Config     : Backup.CLI.Configuration;
      Entries    : out Entry_Vectors.Vector;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Scan_Status;

end Backup.Scanner;
