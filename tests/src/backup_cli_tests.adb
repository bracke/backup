with Ada.Command_Line;
with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Process;

with Project_Tools.Files;

with Backup.CLI;

procedure Backup_CLI_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Backup.CLI.Compression_Mode;
   use type Backup.CLI.Symlink_Mode;

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

   function Args
     (A01 : String := "";
      A02 : String := "";
      A03 : String := "";
      A04 : String := "";
      A05 : String := "";
      A06 : String := "";
      A07 : String := "";
      A08 : String := "";
      A09 : String := "";
      A10 : String := "";
      A11 : String := "";
      A12 : String := "")
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

      if A04 /= "" then
         Result.Append (A04);
      end if;

      if A05 /= "" then
         Result.Append (A05);
      end if;

      if A06 /= "" then
         Result.Append (A06);
      end if;

      if A07 /= "" then
         Result.Append (A07);
      end if;

      if A08 /= "" then
         Result.Append (A08);
      end if;

      if A09 /= "" then
         Result.Append (A09);
      end if;

      if A10 /= "" then
         Result.Append (A10);
      end if;

      if A11 /= "" then
         Result.Append (A11);
      end if;

      if A12 /= "" then
         Result.Append (A12);
      end if;
      return Result;
   end Args;

   procedure Expect_OK
     (Name      : String;
      Arguments : Backup.CLI.String_Vectors.Vector;
      Config    : out Backup.CLI.Configuration)
   is
      Diagnostic : Unbounded_String;
      OK         : constant Boolean := Backup.CLI.Parse
        (Arguments, Config, Diagnostic);
   begin
      Check (OK, Name & " should parse: " & To_String (Diagnostic));
   end Expect_OK;

   procedure Expect_Error
     (Name      : String;
      Arguments : Backup.CLI.String_Vectors.Vector;
      Contains  : String)
   is
      Config     : Backup.CLI.Configuration;
      Diagnostic : Unbounded_String;
      OK         : constant Boolean := Backup.CLI.Parse
        (Arguments, Config, Diagnostic);
   begin
      Check (not OK, Name & " should fail");
      Check
        (Ada.Strings.Unbounded.Index (Diagnostic, Contains) /= 0,
         Name & " diagnostic should contain '" & Contains & "', got '" &
         To_String (Diagnostic) & "'");
   end Expect_Error;

   procedure Write_File (Path : String) is
   begin
      Project_Tools.Files.Write_Text_File (Path, "*.o" & ASCII.LF);
   end Write_File;

   function Backup_Binary_Path return String is
      --  Resolve to an absolute native path, and to the .exe on Windows. A bare relative
      --  "bin/backup" with forward slashes did not spawn through CreateProcessW there;
      --  Full_Name gives the OS-canonical path and the extension makes the target
      --  unambiguous. On POSIX this is just the absolute path to bin/backup.
      function Resolve (Base : String) return String is
      begin
         if Ada.Directories.Exists (Base & ".exe") then
            return Ada.Directories.Full_Name (Base & ".exe");
         elsif Ada.Directories.Exists (Base) then
            return Ada.Directories.Full_Name (Base);
         else
            return "";
         end if;
      end Resolve;
   begin
      if Resolve ("bin/backup") /= "" then
         return Resolve ("bin/backup");
      elsif Resolve ("../bin/backup") /= "" then
         return Resolve ("../bin/backup");
      else
         return "bin/backup";
      end if;
   end Backup_Binary_Path;

   --  Run the built binary with one argument, capturing stdout and stderr the way the
   --  old GNAT.OS_Lib.Spawn (Err_To_Out => True) did -- but through Hostkit.Process,
   --  whose Windows path resolves backup.exe from "bin/backup" and captures output via
   --  inherited handles. The raw spawn's output-file redirection did not survive there.
   procedure Run_Backup
     (Argument    : String;
      Output_Path : String;
      Success     : out Boolean;
      Return_Code : out Integer;
      Output      : out Unbounded_String)
   is
      Err_Path : constant String := Output_Path & ".err";
      Args     : Hostkit.String_Vectors.Vector;
      Outcome  : Hostkit.Process.Process_Outcome;

      function File_Text (Path : String) return String is
        (if Ada.Directories.Exists (Path)
         then Project_Tools.Files.Read_Raw_File (Path)
         else "");
   begin
      Args.Append (To_Unbounded_String (Argument));
      Outcome :=
        Hostkit.Process.Run_Captured
          (Program     => Backup_Binary_Path,
           Arguments   => Args,
           Stdout_Path => Output_Path,
           Stderr_Path => Err_Path);
      Success     := Outcome.Started;
      Return_Code := Outcome.Exit_Status;
      Output      :=
        To_Unbounded_String (File_Text (Output_Path) & File_Text (Err_Path));
   end Run_Backup;

   procedure Expect_Help_Advanced_Runtime (Output_Path : String) is
      Success     : Boolean := False;
      Return_Code : Integer := 0;
      Output      : Unbounded_String;
   begin
      Run_Backup ("--help-advanced", Output_Path, Success, Return_Code, Output);

      Check (Success, "binary help-advanced smoke should spawn");
      Check (Return_Code = 0, "binary help-advanced smoke should succeed");
      if Success then
         Check
           (Index (Output, "advanced options:") /= 0,
            "binary help-advanced emits advanced section");
         Check
           (Index (Output, "--remote-config FILE") /= 0,
            "binary help-advanced emits remote options");
         Check
           (Index (Output, "--verify-catalog") /= 0,
            "binary help-advanced emits catalog options");
         Check
           (Index (Output, "--incremental-from-manifest FILE") /= 0,
            "binary help-advanced emits incremental options");
      end if;
   end Expect_Help_Advanced_Runtime;

   procedure Expect_JSON_Error_Runtime (Output_Path : String) is
      Success     : Boolean := False;
      Return_Code : Integer := 0;
      Output      : Unbounded_String;
   begin
      Run_Backup ("--json-errors", Output_Path, Success, Return_Code, Output);

      Check (Success, "binary json-errors smoke should spawn");
      Check (Return_Code /= 0, "binary json-errors smoke should fail");
      if Success then
         Check
           (Index (Output, """format"":""backup-error-v1""") /= 0,
            "binary json-errors smoke emits format marker");
         Check
           (Index (Output, """status"":""error""") /= 0,
            "binary json-errors smoke emits error status");
         Check
           (Index (Output, "missing output ZIP path") /= 0,
            "binary json-errors smoke emits diagnostic message");
      end if;
   end Expect_JSON_Error_Runtime;

   Temp_Dir : constant String := "backup_phase1_cli_tests_tmp";
   Ignore_1 : constant String := Temp_Dir & "/ignore-one";
   Ignore_2 : constant String := Temp_Dir & "/ignore-two";
   Prior_Zip : constant String := Temp_Dir & "/prior.zip";
   Prior_Manifest : constant String := Temp_Dir & "/manifest.json";
   Config   : Backup.CLI.Configuration;
