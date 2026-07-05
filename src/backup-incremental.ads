with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

with Backup.Encryption;
with Backup.Scanner;

package Backup.Incremental is
   type Plan_Status is
     (Plan_Ok,
      Plan_Previous_Open_Failed,
      Plan_Previous_Verify_Failed,
      Plan_Invalid_Manifest,
      Plan_Invalid_Archive_Path,
      Plan_Duplicate_Archive_Path,
      Plan_Unreadable_Source,
      Plan_Unsupported_Method,
      Plan_Conflicting_Metadata);

   type Decision_Kind is
     (Decision_Added,
      Decision_Modified,
      Decision_Removed,
      Decision_Reused,
      Decision_Skipped);

   type Plan_Entry_Kind is
     (Plan_File,
      Plan_Directory,
      Plan_Symlink,
      Plan_Manifest);

   type Plan_Item is record
      Archive_Path      : Ada.Strings.Unbounded.Unbounded_String;
      Decision          : Decision_Kind := Decision_Added;
      Kind              : Plan_Entry_Kind := Plan_File;
      Method            : Interfaces.Unsigned_16 := 0;
      Crc32             : Interfaces.Unsigned_32 := 0;
      Compressed_Size   : Interfaces.Unsigned_64 := 0;
      Uncompressed_Size : Interfaces.Unsigned_64 := 0;
      Link_Target       : Ada.Strings.Unbounded.Unbounded_String;
      Previous_Index    : Natural := 0;
      Current_Index     : Natural := 0;
   end record;

   package Plan_Item_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Plan_Item);

   type Incremental_Strategy is
     (Synthetic_Full_Archive);

   type Plan is record
      Strategy       : Incremental_Strategy := Synthetic_Full_Archive;
      Items          : Plan_Item_Vectors.Vector;
      Added_Count    : Natural := 0;
      Modified_Count : Natural := 0;
      Removed_Count  : Natural := 0;
      Reused_Count   : Natural := 0;
      Skipped_Count  : Natural := 0;
   end record;

   function Status_Text (Status : Plan_Status) return String;
   function Decision_Name (Decision : Decision_Kind) return String;
   function Kind_Name (Kind : Plan_Entry_Kind) return String;
   function Method_Name (Method : Interfaces.Unsigned_16) return String;

   function Build_From_Archive
     (Previous_Archive_Path : String;
      Current               : Backup.Scanner.Entry_Vectors.Vector;
      Result                : out Plan;
      Diagnostic            : out Ada.Strings.Unbounded.Unbounded_String)
      return Plan_Status;

   function Build_From_Archive
     (Previous_Archive_Path : String;
      Password              : Backup.Encryption.Password_Source;
      Current               : Backup.Scanner.Entry_Vectors.Vector;
      Result                : out Plan;
      Diagnostic            : out Ada.Strings.Unbounded.Unbounded_String)
      return Plan_Status;

   function Build_From_Manifest
     (Previous_Manifest_Path : String;
      Current                : Backup.Scanner.Entry_Vectors.Vector;
      Result                 : out Plan;
      Diagnostic             : out Ada.Strings.Unbounded.Unbounded_String)
      return Plan_Status;

   procedure Append_Skipped_From_Report
     (Result : in out Plan;
      Report : Backup.Scanner.Scan_Report);

   procedure Build_Dry_Run_Report
     (Result : Plan;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_JSON_Report
     (Result : Plan;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);
end Backup.Incremental;
