with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Backup.CLI;
with Backup.Encryption;
with Backup.Remote;

package Backup.Jobs is
   --  Automated backup job loading, execution, and retention management.
   --
   --  This package is the Phase 20 orchestration layer. It deliberately
   --  delegates archive creation, verification, incremental planning,
   --  symlink handling, ZIP64 handling, and encryption to the existing
   --  workflow packages so scheduled jobs preserve the one-shot CLI
   --  invariants.

   --  Result of job configuration, execution, and retention operations.
   type Job_Status is
     (Job_Ok,
      Job_Open_Failed,
      Job_Read_Failed,
      Job_Write_Failed,
      Job_Malformed,
      Job_Unsupported_Value,
      Job_Missing_Required_Field,
      Job_Backup_Failed,
      Job_Verification_Failed,
      Job_Retention_Failed,
      Job_Interrupted);

   --  Supported retention policy families.
   type Retention_Kind is
     (Retention_None,
      Retention_Count,
      Retention_Age_Days,
      Retention_Tiered);

   --  Destination archive naming policy for repeated automated runs.
   type Archive_Naming_Policy is
     (Archive_Name_Exact,
      Archive_Name_Sequence);

   --  Parsed retention policy.
   --
   --  For Retention_Count, Keep_Count is significant.
   --  For Retention_Age_Days, Max_Age_Days is significant.
   --  For Retention_Tiered, Daily, Weekly, and Monthly are significant.
   type Retention_Policy is record
      Kind       : Retention_Kind := Retention_None;
      Keep_Count : Natural := 0;
      Max_Age_Days : Natural := 0;
      Daily       : Natural := 0;
      Weekly      : Natural := 0;
      Monthly     : Natural := 0;
   end record;

   --  Fully loaded backup job configuration.
   --
   --  Inputs and Ignore_Files preserve configuration-file order. Output_Path
   --  is the configured base archive path; Planned_Output_Path applies the
   --  naming policy and filesystem normalization for the actual run.
   type Job_Configuration is record
      Name        : Ada.Strings.Unbounded.Unbounded_String;
      Output_Path : Ada.Strings.Unbounded.Unbounded_String;
      Output_Naming : Archive_Naming_Policy := Archive_Name_Exact;
      Inputs      : Backup.CLI.String_Vectors.Vector;
      Ignore_Files : Backup.CLI.String_Vectors.Vector;
      Prefix      : Ada.Strings.Unbounded.Unbounded_String;
      Compression : Backup.CLI.Compression_Mode := Backup.CLI.Compression_Auto;
      Symlinks    : Backup.CLI.Symlink_Mode := Backup.CLI.Symlinks_Skip;
      Deterministic : Boolean := False;
      Manifest      : Boolean := False;
      List_JSON     : Boolean := False;
      Dry_Run       : Boolean := False;
      Max_File_Size  : Backup.CLI.Size_Limit;
      Max_Total_Size : Backup.CLI.Size_Limit;
      Incremental_From_Archive : Ada.Strings.Unbounded.Unbounded_String;
      Incremental_From_Manifest : Ada.Strings.Unbounded.Unbounded_String;
      Encrypt  : Boolean := False;
      Password : Backup.Encryption.Password_Source;
      Cipher   : Backup.Encryption.Cipher_Kind :=
        Backup.Encryption.Cipher_AES256_GCM;
      Verify_After : Boolean := False;
      Retention_After : Boolean := False;
      Schedule : Ada.Strings.Unbounded.Unbounded_String;
      Retention : Retention_Policy;
      Remote_URL    : Ada.Strings.Unbounded.Unbounded_String;
      Upload_Remote : Boolean := False;
      Sync_Remote   : Boolean := False;
      Remote_Options : Backup.Remote.Remote_Options;
      Catalog_File  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Retention candidate with explicit managed-set marker.
   --
   --  Select_Retention_Deletions refuses candidates where Managed is False.
   --  This keeps safety checks available even when callers build candidates
   --  outside the normal filesystem discovery path.
   type Managed_Backup is record
      Path       : Ada.Strings.Unbounded.Unbounded_String;
      Created_At : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
      Managed    : Boolean := False;
   end record;

   package Managed_Backup_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Managed_Backup);

   --  Return stable human-readable text for a job status.
   function Status_Text (Status : Job_Status) return String;

   --  Parse retention policy text such as none, count:7, age-days:30,
   --  or tiered:daily=7,weekly=4,monthly=12.
   function Parse_Retention_Policy
     (Text       : String;
      Policy     : out Retention_Policy;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Boolean;

   --  Load and validate a backup-job-v1 configuration file.
   --
   --  The loader rejects malformed lines, unknown keys, duplicate scalar keys,
   --  missing required fields, unsupported values, unsafe incremental sources,
   --  invalid password sources, and job configurations that would bypass
   --  one-shot CLI invariants.
   function Load
     (Path       : String;
      Job        : out Job_Configuration;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Job_Status;

   --  Write a deterministic example job configuration file.
   function Write_Template
     (Path       : String;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Job_Status;

   --  Convert a validated job configuration into the ordinary CLI
   --  configuration consumed by Backup.Workflow.Execute.
   procedure To_CLI_Config
     (Job    : Job_Configuration;
      Config : out Backup.CLI.Configuration);

   --  Return the normalized archive path that the next run will use.
   --
   --  Exact naming returns the configured output path after normalization.
   --  Sequence naming returns the first missing BASE-NNNNNN.zip path.
   function Planned_Output_Path
     (Job : Job_Configuration)
      return String;

   --  Deterministically select managed backup candidates for deletion.
   --
   --  Candidates are sorted newest-first with path tie-breaking. The function
   --  never deletes files; it only returns the deletion plan.
   function Select_Retention_Deletions
     (Policy     : Retention_Policy;
      Now        : Ada.Calendar.Time;
      Candidates : Managed_Backup_Vectors.Vector;
      To_Delete  : out Managed_Backup_Vectors.Vector;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Job_Status;

   --  Execute a job file through the normal backup workflow.
   --
   --  Retention_Override, when non-empty, replaces the job-file retention
   --  policy for this run and enables retention cleanup. Diagnostic receives
   --  either a precise failure message or the deterministic JSON job report.
   function Execute
     (Job_File   : String;
      Retention_Override : String := "";
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Job_Status;
end Backup.Jobs;