begin
   if Ada.Directories.Exists (Temp_Dir) then
      Project_Tools.Files.Delete_Tree (Temp_Dir);
   end if;

   Ada.Directories.Create_Directory (Temp_Dir);
   Write_File (Ignore_1);
   Write_File (Ignore_2);
   Write_File (Prior_Zip);
   Write_File (Prior_Manifest);

   Expect_OK ("valid minimal invocation", Args ("out.zip", "src"), Config);
   Check (To_String (Config.Output_Path) = "out.zip", "minimal output path");
   Check (Config.Input_Paths.Length = 1, "minimal input count");

   Expect_OK
     ("repeated ignore files",
      Args ("--ignore", Ignore_1, "--ignore", Ignore_2, "out.zip", "src"),
      Config);
   Check (Config.Ignore_Files.Length = 2, "repeated ignore count");
   Check (Config.Ignore_Files.Element (1) = Ignore_1, "first ignore order");
   Check (Config.Ignore_Files.Element (2) = Ignore_2, "second ignore order");

   Expect_OK
     ("option ordering",
      Args ("--dry-run", "out.zip", "src", "--manifest", "--deterministic",
            "--compression=deflate", "--symlinks=store-link", "--list-json"),
      Config);
   Check (Config.Dry_Run, "dry-run parsed");
   Check (Config.Manifest, "manifest parsed");
   Check (Config.Deterministic, "deterministic parsed");
   Check (Config.List_JSON, "list-json parsed");
   Check
     (Config.Compression = Backup.CLI.Compression_Deflate,
      "compression parsed");
   Check (Config.Symlinks = Backup.CLI.Symlinks_Store_Link, "symlinks parsed");

   Expect_OK
     ("bzip2 compression option",
      Args ("--compression=bzip2", "out.zip", "src"), Config);
   Check
     (Config.Compression = Backup.CLI.Compression_BZip2,
      "bzip2 compression parsed");

   Expect_OK
     ("lzma compression option",
      Args ("--compression=lzma", "out.zip", "src"), Config);
   Check
     (Config.Compression = Backup.CLI.Compression_LZMA,
      "lzma compression parsed");

   Expect_OK
     ("zstd compression option",
      Args ("--compression=zstd", "out.zip", "src"), Config);
   Check
     (Config.Compression = Backup.CLI.Compression_Zstd,
      "zstd compression parsed");

   Expect_OK
     ("JSON error diagnostics option",
      Args ("--json-errors", "out.zip", "src"), Config);
   Check (Config.Json_Errors, "json-errors parsed");
   Expect_JSON_Error_Runtime (Temp_Dir & "/json-errors.out");
   Expect_Help_Advanced_Runtime (Temp_Dir & "/help-advanced.out");

   Expect_OK ("verify invocation", Args ("--verify", "out.zip"), Config);
   Check (Config.Verify, "verify parsed");
   Check (Config.Input_Paths.Is_Empty, "verify has no input paths");

   Expect_OK
     ("verify JSON invocation",
      Args ("--verify", "--list-json", "out.zip"), Config);
   Check (Config.Verify and Config.List_JSON, "verify list-json parsed");

   Expect_OK
     ("size limits and prefix",
      Args ("--prefix", "root/name", "--max-file-size", "10",
            "--max-total-size", "25", "out.zip", "src"),
      Config);
   Check (To_String (Config.Prefix) = "root/name", "prefix parsed");
   Check (Config.Max_File_Size.Is_Set, "max file size set");
   Check (Config.Max_Total_Size.Is_Set, "max total size set");

   Expect_OK
     ("incremental archive option",
      Args ("--incremental-from", Prior_Zip, "out.zip", "src"),
      Config);
   Check
     (To_String (Config.Incremental_From_Archive) = Prior_Zip,
      "incremental archive parsed");

   Expect_OK
     ("incremental manifest option",
      Args ("--incremental-from-manifest", Prior_Manifest,
            "out.zip", "src"),
      Config);
   Check
     (To_String (Config.Incremental_From_Manifest) = Prior_Manifest,
      "incremental manifest parsed");

   Expect_Error
     ("unknown option", Args ("--unknown", "out.zip", "src"),
      "unknown option");
   Expect_Error
     ("duplicate inputs", Args ("out.zip", "src", "./src"), "duplicate input");
   Expect_Error
     ("invalid compression", Args ("--compression=gzip", "out.zip", "src"),
      "invalid --compression");
   Expect_Error
     ("invalid symlink mode", Args ("--symlinks=copy", "out.zip", "src"),
      "invalid --symlinks");
   Expect_Error ("missing output", Args, "missing output");
   Expect_Error ("missing input", Args ("out.zip"), "missing input");
   Expect_Error
     ("verify with input", Args ("--verify", "out.zip", "src"),
      "--verify accepts only");
   Expect_Error
     ("verify dry-run", Args ("--verify", "--dry-run", "out.zip"),
      "--verify cannot be combined with --dry-run");
   Expect_Error
     ("missing ignore value", Args ("--ignore"),
      "--ignore requires a value");
   Expect_Error
     ("missing prefix value", Args ("--prefix"),
      "--prefix requires a value");
   Expect_Error
     ("invalid prefix", Args ("--prefix", "/abs", "out.zip", "src"),
      "invalid --prefix");
   Expect_Error
     ("invalid backslash prefix",
      Args ("--prefix", "root\name", "out.zip", "src"),
      "invalid --prefix");
   Expect_Error
     ("invalid size", Args ("--max-file-size", "12x", "out.zip", "src"),
      "decimal byte count");
   Expect_Error
     ("oversized max-file-size value",
      Args ("--max-file-size", "184467440737095516160",
            "out.zip", "src"),
      "too large");
   Expect_Error
     ("invalid total size",
      Args ("--max-total-size", "1_000", "out.zip", "src"),
      "decimal byte count");
   Expect_Error
     ("missing compression value", Args ("--compression", "out.zip", "src"),
      "--compression requires");
   Expect_Error
     ("missing symlink value", Args ("--symlinks", "out.zip", "src"),
      "--symlinks requires");
   Expect_Error
     ("output equals input", Args ("out.zip", "./out.zip"),
      "output ZIP path must not also be an input path");
   Expect_Error
     ("missing ignore file",
      Args ("--ignore", Temp_Dir & "/missing", "out.zip", "src"),
      "ignore file does not exist");
   Expect_Error
     ("incremental source choices conflict",
      Args ("--incremental-from", Prior_Zip,
            "--incremental-from-manifest", Prior_Manifest,
            "out.zip", "src"),
      "choose only one");
   Expect_Error
     ("empty incremental archive equals value",
      Args ("--incremental-from=", "out.zip", "src"),
      "--incremental-from requires a non-empty value");
   Expect_Error
     ("empty incremental manifest equals value",
      Args ("--incremental-from-manifest=", "out.zip", "src"),
      "--incremental-from-manifest requires a non-empty value");
   Expect_Error
     ("missing incremental archive",
      Args ("--incremental-from", Temp_Dir & "/missing.zip",
            "out.zip", "src"),
      "incremental archive does not exist");
   Expect_Error
     ("verify rejects incremental",
      Args ("--verify", "--incremental-from", Prior_Zip, "out.zip"),
      "--verify cannot be combined with incremental options");

   Project_Tools.Files.Delete_Tree (Temp_Dir);

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup CLI tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup CLI test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_CLI_Tests;
