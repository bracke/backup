with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

with Backup.Encryption;
with Backup.Remote;

package Backup.CLI is
   --  Command-line parsing and top-level dispatch for the backup executable.
   --
   --  The parser supports both one-shot archive operations and Phase 20
   --  job-management commands. Job-management commands are mutually exclusive
   --  with one-shot backup, verify, extract, encryption, incremental, and
   --  reporting options; job-specific values belong in the persisted job file.

   --  Process-level success/failure result used by Backup.Main.
   type Exit_Status is
     (Success,
      Failure);

   --  Parsed compression policy.
   type Compression_Mode is
     (Compression_Auto,
      Compression_Store,
      Compression_Deflate,
      Compression_BZip2,
      Compression_LZMA,
      Compression_Zstd);

   --  Parsed symlink handling policy.
   type Symlink_Mode is
     (Symlinks_Skip,
      Symlinks_Store_Link,
      Symlinks_Follow);

   --  Restore behavior when a destination path already exists.
   type Restore_Conflict_Mode is
     (Conflict_Reject,
      Conflict_Skip,
      Conflict_Overwrite,
      Conflict_Rename);

   --  Optional byte-count limit parsed from CLI or job configuration.
   type Size_Limit is record
      Is_Set : Boolean := False;
      Value  : Interfaces.Unsigned_64 := 0;
   end record;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   --  Fully parsed CLI configuration.
   --
   --  Job_File/Create_Job_File and Run_Job/Create_Job identify Phase 20
   --  job-management mode. In that mode ordinary archive positional paths
   --  and one-shot operation options are rejected during final validation.
   type Configuration is record
      Output_Path    : Ada.Strings.Unbounded.Unbounded_String;
      Input_Paths    : String_Vectors.Vector;
      Ignore_Files   : String_Vectors.Vector;
      Prefix         : Ada.Strings.Unbounded.Unbounded_String;
      Dry_Run        : Boolean := False;
      Manifest       : Boolean := False;
      Deterministic  : Boolean := False;
      List_JSON      : Boolean := False;
      Verify         : Boolean := False;
      List_Archive   : Boolean := False;
      Extract        : Boolean := False;
      Output_Dir     : Ada.Strings.Unbounded.Unbounded_String;
      Restore_Only   : String_Vectors.Vector;
      Restore_Exclude : String_Vectors.Vector;
      Restore_Conflict : Restore_Conflict_Mode := Conflict_Reject;
      Incremental_From_Archive  : Ada.Strings.Unbounded.Unbounded_String;
      Incremental_From_Manifest : Ada.Strings.Unbounded.Unbounded_String;
      Compression    : Compression_Mode := Compression_Auto;
      Compression_Set : Boolean := False;
      Symlinks       : Symlink_Mode := Symlinks_Skip;
      Symlinks_Set    : Boolean := False;
      Max_File_Size  : Size_Limit;
      Max_Total_Size : Size_Limit;
      Encrypt        : Boolean := False;
      Password       : Backup.Encryption.Password_Source;
      Cipher         : Backup.Encryption.Cipher_Kind :=
        Backup.Encryption.Cipher_AES256_GCM;
      Cipher_Set     : Boolean := False;
      Job_File       : Ada.Strings.Unbounded.Unbounded_String;
      Create_Job_File : Ada.Strings.Unbounded.Unbounded_String;
      Run_Job        : Boolean := False;
      Create_Job     : Boolean := False;
      Retention_Override : Ada.Strings.Unbounded.Unbounded_String;
      Remote_URL     : Ada.Strings.Unbounded.Unbounded_String;
      Remote_Config  : Ada.Strings.Unbounded.Unbounded_String;
      Upload_Remote  : Boolean := False;
      Sync_Remote    : Boolean := False;
      Restore_Remote : Boolean := False;
      Clean_PCloud_Temporary : Boolean := False;
      Check_PCloud_Remote : Boolean := False;
      Remote_Options : Backup.Remote.Remote_Options;
      Catalog_File  : Ada.Strings.Unbounded.Unbounded_String;
      Catalog_Index : Ada.Strings.Unbounded.Unbounded_String;
      Catalog_Query : Ada.Strings.Unbounded.Unbounded_String;
      Catalog_List_Archives : Boolean := False;
      Catalog_List_Contents : Boolean := False;
      Catalog_Verify : Boolean := False;
      Json_Errors : Boolean := False;
   end record;

   --  Parse command-line arguments into a validated configuration.
   function Parse
     (Arguments  : String_Vectors.Vector;
      Config     : out Configuration;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Boolean;

   --  Parse Ada.Command_Line arguments, dispatch the selected operation,
   --  and print diagnostics/reports.
   function Run return Exit_Status;
end Backup.CLI;
