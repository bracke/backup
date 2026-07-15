with Backup_Test_Temp;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Project_Tools.Files;

with Backup.Catalog;
with Backup.CLI;
with Backup.Encryption;
with Backup.Workflow;

procedure Backup_Workflow_Tests is
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Backup.Workflow.Execution_Status;
   use type Backup.Catalog.Catalog_Status;

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
         "backup_workflow_tests");
   end Root_Path;

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Directory;

   procedure Write_Text
     (Path : String;
      Text : String)
   is
   begin
      Project_Tools.Files.Write_Raw_File (Path, Text);
   end Write_Text;

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

   function Parsed
     (Arguments : Backup.CLI.String_Vectors.Vector)
      return Backup.CLI.Configuration
   is
      Config     : Backup.CLI.Configuration;
      Diagnostic : Unbounded_String;
      OK         : constant Boolean := Backup.CLI.Parse
        (Arguments, Config, Diagnostic);
   begin
      Check (OK, "workflow fixture CLI parse: " & To_String (Diagnostic));
      return Config;
   end Parsed;

   function Read_All (Path : String) return Stream_Element_Array is
      File   : Ada.Streams.Stream_IO.File_Type;
      Length : Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Length := Stream_Element_Offset
        (Ada.Streams.Stream_IO.Size (File));
      declare
         Data : Stream_Element_Array (1 .. Length);
         Last : Stream_Element_Offset;
      begin
         Ada.Streams.Stream_IO.Read (File, Data, Last);
         Ada.Streams.Stream_IO.Close (File);
         pragma Assert (Last = Data'Last, "read complete file");
         return Data;
      end;
   end Read_All;

   function U16_At
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return Unsigned_16
   is
   begin
      return Unsigned_16 (Data (Pos))
        or Shift_Left (Unsigned_16 (Data (Pos + 1)), 8);
   end U16_At;

   function U32_At
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return Unsigned_32
   is
   begin
      return Unsigned_32 (Data (Pos))
        or Shift_Left (Unsigned_32 (Data (Pos + 1)), 8)
        or Shift_Left (Unsigned_32 (Data (Pos + 2)), 16)
        or Shift_Left (Unsigned_32 (Data (Pos + 3)), 24);
   end U32_At;

   function Count_Method
     (Data   : Stream_Element_Array;
      Method : Unsigned_16)
      return Natural
   is
      Count : Natural := 0;
      Pos   : Stream_Element_Offset := Data'First;
   begin
      while Pos <= Data'Last - 30 loop
         if U32_At (Data, Pos) = 16#0403_4B50# then
            if U16_At (Data, Pos + 8) = Method then
               Count := Count + 1;
            end if;
         end if;
         Pos := Pos + 1;
      end loop;
      return Count;
   end Count_Method;

   function Count_Local_Headers
     (Data : Stream_Element_Array)
      return Natural
   is
      Count : Natural := 0;
   begin
      for Pos in Data'First .. Data'Last - 3 loop
         if U32_At (Data, Pos) = 16#0403_4B50# then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_Local_Headers;


   function Matches_Text
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset;
      Text : String)
      return Boolean
   is
   begin
      if Text'Length = 0 then
         return True;
      elsif Pos < Data'First
        or else Pos + Stream_Element_Offset (Text'Length) - 1 > Data'Last
      then
         return False;
      end if;

      for Offset in 0 .. Text'Length - 1 loop
         if Data (Pos + Stream_Element_Offset (Offset)) /=
           Stream_Element (Character'Pos (Text (Text'First + Offset)))
         then
            return False;
         end if;
      end loop;
      return True;
   end Matches_Text;

   function Decimal_32 (Value : Unsigned_32) return String is
      Image : constant String := Unsigned_32'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal_32;


   function Manifest_Matches_Deflated_Central_Sizes
     (Data : Stream_Element_Array)
      return Boolean
   is
      Pos   : Stream_Element_Offset := Data'First;
      Count : Natural := 0;
   begin
      while Pos <= Data'Last - 46 loop
         if U32_At (Data, Pos) = 16#0201_4B50# then
            declare
               Method         : constant Unsigned_16 := U16_At (Data, Pos + 10);
               CSize          : constant Unsigned_32 := U32_At (Data, Pos + 20);
               Name_Length    : constant Unsigned_16 := U16_At (Data, Pos + 28);
               Extra_Length   : constant Unsigned_16 := U16_At (Data, Pos + 30);
               Comment_Length : constant Unsigned_16 := U16_At (Data, Pos + 32);
               Name_Pos       : constant Stream_Element_Offset := Pos + 46;
               Next_Pos       : constant Stream_Element_Offset :=
                 Name_Pos + Stream_Element_Offset
                   (Name_Length + Extra_Length + Comment_Length);
            begin
               if Method = 8 then
                  Count := Count + 1;
                  declare
                     Needle : constant String :=
                       """compressed_size"": " & Decimal_32 (CSize);
                     Found  : Boolean := False;
                  begin
                     for Search in Data'First
                       .. Data'Last - Stream_Element_Offset (Needle'Length) + 1
                     loop
                        if Matches_Text (Data, Search, Needle) then
                           Found := True;
                           exit;
                        end if;
                     end loop;
                     if not Found then
                        return False;
                     end if;
                  end;
               end if;
               Pos := Next_Pos;
            end;
         else
            Pos := Pos + 1;
         end if;
      end loop;
      return Count > 0;
   end Manifest_Matches_Deflated_Central_Sizes;

   function Counter_Text (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Counter_Text;

   function Has_Prepared_Temp (Base_Path : String) return Boolean is
   begin
      for Counter in Natural range 0 .. 10 loop
         if Ada.Directories.Exists
           (Base_Path & ".prepared-deflate.tmp." & Counter_Text (Counter))
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Prepared_Temp;

   function Equal_File
     (Left  : String;
      Right : String)
      return Boolean
   is
      A : constant Stream_Element_Array := Read_All (Left);
      B : constant Stream_Element_Array := Read_All (Right);
   begin
      return A = B;
   end Equal_File;

   function Contains_Text
     (Data : Stream_Element_Array;
      Text : String)
      return Boolean
   is
   begin
      if Text'Length = 0 then
         return True;
      elsif Data'Length < Text'Length then
         return False;
      end if;

      for Pos in Data'First
        .. Data'Last - Stream_Element_Offset (Text'Length) + 1
      loop
         declare
            Matched : Boolean := True;
         begin
            for Offset in 0 .. Text'Length - 1 loop
               if Data (Pos + Stream_Element_Offset (Offset)) /=
                 Stream_Element (Character'Pos (Text (Text'First + Offset)))
               then
                  Matched := False;
                  exit;
               end if;
            end loop;
            if Matched then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Contains_Text;

   Root        : constant String := Root_Path;
   Source_Root : constant String := Root & "/input";
   Ignore_File : constant String := Root & "/root.ignore";
   Diagnostic  : Unbounded_String;
   Status      : Backup.Workflow.Execution_Status;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;

   Ensure_Directory (Source_Root & "/sub");
   Write_Text (Source_Root & "/main.adb", [1 .. 512 => 'A']);
   Write_Text (Source_Root & "/image.png", "already-compressed");
   Write_Text (Source_Root & "/ignored.tmp", "root ignore");
   Write_Text (Source_Root & "/sub/.gitignore", "hidden.txt" & ASCII.LF);
   Write_Text (Source_Root & "/sub/hidden.txt", "gitignore");
   Write_Text (Source_Root & "/sub/kept.txt", "kept" & ASCII.LF);
   Write_Text (Ignore_File, "ignored.tmp" & ASCII.LF);

   declare
      Output : constant String := Root & "/archive.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--ignore", Ignore_File, "--compression=auto",
               Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "valid end-to-end workflow succeeds: " & To_String (Diagnostic));
      Check (Ada.Directories.Exists (Output), "workflow creates ZIP archive");

      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
      begin
         Check
           (Count_Local_Headers (Zip_Data) = 4,
            "root ignore and discovered .gitignore remove two files");
         Check
           (Count_Method (Zip_Data, 8) >= 1,
            "compression policy reaches ZIP writer as deflate");
         Check
           (Count_Method (Zip_Data, 0) >= 1,
            "compression policy reaches ZIP writer as stored");
      end;
   end;

   declare
      Output : constant String := Root & "/manifest.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args
           ("--manifest", "--compression=auto", "--ignore", Ignore_File,
            Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "manifest workflow succeeds: " & To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Output),
         "manifest workflow creates archive");

      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
      begin
         Check
           (Count_Local_Headers (Zip_Data) = 5,
            "manifest archive contains four files plus manifest");
         Check
           (Contains_Text (Zip_Data, ".backup/manifest.json"),
            "manifest entry path is present in ZIP");
         Check
           (Contains_Text (Zip_Data, "backup-manifest-v1"),
            "manifest JSON content is present");
         Check
           (Contains_Text (Zip_Data, "main.adb"),
            "manifest lists included source entries");
         Check
           (Contains_Text (Zip_Data, "compression_method"),
            "manifest records compression metadata");
         Check
           (Contains_Text (Zip_Data, "crc32"),
            "manifest records CRC32 metadata");
         Check
           (Manifest_Matches_Deflated_Central_Sizes (Zip_Data),
            "manifest compressed sizes match all deflated central entries");
      end;
      Check
        (not Has_Prepared_Temp (Output),
         "manifest workflow removes prepared deflate temp payloads");
   end;

   declare
      First_Output : constant String := Root & "/manifest-deterministic-a.zip";
      Second_Output : constant String :=
        Root & "/manifest-deterministic-b.zip";
      First_Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--manifest", First_Output, Source_Root));
      Second_Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--manifest", Second_Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (First_Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "first deterministic manifest archive succeeds: " &
         To_String (Diagnostic));
      Status := Backup.Workflow.Execute (Second_Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "second deterministic manifest archive succeeds: " &
         To_String (Diagnostic));
      Check
        (Equal_File (First_Output, Second_Output),
         "repeated manifest archive output is deterministic");
   end;

   declare
      First_Output  : constant String := Root & "/deterministic-a.zip";
      Second_Output : constant String := Root & "/deterministic-b.zip";
      First_Config  : constant Backup.CLI.Configuration := Parsed
        (Args ("--ignore", Ignore_File, "--compression=auto",
               First_Output, Source_Root));
      Second_Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--ignore", Ignore_File, "--compression=auto",
               Second_Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (First_Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "first deterministic archive succeeds: " & To_String (Diagnostic));
      Status := Backup.Workflow.Execute (Second_Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "second deterministic archive succeeds: " & To_String (Diagnostic));
      Check
        (Equal_File (First_Output, Second_Output),
         "repeated workflow output is deterministic");
   end;

   declare
      Output : constant String := Root & "/dry-run.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--dry-run", "--manifest", "--ignore", Ignore_File,
               Output, Source_Root));
      First_Report : Unbounded_String;
      Second_Report : Unbounded_String;
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      First_Report := Diagnostic;
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "dry-run workflow succeeds: " & To_String (Diagnostic));
      Check
        (not Ada.Directories.Exists (Output),
         "dry-run does not create output archive");
      Check
        (Index (Diagnostic, "include input/main.adb") /= 0,
         "dry-run reports included entries");
      Check
        (Index (Diagnostic, "ignore input/ignored.tmp") /= 0,
         "dry-run reports ignored root-ignore entries");
      Check
        (Index (Diagnostic, "ignore input/sub/hidden.txt") /= 0,
         "dry-run reports discovered .gitignore entries");
      Check
        (Index (Diagnostic, "method=deflated") /= 0,
         "dry-run reports compression methods");
      Check
        (Index (Diagnostic, ".backup/manifest.json") /= 0,
         "dry-run reports generated manifest entry");
      Check
        (Index (Diagnostic, Root) = 0,
         "dry-run report does not contain absolute host paths");
      Check
        (Index (Diagnostic, "source=<normalized-input>") /= 0,
         "dry-run report normalizes source metadata");

      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Second_Report := Diagnostic;
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "second dry-run workflow succeeds");
      Check
        (First_Report = Second_Report,
         "repeated dry-run output is deterministic");
   end;

   declare
      Output : constant String := Root & "/dry-run-existing.zip";
      Copy   : constant String := Root & "/dry-run-existing-copy.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--dry-run", Output, Source_Root));
   begin
      Write_Text (Output, "existing output must not change" & ASCII.LF);
      Write_Text (Copy, "existing output must not change" & ASCII.LF);
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "dry-run over existing output succeeds");
      Check
        (Equal_File (Output, Copy),
         "dry-run does not modify an existing output archive path");
   end;

   declare
      Output : constant String := Root & "/list-json.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--list-json", Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "list-json workflow succeeds");
      Check
        (Index (Diagnostic, """format"": ""backup-list-v1""") /= 0,
         "list-json emits stable format key");
      Check
        (Index (Diagnostic, """included_entries""") /= 0,
         "list-json reports included entries");
      Check
        (Index (Diagnostic, """ignored_entries""") /= 0,
         "list-json reports ignored entries");
      Check
        (Index (Diagnostic, """compression_method""") /= 0,
         "list-json reports compression method");
      Check
        (Index (Diagnostic, """total_uncompressed_size""") /= 0,
         "list-json reports total candidate byte size");
      Check
        (Index (Diagnostic, """limits""") /= 0,
         "list-json reports configured size limits");
      Check
        (Index (Diagnostic, """descendants_unreachable""") /= 0,
         "list-json reports ignored descendant reachability");
      Check
        (Index (Diagnostic, Root) = 0,
         "list-json does not contain absolute host paths");
      Check
        (Index (Diagnostic, """source"": ""<normalized-input>""") /= 0,
         "list-json normalizes source metadata");
   end;

   declare
      Output : constant String := Root & "/supported-symlink-follow.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--symlinks=follow", Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "follow symlink mode is accepted by workflow");
   end;

   declare
      Output : constant String := Root & "/too-large-file.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--max-file-size", "1", Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Size_Limit_Exceeded,
         "max-file-size rejects oversized candidate");
      Check
        (Index (Diagnostic, "--max-file-size") /= 0,
         "max-file-size diagnostic names option");
      Check
        (Index (Diagnostic, "limit=1") /= 0,
         "max-file-size diagnostic reports limit");
   end;

   declare
      Output : constant String := Root & "/too-large-total.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--max-total-size", "1", Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Size_Limit_Exceeded,
         "max-total-size rejects oversized candidate set");
      Check
        (Index (Diagnostic, "--max-total-size") /= 0,
         "max-total-size diagnostic names option");
      Check
        (Index (Diagnostic, "ignored-files-contribute=no") /= 0,
         "total-size diagnostic documents ignored-file accounting");
   end;

   declare
      Output : constant String := Root & "/ignored-does-not-count.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--ignore", Ignore_File, "--max-total-size", "550",
               Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "ignored files are excluded from total-size accounting: " &
         To_String (Diagnostic));
   end;

   declare
      Output    : constant String := Root & "/encrypted-workflow.benc";
      Pass_File : constant String := Root & "/workflow-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "workflow-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted workflow create succeeds: " & To_String (Diagnostic));
      Check (Ada.Directories.Exists (Output),
             "encrypted workflow creates output archive");
      Check (Backup.Encryption.Is_Encrypted (Output),
             "encrypted workflow output has envelope magic");

      declare
         Enc_Data : constant Stream_Element_Array := Read_All (Output);
      begin
         Check
           (not Contains_Text (Enc_Data, "main.adb"),
            "encrypted workflow output does not expose ZIP filenames");
      end;

      declare
         Catalog_Path : constant String := Root & "/encrypted-workflow.catalog";
         Catalog_Output : constant String :=
           Root & "/encrypted-workflow-catalog.benc";
         Catalog_Data : Backup.Catalog.Catalog_Data;
         Query : Backup.Catalog.Query;
         Result : Backup.Catalog.Query_Result;
         Saw_Entry : Boolean := False;
         Catalog_Status : Backup.Catalog.Catalog_Status;
      begin
         Config := Parsed
           (Args ("--encrypt", "--password-file", Pass_File,
                  "--catalog", Catalog_Path, Catalog_Output, Source_Root));
         Status := Backup.Workflow.Execute (Config, Diagnostic);
         Check
           (Status = Backup.Workflow.Execution_Ok,
            "encrypted workflow create indexes searchable catalog contents: " &
            To_String (Diagnostic));
         Catalog_Status := Backup.Catalog.Load
           (Catalog_Path, Catalog_Data, Diagnostic);
         Check (Catalog_Status = Backup.Catalog.Catalog_Ok,
                "encrypted workflow catalog loads: " & To_String (Diagnostic));
         Catalog_Status := Backup.Catalog.Parse_Query
           ("content:input/main.adb", Query, Diagnostic);
         Check (Catalog_Status = Backup.Catalog.Catalog_Ok,
                "encrypted workflow catalog parses content query");
         Catalog_Status := Backup.Catalog.Query_Catalog
           (Catalog_Data, Query, Result, Diagnostic);
         Check (Catalog_Status = Backup.Catalog.Catalog_Ok,
                "encrypted workflow catalog query executes: " &
                To_String (Diagnostic));
         for Entry_Item of Result.Entries loop
            if To_String (Entry_Item.Archive_Path) = "input/main.adb" then
               Saw_Entry := True;
            end if;
         end loop;
         Check (Saw_Entry,
                "encrypted workflow catalog query finds decrypted entry path");
      end;

      Config := Parsed
        (Args ("--verify", "--password-file", Pass_File, Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted workflow verify succeeds with password: " &
         To_String (Diagnostic));

      Config := Parsed (Args ("--verify", Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Encryption_Failed,
         "encrypted workflow verify without password fails before ZIP parse");
   end;

   declare
      Output     : constant String := Root & "/encrypted-extract.benc";
      Pass_File  : constant String := Root & "/extract-password.txt";
      Restore_To : constant String := Root & "/encrypted-restore";
      Config     : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "extract-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted extraction fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--extract", Output, "--password-file", Pass_File,
               "--output-dir", Restore_To));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted workflow extract succeeds with password: " &
         To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Restore_To & "/input/main.adb"),
         "encrypted extraction restores regular file");
   end;

   declare
      Output    : constant String := Root & "/encrypted-list-json.benc";
      Pass_File : constant String := Root & "/json-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "json-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               "--list-json", Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted list-json workflow succeeds: " & To_String (Diagnostic));
      Check (Index (Diagnostic, """encryption""") /= 0,
             "encrypted list-json reports encryption object");
      Check (Index (Diagnostic, """enabled"": true") /= 0,
             "encrypted list-json reports encryption enabled");
      Check (Index (Diagnostic, """cipher"": ""aes256-gcm""") /= 0,
             "encrypted list-json reports cipher name");
      Check (Index (Diagnostic, """password_source"": ""file""") /= 0,
             "encrypted list-json reports password source kind only");
      Check (Index (Diagnostic, Pass_File) = 0,
             "encrypted list-json does not leak password file path");
      Check (Index (Diagnostic, "json-secret") = 0,
             "encrypted list-json does not leak password contents");
   end;



   declare
      Output    : constant String := Root & "/encrypted-wrong-password.benc";
      Pass_File : constant String := Root & "/wrong-password-good.txt";
      Bad_File  : constant String := Root & "/wrong-password-bad.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "right-secret" & ASCII.LF);
      Write_Text (Bad_File, "wrong-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted wrong-password fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--verify", "--password-file", Bad_File, Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Encryption_Failed,
         "encrypted workflow verify with wrong password fails during authentication");
      Check
        (Index (Diagnostic, "authentication") /= 0,
         "wrong-password verification diagnostic mentions authentication");
   end;

   declare
      Output     : constant String := Root & "/encrypted-extract-no-password.benc";
      Pass_File  : constant String := Root & "/extract-no-password.txt";
      Restore_To : constant String := Root & "/encrypted-restore-no-password";
      Config     : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "extract-no-password-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted missing-password extraction fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--extract", Output, "--output-dir", Restore_To));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Restore_Failed,
         "encrypted workflow extract without password fails before writing files");
      Check
        (not Ada.Directories.Exists (Restore_To & "/input/main.adb"),
         "encrypted missing-password extraction does not restore payload files");
   end;

   declare
      Output   : constant String := Root & "/encrypted-env-list-json.benc";
      Env_Name : constant String := "BACKUP_PHASE19_WORKFLOW_JSON_SECRET";
      Config   : Backup.CLI.Configuration;
   begin
      Ada.Environment_Variables.Set (Env_Name, "env-json-secret");
      Config := Parsed
        (Args ("--encrypt", "--password-env", Env_Name,
               "--list-json", Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted env list-json workflow succeeds: " &
         To_String (Diagnostic));
      Check (Index (Diagnostic, """password_source"": ""env""") /= 0,
             "encrypted env list-json reports env source kind only");
      Check (Index (Diagnostic, Env_Name) = 0,
             "encrypted env list-json does not leak environment variable name");
      Check (Index (Diagnostic, "env-json-secret") = 0,
             "encrypted env list-json does not leak environment password value");
      Ada.Environment_Variables.Clear (Env_Name);
   end;

   declare
      Prior     : constant String := Root & "/encrypted-incremental-prior.benc";
      Output    : constant String := Root & "/encrypted-incremental-output.zip";
      Pass_File : constant String := Root & "/encrypted-incremental-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "incremental-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Prior, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted incremental prior fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--incremental-from", Prior, "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "workflow incremental planning reads encrypted prior archive with password: " &
         To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Output),
         "encrypted incremental workflow writes successor archive");
   end;

   declare
      Prior     : constant String := Root & "/encrypted-incremental-no-password-prior.benc";
      Output    : constant String := Root & "/encrypted-incremental-no-password-output.zip";
      Pass_File : constant String := Root & "/encrypted-incremental-no-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "incremental-missing-password-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Prior, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted incremental missing-password fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--incremental-from", Prior, Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Incremental_Failed,
         "workflow incremental planning without password rejects encrypted prior archive");
      Check
        (not Ada.Directories.Exists (Output),
         "failed encrypted incremental planning does not write successor archive");
   end;



   declare
      Output    : constant String := Root & "/encrypted-dry-run-json.benc";
      Pass_File : constant String := Root & "/dry-run-json-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "dry-run-json-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               "--dry-run", "--list-json", Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted dry-run list-json succeeds: " & To_String (Diagnostic));
      Check
        (not Ada.Directories.Exists (Output),
         "encrypted dry-run list-json does not create output archive");
      Check
        (Index (Diagnostic, """encryption""") /= 0,
         "encrypted dry-run list-json reports encryption object");
      Check
        (Index (Diagnostic, """enabled"": true") /= 0,
         "encrypted dry-run list-json reports encryption enabled");
      Check
        (Index (Diagnostic, Pass_File) = 0,
         "encrypted dry-run list-json does not leak password file path");
   end;

   declare
      Output    : constant String := Root & "/encrypted-existing-output.benc";
      Pass_File : constant String := Root & "/existing-output-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "replace-output-secret" & ASCII.LF);
      Write_Text (Output, "old cleartext output that must be replaced");
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted workflow replaces existing output: " &
         To_String (Diagnostic));
      Check
        (Backup.Encryption.Is_Encrypted (Output),
         "encrypted workflow replacement leaves envelope output");
      declare
         Enc_Data : constant Stream_Element_Array := Read_All (Output);
      begin
         Check
           (not Contains_Text (Enc_Data, "old cleartext output"),
            "encrypted workflow replacement removes old cleartext output");
      end;
   end;

   declare
      Output    : constant String := Root & "/encrypted-manifest.benc";
      Pass_File : constant String := Root & "/encrypted-manifest-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "encrypted-manifest-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--manifest", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted manifest archive creation succeeds: " &
         To_String (Diagnostic));
      Check
        (Backup.Encryption.Is_Encrypted (Output),
         "encrypted manifest archive is written as envelope");

      Config := Parsed
        (Args ("--verify", "--password-file", Pass_File, Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted manifest archive verifies with password: " &
         To_String (Diagnostic));
   end;

   declare
      Output     : constant String := Root & "/encrypted-extract-wrong-password.benc";
      Pass_File  : constant String := Root & "/extract-wrong-good.txt";
      Bad_File   : constant String := Root & "/extract-wrong-bad.txt";
      Restore_To : constant String := Root & "/encrypted-restore-wrong-password";
      Config     : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "extract-right-secret" & ASCII.LF);
      Write_Text (Bad_File, "extract-wrong-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted wrong-password extraction fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--extract", Output, "--password-file", Bad_File,
               "--output-dir", Restore_To));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Restore_Failed,
         "encrypted workflow extract with wrong password fails");
      Check
        (not Ada.Directories.Exists (Restore_To & "/input/main.adb"),
         "encrypted wrong-password extraction does not restore payload files");
   end;

   declare
      Prior     : constant String := Root & "/encrypted-incremental-wrong-password-prior.benc";
      Output    : constant String := Root & "/encrypted-incremental-wrong-password-output.zip";
      Pass_File : constant String := Root & "/encrypted-incremental-wrong-password-good.txt";
      Bad_File  : constant String := Root & "/encrypted-incremental-wrong-password-bad.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "incremental-right-secret" & ASCII.LF);
      Write_Text (Bad_File, "incremental-wrong-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Prior, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted incremental wrong-password fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--incremental-from", Prior, "--password-file", Bad_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Incremental_Failed,
         "workflow incremental planning with wrong password rejects encrypted prior archive");
      Check
        (not Ada.Directories.Exists (Output),
         "failed encrypted incremental wrong-password planning does not write successor archive");
   end;


   declare
      Output    : constant String := Root & "/encrypted-verify-json-temp.benc";
      Pass_File : constant String := Root & "/verify-json-temp-password.txt";
      Temp_Path : constant String := Output & ".phase19-decrypted.zip.0";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "verify-json-temp-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted verify-json temp fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--verify", "--list-json", "--password-file", Pass_File,
               Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted verify with list-json succeeds: " &
         To_String (Diagnostic));
      Check
        (Index (Diagnostic, """format"": ""backup-verify-v1""") /= 0,
         "encrypted verify list-json emits verify JSON report");
      Check
        (not Ada.Directories.Exists (Temp_Path),
         "encrypted verify list-json removes decrypted temp archive");
   end;

   declare
      Output     : constant String := Root & "/encrypted-extract-dry-run-json.benc";
      Pass_File  : constant String := Root & "/extract-dry-run-json-password.txt";
      Restore_To : constant String := Root & "/encrypted-dry-run-restore";
      Temp_Path  : constant String := Output & ".phase19-decrypted.zip.0";
      Config     : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "extract-dry-run-json-secret" & ASCII.LF);
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted extract dry-run fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--dry-run", "--list-json", "--extract", Output,
               "--password-file", Pass_File, "--output-dir", Restore_To));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted extract dry-run list-json succeeds: " &
         To_String (Diagnostic));
      Check
        (Index (Diagnostic, """dry_run"": true") /= 0,
         "encrypted extract dry-run list-json reports dry-run mode");
      Check
        (not Ada.Directories.Exists (Restore_To & "/input/main.adb"),
         "encrypted extract dry-run list-json does not restore payload files");
      Check
        (not Ada.Directories.Exists (Temp_Path),
         "encrypted extract dry-run removes decrypted temp archive");
   end;

   declare
      Output    : constant String := Root & "/plain-verify-with-password.zip";
      Pass_File : constant String := Root & "/plain-verify-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "unused-plain-verify-secret" & ASCII.LF);
      Config := Parsed (Args (Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "plain archive fixture for verify-with-password succeeds: " &
         To_String (Diagnostic));
      Check
        (not Backup.Encryption.Is_Encrypted (Output),
         "plain verify-with-password fixture is not encrypted");

      Config := Parsed
        (Args ("--verify", "--password-file", Pass_File, Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "password source is ignored for unencrypted verify archive: " &
         To_String (Diagnostic));
   end;

   declare
      Output     : constant String := Root & "/plain-extract-with-password.zip";
      Pass_File  : constant String := Root & "/plain-extract-password.txt";
      Restore_To : constant String := Root & "/plain-extract-with-password-restore";
      Config     : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "unused-plain-extract-secret" & ASCII.LF);
      Config := Parsed (Args (Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "plain archive fixture for extract-with-password succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--extract", Output, "--password-file", Pass_File,
               "--output-dir", Restore_To));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "password source is ignored for unencrypted extraction: " &
         To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Restore_To & "/input/main.adb"),
         "unencrypted extraction with unused password source restores payload files");
   end;

   declare
      Prior     : constant String := Root & "/plain-incremental-with-password-prior.zip";
      Output    : constant String := Root & "/plain-incremental-with-password-output.zip";
      Pass_File : constant String := Root & "/plain-incremental-password.txt";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "unused-plain-incremental-secret" & ASCII.LF);
      Config := Parsed (Args (Prior, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "plain incremental prior fixture succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--incremental-from", Prior, "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "password source is ignored for unencrypted incremental prior: " &
         To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Output),
         "unencrypted incremental with unused password source writes successor archive");
   end;

   declare
      Output     : constant String := Root & "/encrypted-read-env.benc";
      Pass_File  : constant String := Root & "/encrypted-read-env-password.txt";
      Restore_To : constant String := Root & "/encrypted-read-env-restore";
      Env_Name   : constant String := "BACKUP_PHASE19_WORKFLOW_READ_ENV";
      Config     : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "read-env-secret" & ASCII.LF);
      Ada.Environment_Variables.Set (Env_Name, "read-env-secret");
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted read-env fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--verify", "--password-env", Env_Name, Output));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted verify accepts password from environment: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--extract", Output, "--password-env", Env_Name,
               "--output-dir", Restore_To));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted extract accepts password from environment: " &
         To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Restore_To & "/input/main.adb"),
         "encrypted env extraction restores payload files");
      Ada.Environment_Variables.Clear (Env_Name);
   end;

   declare
      Prior     : constant String := Root & "/encrypted-incremental-env-prior.benc";
      Output    : constant String := Root & "/encrypted-incremental-env-output.zip";
      Pass_File : constant String := Root & "/encrypted-incremental-env-password.txt";
      Env_Name  : constant String := "BACKUP_PHASE19_WORKFLOW_INCREMENTAL_ENV";
      Config    : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "incremental-env-secret" & ASCII.LF);
      Ada.Environment_Variables.Set (Env_Name, "incremental-env-secret");
      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Prior, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted incremental-env fixture create succeeds: " &
         To_String (Diagnostic));

      Config := Parsed
        (Args ("--incremental-from", Prior, "--password-env", Env_Name,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted incremental planning accepts password from environment: " &
         To_String (Diagnostic));
      Check
        (Ada.Directories.Exists (Output),
         "encrypted incremental env planning writes successor archive");
      Ada.Environment_Variables.Clear (Env_Name);
   end;


   declare
      Output       : constant String := Root & "/encrypted-create-missing-password-file.benc";
      Missing_Pass : constant String := Root & "/does-not-exist-password.txt";
      Plain_Temp0  : constant String := Output & ".phase19-plain.zip.0";
      Enc_Temp0    : constant String := Output & ".phase19-encrypted.tmp.0";
      Config       : Backup.CLI.Configuration;
   begin
      Write_Text (Output, "old output must survive failed encryption");
      if Ada.Directories.Exists (Missing_Pass) then
         Ada.Directories.Delete_File (Missing_Pass);
      end if;

      Config := Parsed
        (Args ("--encrypt", "--password-file", Missing_Pass,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Encryption_Failed,
         "encrypted create with unreadable password file fails in encryption path");
      Check
        (Ada.Directories.Exists (Output),
         "failed encrypted create preserves existing output archive");
      declare
         Output_Data : constant Stream_Element_Array := Read_All (Output);
      begin
         Check
           (Contains_Text (Output_Data, "old output must survive failed encryption"),
            "failed encrypted create leaves existing output content intact");
      end;
      Check
        (not Ada.Directories.Exists (Plain_Temp0),
         "failed encrypted create removes plaintext temporary archive");
      Check
        (not Ada.Directories.Exists (Enc_Temp0),
         "failed encrypted create removes encrypted temporary archive");
   end;

   declare
      Output      : constant String := Root & "/encrypted-create-temp-collision.benc";
      Pass_File   : constant String := Root & "/temp-collision-password.txt";
      Plain_Temp0 : constant String := Output & ".phase19-plain.zip.0";
      Enc_Temp0   : constant String := Output & ".phase19-encrypted.tmp.0";
      Config      : Backup.CLI.Configuration;
   begin
      Write_Text (Pass_File, "temp-collision-secret" & ASCII.LF);
      Write_Text (Plain_Temp0, "preexisting plain temp sentinel");
      Write_Text (Enc_Temp0, "preexisting encrypted temp sentinel");

      Config := Parsed
        (Args ("--encrypt", "--password-file", Pass_File,
               Output, Source_Root));
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "encrypted create succeeds when first temp candidate names already exist: " &
         To_String (Diagnostic));
      Check
        (Backup.Encryption.Is_Encrypted (Output),
         "encrypted create with temp collision still writes envelope");
      Check
        (Ada.Directories.Exists (Plain_Temp0),
         "encrypted create does not remove preexisting plain temp candidate");
      Check
        (Ada.Directories.Exists (Enc_Temp0),
         "encrypted create does not remove preexisting encrypted temp candidate");
      declare
         Plain_Temp_Data : constant Stream_Element_Array := Read_All (Plain_Temp0);
         Enc_Temp_Data   : constant Stream_Element_Array := Read_All (Enc_Temp0);
      begin
         Check
           (Contains_Text (Plain_Temp_Data, "preexisting plain temp sentinel"),
            "preexisting plain temp candidate content is preserved");
         Check
           (Contains_Text (Enc_Temp_Data, "preexisting encrypted temp sentinel"),
            "preexisting encrypted temp candidate content is preserved");
      end;
      Check
        (not Ada.Directories.Exists (Output & ".phase19-plain.zip.1"),
         "successful encrypted create removes alternate plaintext temp file");
      Check
        (not Ada.Directories.Exists (Output & ".phase19-encrypted.tmp.1"),
         "successful encrypted create moves alternate encrypted temp file");
   end;

   declare
      Output : constant String := Root & "/missing.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args (Output, Root & "/missing-input"));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Scan_Failed,
         "missing input fails through workflow path");
      Check
        (Index (Diagnostic, "missing input") /= 0,
         "missing input diagnostic propagated");
   end;

   declare
      Output : constant String := Root & "/missing-dir/out.zip";
      Config : constant Backup.CLI.Configuration := Parsed
        (Args (Output, Source_Root));
   begin
      Status := Backup.Workflow.Execute (Config, Diagnostic);
      Check
        (Status = Backup.Workflow.Execution_Zip_Failed,
         "ZIP writer failure is propagated");
      Check
        (Index (Diagnostic, "write error") /= 0,
         "ZIP writer diagnostic propagated");
   end;

   Project_Tools.Files.Delete_Tree (Root);

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup workflow tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup workflow test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Workflow_Tests;
