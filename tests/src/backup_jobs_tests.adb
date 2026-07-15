with Ada.Calendar;
with Ada.Command_Line;
with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Project_Tools.Files;

with Backup.CLI;
with Backup.Encryption;
with Backup.Jobs;

procedure Backup_Jobs_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Backup.CLI.Compression_Mode;
   use type Backup.Encryption.Password_Source_Kind;
   use type Backup.Jobs.Archive_Naming_Policy;
   use type Interfaces.Unsigned_64;
   use type Backup.Jobs.Job_Status;
   use type Backup.Jobs.Retention_Kind;

   Root     : constant String := "tmp_backup_jobs_tests";
   Job_Path : constant String := Root & "/job.conf";
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

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Directory (Path);
      end if;
   end Ensure_Directory;

   procedure Write_File
     (Path : String;
      Text : String)
   is
   begin
      Project_Tools.Files.Write_Text_File (Path, Text);
   end Write_File;

   function Args
     (A01 : String := "";
      A02 : String := "";
      A03 : String := "")
      return Backup.CLI.String_Vectors.Vector
   is
      Result : Backup.CLI.String_Vectors.Vector;
   begin
      if A01 /= "" then
         Result.Append (A01);
      end if;
      if A02 /= "" then
         Result.Append (A02);
      end if;
      if A03 /= "" then
         Result.Append (A03);
      end if;
      return Result;
   end Args;

   Job        : Backup.Jobs.Job_Configuration;
   Policy     : Backup.Jobs.Retention_Policy;
   Diagnostic : Unbounded_String;
   Status     : Backup.Jobs.Job_Status;
   Now        : constant Ada.Calendar.Time :=
     Ada.Calendar.Time_Of (2026, 5, 12);
   Candidates : Backup.Jobs.Managed_Backup_Vectors.Vector;
   Deletions  : Backup.Jobs.Managed_Backup_Vectors.Vector;
   Config     : Backup.CLI.Configuration;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/src");
   Write_File (Root & "/src/file.txt", "content" & ASCII.LF);
   Write_File (Root & "/.backupignore", "ignored" & ASCII.LF);

   Write_File
     (Job_Path,
      "format=backup-job-v1" & ASCII.LF &
      "name=nightly" & ASCII.LF &
      "source=" & Root & "/src" & ASCII.LF &
      "ignore=" & Root & "/.backupignore" & ASCII.LF &
      "output=" & Root & "/nightly.zip" & ASCII.LF &
      "output_naming=sequence" & ASCII.LF &
      "compression=deflate" & ASCII.LF &
      "symlinks=store-link" & ASCII.LF &
      "manifest=true" & ASCII.LF &
      "list_json=true" & ASCII.LF &
      "dry_run=true" & ASCII.LF &
      "max_file_size=100" & ASCII.LF &
      "max_total_size=200" & ASCII.LF &
      "verify_after=true" & ASCII.LF &
      "retention_after=true" & ASCII.LF &
      "retention=count:2" & ASCII.LF &
      "schedule=external" & ASCII.LF);

   Status := Backup.Jobs.Load (Job_Path, Job, Diagnostic);
   Check
     (Status = Backup.Jobs.Job_Ok,
      "load valid job: " & To_String (Diagnostic));
   Check (To_String (Job.Name) = "nightly", "job name parsed");
   Check (Job.Inputs.Length = 1, "job source parsed");
   Check (Job.Ignore_Files.Length = 1, "job ignore parsed");
   Check (Job.Compression = Backup.CLI.Compression_Deflate,
          "job compression parsed");
   Check (Job.Manifest, "job manifest parsed");
   Check (Job.List_JSON, "job list_json parsed");
   Check (Job.Dry_Run, "job dry_run parsed");
   Check (Job.Output_Naming = Backup.Jobs.Archive_Name_Sequence,
          "job output naming parsed");
   Check (Job.Max_File_Size.Is_Set and then Job.Max_File_Size.Value = 100,
          "job max file size parsed");
   Check (Job.Max_Total_Size.Is_Set and then Job.Max_Total_Size.Value = 200,
          "job max total size parsed");
   Check (Job.Verify_After, "job verify_after parsed");
   Check (Job.Retention_After, "job retention_after parsed");
   Check (Job.Retention.Kind = Backup.Jobs.Retention_Count,
          "job retention kind parsed");
   Check (Job.Retention.Keep_Count = 2, "job retention count parsed");
   Check (Backup.Jobs.Planned_Output_Path (Job) = Root & "/nightly-000001.zip",
          "sequence naming selects first deterministic archive path");
   Write_File (Root & "/nightly-000001.zip", "old");
   Check (Backup.Jobs.Planned_Output_Path (Job) = Root & "/nightly-000002.zip",
          "sequence naming skips existing archive path");
   Ada.Directories.Delete_File (Root & "/nightly-000001.zip");


   declare
      procedure Check_Job_Compression
        (Name     : String;
         Expected : Backup.CLI.Compression_Mode)
      is
         Path       : constant String := Root & "/" & Name & "-job.conf";
         Parsed     : Backup.Jobs.Job_Configuration;
         Mapped     : Backup.CLI.Configuration;
      begin
         Write_File
           (Path,
            "format=backup-job-v1" & ASCII.LF &
            "name=" & Name & ASCII.LF &
            "source=" & Root & "/src" & ASCII.LF &
            "output=" & Root & "/" & Name & ".zip" & ASCII.LF &
            "compression=" & Name & ASCII.LF);

         Status := Backup.Jobs.Load (Path, Parsed, Diagnostic);
         Check
           (Status = Backup.Jobs.Job_Ok,
            "job accepts " & Name & " compression: " &
            To_String (Diagnostic));
         Check
           (Parsed.Compression = Expected,
            "job " & Name & " compression parsed");

         Backup.Jobs.To_CLI_Config (Parsed, Mapped);
         Check
           (Mapped.Compression = Expected and then Mapped.Compression_Set,
            "job " & Name & " compression maps to CLI config");
      end Check_Job_Compression;
   begin
      Check_Job_Compression ("bzip2", Backup.CLI.Compression_BZip2);
      Check_Job_Compression ("lzma", Backup.CLI.Compression_LZMA);
      Check_Job_Compression ("zstd", Backup.CLI.Compression_Zstd);
   end;


   declare
      Catalog_Job_Path : constant String := Root & "/catalog-job.conf";
      Catalog_Job      : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Catalog_Job_Path,
         "format=backup-job-v1" & ASCII.LF &
         "name=cataloged" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/cataloged.zip" & ASCII.LF &
         "catalog=" & Root & "/backup.catalog" & ASCII.LF &
         "manifest=true" & ASCII.LF &
         "schedule=external" & ASCII.LF);
      Status := Backup.Jobs.Load (Catalog_Job_Path, Catalog_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "job accepts catalog path for scheduled indexing: " &
             To_String (Diagnostic));
      Check (To_String (Catalog_Job.Catalog_File) = Root & "/backup.catalog",
             "job catalog path parsed");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-catalog-dryrun.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/bad-catalog.zip" & ASCII.LF &
         "catalog=" & Root & "/backup.catalog" & ASCII.LF &
         "dry_run=true" & ASCII.LF &
         "schedule=external" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "job rejects catalog path with dry_run=true");
   end;

   declare
      Template_Path : constant String := Root & "/template.conf";
      Template_Job  : Backup.Jobs.Job_Configuration;
   begin
      Status := Backup.Jobs.Write_Template (Template_Path, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok, "write job template");
      Status := Backup.Jobs.Load (Template_Path, Template_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "generated job template loads: " & To_String (Diagnostic));
      Check (Template_Job.Output_Naming = Backup.Jobs.Archive_Name_Sequence,
             "generated template uses sequence naming");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-duplicate.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "source=" & Root & "/./src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "duplicate normalized job sources rejected");
      Check (Index (Diagnostic, "duplicate input path") /= 0,
             "duplicate job source diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-output-input.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/same.zip" & ASCII.LF &
         "output=" & Root & "/same.zip" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "job output path cannot also be input");
      Check (Index (Diagnostic, "output ZIP path") /= 0,
             "job output/input diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-encrypted-deterministic.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/encrypted.zip" & ASCII.LF &
         "deterministic=true" & ASCII.LF &
         "encrypt=true" & ASCII.LF &
         "password_env=BACKUP_TEST_PASSWORD" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "encrypted deterministic job rejected");
      Check (Index (Diagnostic, "cannot be combined") /= 0,
             "encrypted deterministic diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-missing-format.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Missing_Required_Field,
             "job format field is required");
      Check (Index (Diagnostic, "format=backup-job-v1") /= 0,
             "missing format diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-retention.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF &
         "retention=tiered:daily=0,weekly=0,monthly=0" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "empty tiered retention job rejected");
      Check (Index (Diagnostic, "tiered retention") /= 0,
             "empty tiered retention diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-duplicate-key.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF &
         "compression=store" & ASCII.LF &
         "compression=deflate" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "duplicate scalar job key rejected");
      Check (Index (Diagnostic, "duplicate job key") /= 0,
             "duplicate scalar job key diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-schedule.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF &
         "schedule=daily-at:24:00" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "invalid schedule metadata rejected");
      Check (Index (Diagnostic, "schedule daily-at") /= 0,
             "invalid schedule diagnostic");
   end;

   declare
      Scheduled_Path : constant String := Root & "/scheduled-ok.conf";
      Scheduled_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Scheduled_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF &
         "schedule=interval-hours:6" & ASCII.LF);
      Status := Backup.Jobs.Load (Scheduled_Path, Scheduled_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "valid interval schedule metadata accepted");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-missing-incremental.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
   begin
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF &
         "incremental_from=" & Root & "/missing.zip" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "missing incremental archive rejected");
      Check (Index (Diagnostic, "incremental archive does not exist") /= 0,
             "missing incremental archive diagnostic");
   end;

   declare
      Bad_Path : constant String := Root & "/bad-incremental-manifest-dir.conf";
      Bad_Job  : Backup.Jobs.Job_Configuration;
      Manifest_Dir : constant String := Root & "/manifest-dir";
   begin
      Ensure_Directory (Manifest_Dir);
      Write_File
        (Bad_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/out.zip" & ASCII.LF &
         "incremental_from_manifest=" & Manifest_Dir & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Path, Bad_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "non-file incremental manifest rejected");
      Check
        (Index (Diagnostic,
                "incremental manifest is not an ordinary file") /= 0,
         "non-file incremental manifest diagnostic");
   end;

   declare
      Password_Path : constant String := Root & "/password.txt";
      Archive_Path  : constant String := Root & "/previous.zip";
      Enc_Path      : constant String := Root & "/encrypted-valid.conf";
      Inc_Path      : constant String := Root & "/incremental-valid.conf";
      Enc_Job       : Backup.Jobs.Job_Configuration;
      Inc_Job       : Backup.Jobs.Job_Configuration;
      Prompt_Job    : Backup.Jobs.Job_Configuration;
      Prompt_Config : Backup.CLI.Configuration;
      Bad_Prompt_Path : constant String := Root & "/bad-prompt-source.conf";
      Bad_Prompt_Job  : Backup.Jobs.Job_Configuration;
      Inc_Config    : Backup.CLI.Configuration;
   begin
      Write_File (Password_Path, "secret" & ASCII.LF);
      Write_File (Archive_Path, "archive");
      Write_File
        (Enc_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/encrypted.zip" & ASCII.LF &
         "encrypt=true" & ASCII.LF &
         "password_file=" & Password_Path & ASCII.LF &
         "verify_after=true" & ASCII.LF);
      Status := Backup.Jobs.Load (Enc_Path, Enc_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "encrypted scheduled job loads: " & To_String (Diagnostic));
      Check (Enc_Job.Encrypt, "encrypted scheduled job flag parsed");
      Check (Enc_Job.Verify_After,
             "encrypted scheduled job post verification parsed");

      Write_File
        (Inc_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/incremental.zip" & ASCII.LF &
         "incremental_from=" & Archive_Path & ASCII.LF &
         "password_file=" & Password_Path & ASCII.LF);
      Status := Backup.Jobs.Load (Inc_Path, Inc_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "incremental scheduled job loads: " & To_String (Diagnostic));
      Backup.Jobs.To_CLI_Config (Inc_Job, Inc_Config);
      Check (To_String (Inc_Config.Incremental_From_Archive) = Archive_Path,
             "incremental scheduled job maps to CLI configuration");

      Write_File
        (Root & "/prompt-valid.conf",
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/prompt-encrypted.zip" & ASCII.LF &
         "encrypt=true" & ASCII.LF &
         "password_prompt=true" & ASCII.LF);
      Status := Backup.Jobs.Load
        (Root & "/prompt-valid.conf", Prompt_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "encrypted prompt-password job loads: " &
             To_String (Diagnostic));
      Check
        (Prompt_Job.Password.Kind = Backup.Encryption.Password_Prompt,
         "job prompt password source parsed");
      Backup.Jobs.To_CLI_Config (Prompt_Job, Prompt_Config);
      Check
        (Prompt_Config.Password.Kind = Backup.Encryption.Password_Prompt,
         "job prompt password source maps to CLI configuration");

      Write_File
        (Bad_Prompt_Path,
         "format=backup-job-v1" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/bad-prompt.zip" & ASCII.LF &
         "encrypt=true" & ASCII.LF &
         "password_file=" & Password_Path & ASCII.LF &
         "password_prompt=true" & ASCII.LF);
      Status := Backup.Jobs.Load (Bad_Prompt_Path, Bad_Prompt_Job, Diagnostic);
      Check (Status = Backup.Jobs.Job_Malformed,
             "job rejects duplicate prompt password source");
      Check (Index (Diagnostic, "choose only one password source") /= 0,
             "duplicate prompt password source diagnostic");
   end;

   Check
     (Backup.Jobs.Parse_Retention_Policy
        ("age-days:30", Policy, Diagnostic),
      "parse age retention");
   Check (Policy.Kind = Backup.Jobs.Retention_Age_Days,
          "age retention kind");
   Check (Policy.Max_Age_Days = 30, "age retention days");

   Check
     (Backup.Jobs.Parse_Retention_Policy
        ("tiered:daily=7,weekly=4,monthly=12", Policy, Diagnostic),
      "parse tiered retention");
   Check (Policy.Kind = Backup.Jobs.Retention_Tiered,
          "tiered retention kind");
   Check (Policy.Daily = 7
          and then Policy.Weekly = 4
          and then Policy.Monthly = 12,
          "tiered retention buckets");


   Policy := (Kind => Backup.Jobs.Retention_Tiered,
              Keep_Count => 0,
              Max_Age_Days => 0,
              Daily => 1,
              Weekly => 1,
              Monthly => 1);
   Candidates.Clear;
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("daily.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 5, 12),
       Managed => True));
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("weekly.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 5, 4),
       Managed => True));
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("monthly.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 4, 1),
       Managed => True));
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("pruned.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 3, 1),
       Managed => True));
   Status := Backup.Jobs.Select_Retention_Deletions
     (Policy, Now, Candidates, Deletions, Diagnostic);
   Check (Status = Backup.Jobs.Job_Ok, "tiered retention selection ok");
   Check (Deletions.Length = 1, "tiered retention deletes excess candidate");
   Check (To_String (Deletions.First_Element.Path) = "pruned.zip",
          "tiered retention keeps daily weekly and monthly representatives");

   Policy := (Kind => Backup.Jobs.Retention_Count,
              Keep_Count => 2,
              Max_Age_Days => 0,
              Daily => 0,
              Weekly => 0,
              Monthly => 0);
   Candidates.Clear;
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("new.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 5, 12),
       Managed => True));
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("old.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 5, 10),
       Managed => True));
   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("middle.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 5, 11),
       Managed => True));
   Status := Backup.Jobs.Select_Retention_Deletions
     (Policy, Now, Candidates, Deletions, Diagnostic);
   Check (Status = Backup.Jobs.Job_Ok, "count retention selection ok");
   Check (Deletions.Length = 1, "count retention deletes one");
   Check (To_String (Deletions.First_Element.Path) = "old.zip",
          "count retention deletes oldest deterministic candidate");

   Policy := (Kind => Backup.Jobs.Retention_Age_Days,
              Keep_Count => 0,
              Max_Age_Days => 1,
              Daily => 0,
              Weekly => 0,
              Monthly => 0);
   Status := Backup.Jobs.Select_Retention_Deletions
     (Policy, Now, Candidates, Deletions, Diagnostic);
   Check (Status = Backup.Jobs.Job_Ok, "age retention selection ok");
   Check (Deletions.Length = 1, "age retention deletes old backup");
   Check (To_String (Deletions.First_Element.Path) = "old.zip",
          "age retention deletes candidate beyond age");

   Candidates.Append
     (Backup.Jobs.Managed_Backup'(Path => To_Unbounded_String ("/tmp/unmanaged.zip"),
       Created_At => Ada.Calendar.Time_Of (2026, 5, 1),
       Managed => False));
   Status := Backup.Jobs.Select_Retention_Deletions
     (Policy, Now, Candidates, Deletions, Diagnostic);
   Check (Status = Backup.Jobs.Job_Retention_Failed,
          "retention refuses unmanaged candidates");

   Check
     (Backup.CLI.Parse (Args ("--run-job", Job_Path), Config, Diagnostic),
      "CLI parses --run-job");
   Check (Config.Run_Job, "CLI marks run job");
   Check (To_String (Config.Job_File)'Length > 0, "CLI stores job file");

   Check
     (Backup.CLI.Parse
        (Args ("--run-job", Job_Path, "--retention-policy=count:3"),
         Config, Diagnostic),
      "CLI parses run-job retention override");
   Check (To_String (Config.Retention_Override) = "count:3",
          "CLI stores retention override");

   Check
     (Backup.CLI.Parse (Args ("--create-job", Root & "/new-job.conf"),
                        Config,
                        Diagnostic),
      "CLI parses --create-job");
   Check (Config.Create_Job and then not Config.Run_Job,
          "CLI marks create job only");

   declare
      OK : constant Boolean := Backup.CLI.Parse
        (Args ("--run-job", Job_Path, "out.zip"), Config, Diagnostic);
   begin
      Check (not OK, "run-job rejects positional paths");
      Check (Index (Diagnostic, "do not accept positional") /= 0,
             "run-job positional diagnostic");
   end;

   declare
      OK : constant Boolean := Backup.CLI.Parse
        (Args ("--job", Job_Path, "--run-job=" & Job_Path),
         Config, Diagnostic);
   begin
      Check (not OK, "duplicate job file options rejected");
      Check (Index (Diagnostic, "choose only one job file option") /= 0,
             "duplicate job file option diagnostic");
   end;

   declare
      OK : constant Boolean := Backup.CLI.Parse
        (Args ("--retention-policy=count:3", "out.zip", "src"),
         Config, Diagnostic);
   begin
      Check (not OK, "retention policy rejected outside run-job");
      Check
        (Index (Diagnostic, "--retention-policy can only be used") /= 0,
         "retention policy rejection diagnostic");
   end;

   declare
      Dry_Run_Path : constant String := Root & "/dry-run-job.conf";
      Retained_Path : constant String := Root & "/dry-000001.zip";
   begin
      Write_File (Retained_Path, "old archive");
      Write_File
        (Dry_Run_Path,
         "format=backup-job-v1" & ASCII.LF &
         "name=dry-run" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Root & "/dry.zip" & ASCII.LF &
         "dry_run=true" & ASCII.LF &
         "list_json=true" & ASCII.LF &
         "verify_after=true" & ASCII.LF &
         "retention_after=true" & ASCII.LF &
         "retention=count:0" & ASCII.LF);
      Status := Backup.Jobs.Execute (Dry_Run_Path, Diagnostic => Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "dry-run job execution succeeds: " & To_String (Diagnostic));
      Check (Index (Diagnostic, """output""") /= 0,
             "job execution report includes output path");
      Check (Index (Diagnostic, "planned") /= 0,
             "dry-run job report says planned");
      Check (Index (Diagnostic, "verify") /= 0
             and then Index (Diagnostic, "skipped") /= 0,
             "dry-run job skips post-backup verification");
      Check (Index (Diagnostic, "would delete") /= 0,
             "dry-run retention reports planned deletions");
      Check (Ada.Directories.Exists (Retained_Path),
             "dry-run retention does not delete archives");
      Ada.Directories.Delete_File (Retained_Path);
   end;

   declare
      Exact_Job_Path : constant String := Root & "/exact-retention-job.conf";
      Exact_Output   : constant String := Root & "/exact.zip";
      Sequence_Sibling : constant String := Root & "/exact-000001.zip";
   begin
      Write_File (Sequence_Sibling, "sequence sibling must survive");
      Write_File
        (Exact_Job_Path,
         "format=backup-job-v1" & ASCII.LF &
         "name=exact-retention" & ASCII.LF &
         "source=" & Root & "/src" & ASCII.LF &
         "output=" & Exact_Output & ASCII.LF &
         "output_naming=exact" & ASCII.LF &
         "compression=store" & ASCII.LF &
         "retention_after=true" & ASCII.LF &
         "retention=count:0" & ASCII.LF);
      Status := Backup.Jobs.Execute
        (Exact_Job_Path, Diagnostic => Diagnostic);
      Check (Status = Backup.Jobs.Job_Ok,
             "exact job retention succeeds: " & To_String (Diagnostic));
      Check (not Ada.Directories.Exists (Exact_Output),
             "exact job retention may prune exact output");
      Check (Ada.Directories.Exists (Sequence_Sibling),
             "exact job retention does not prune sequence sibling");
      Ada.Directories.Delete_File (Sequence_Sibling);
   end;

   Write_File (Job_Path & ".running", "running" & ASCII.LF);
   Status := Backup.Jobs.Execute (Job_Path, Diagnostic => Diagnostic);
   Check (Status = Backup.Jobs.Job_Interrupted,
          "run-job refuses interrupted marker");
   Ada.Directories.Delete_File (Job_Path & ".running");

   Project_Tools.Files.Delete_Tree (Root);

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup job tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup job test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Jobs_Tests;
