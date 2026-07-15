with Backup_Test_Temp;
with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Backup.Incremental;
with Backup.Manifest;
with Backup.Paths;
with Backup.Scanner;
with Backup.Zip;

procedure Backup_Incremental_Tests is
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Ada.Streams.Stream_Element_Offset;
   use type Backup.Incremental.Plan_Status;
   use type Backup.Incremental.Decision_Kind;
   use type Backup.Zip.Write_Result;
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

   function Root return String is
   begin
      return Ada.Directories.Compose
        (Backup_Test_Temp.Base,
         "backup_incremental_tests");
   end Root;

   procedure Ensure_Clean_Root is
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Root);
   end Ensure_Clean_Root;

   procedure Write_Text
     (Path : String;
      Text : String)
   is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      if Text'Length > 0 then
         declare
            Data : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
            Pos  : Ada.Streams.Stream_Element_Offset := Data'First;
         begin
            for Ch of Text loop
               Data (Pos) := Ada.Streams.Stream_Element (Character'Pos (Ch));
               Pos := Pos + Ada.Streams.Stream_Element_Offset (1);
            end loop;
            Ada.Streams.Stream_IO.Write (File, Data);
         end;
      end if;
      Ada.Streams.Stream_IO.Close (File);
   end Write_Text;

   function Archive_Path (Name : String) return Backup.Paths.Archive_Path is
      Result : Backup.Paths.Archive_Path;
      Status : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path (Name, Result);
   begin
      pragma Assert (Status = Backup.Paths.Valid, "test archive path valid");
      return Result;
   end Archive_Path;

   function Scan_File
     (Source_Path  : String;
      Archive_Name : String;
      Method       : Backup.Zip.Compression_Method)
      return Backup.Scanner.Discovered_Entry
   is
   begin
      return
        (Source_Path           =>
           Backup.Paths.Normalize_File_System_Path (Source_Path),
         Archive_Path          => Archive_Path (Archive_Name),
         Kind                  => Backup.Scanner.Entry_File,
         Byte_Size             =>
           Unsigned_64 (Ada.Directories.Size (Source_Path)),
         Has_Modification_Time => False,
         Modification_Time     => Ada.Calendar.Time_Of (1901, 1, 1),
         Compression_Method    => Method,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Link_Target           => Null_Unbounded_String);
   end Scan_File;

   function Scan_Symlink
     (Archive_Name : String;
      Target       : String)
      return Backup.Scanner.Discovered_Entry
   is
   begin
      return
        (Source_Path           =>
           Backup.Paths.Normalize_File_System_Path ("."),
         Archive_Path          => Archive_Path (Archive_Name),
         Kind                  => Backup.Scanner.Entry_Symlink,
         Byte_Size             => Unsigned_64 (Target'Length),
         Has_Modification_Time => False,
         Modification_Time     => Ada.Calendar.Time_Of (1901, 1, 1),
         Compression_Method    => Backup.Zip.Stored,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Link_Target           => To_Unbounded_String (Target));
   end Scan_Symlink;

   function Zip_File
     (Source_Path  : String;
      Archive_Name : String;
      Method       : Backup.Zip.Compression_Method)
      return Backup.Zip.Source_Entry
   is
   begin
      return
        (Source_Path  => Backup.Paths.Normalize_File_System_Path (Source_Path),
         Archive_Path => Archive_Path (Archive_Name),
         Byte_Size    => 0,
         Method       => Method,
         Kind         => Backup.Zip.Source_File,
         Generated    => False,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Content      => Null_Unbounded_String);
   end Zip_File;

   function Find_Decision
     (Plan : Backup.Incremental.Plan;
      Name : String)
      return Backup.Incremental.Decision_Kind
   is
   begin
      for Item of Plan.Items loop
         if To_String (Item.Archive_Path) = Name then
            return Item.Decision;
         end if;
      end loop;
      return Backup.Incremental.Decision_Skipped;
   end Find_Decision;

   function Contains
     (Text     : Unbounded_String;
      Fragment : String)
      return Boolean
   is
   begin
      return Ada.Strings.Unbounded.Index (Text, Fragment) /= 0;
   end Contains;

   procedure Test_Archive_Planning is
      Old_A      : constant String :=
        Ada.Directories.Compose (Root, "old-a.txt");
      Old_B      : constant String :=
        Ada.Directories.Compose (Root, "old-b.txt");
      Old_D      : constant String :=
        Ada.Directories.Compose (Root, "old-d.txt");
      Removed    : constant String :=
        Ada.Directories.Compose (Root, "removed.txt");
      Current_A  : constant String :=
        Ada.Directories.Compose (Root, "current-a.txt");
      Current_B  : constant String :=
        Ada.Directories.Compose (Root, "current-b.txt");
      Current_C  : constant String :=
        Ada.Directories.Compose (Root, "current-c.txt");
      Current_D  : constant String :=
        Ada.Directories.Compose (Root, "current-d.txt");
      Archive    : constant String :=
        Ada.Directories.Compose (Root, "previous.zip");
      Prior_Zip  : Backup.Zip.Source_Entry_Vectors.Vector;
      Current    : Backup.Scanner.Entry_Vectors.Vector;
      Plan       : Backup.Incremental.Plan;
      Diagnostic : Unbounded_String;
      Status     : Backup.Incremental.Plan_Status;
   begin
      Write_Text (Old_A, "same");
      Write_Text (Old_B, "before");
      Write_Text (Old_D, "same deflated");
      Write_Text (Removed, "gone");
      Prior_Zip.Append (Zip_File (Old_A, "a.txt", Backup.Zip.Stored));
      Prior_Zip.Append (Zip_File (Old_B, "b.txt", Backup.Zip.Deflated));
      Prior_Zip.Append (Zip_File (Old_D, "d.txt", Backup.Zip.Deflated));
      Prior_Zip.Append (Zip_File (Removed, "removed.txt", Backup.Zip.Stored));
      Check
        (Backup.Zip.Create_Archive (Archive, Prior_Zip) = Backup.Zip.Write_Ok,
         "previous archive created");

      Write_Text (Current_A, "same");
      Write_Text (Current_B, "after");
      Write_Text (Current_C, "new");
      Write_Text (Current_D, "same deflated");
      Current.Append (Scan_File (Current_A, "a.txt", Backup.Zip.Stored));
      Current.Append (Scan_File (Current_B, "b.txt", Backup.Zip.Deflated));
      Current.Append (Scan_File (Current_C, "c.txt", Backup.Zip.Stored));
      Current.Append (Scan_File (Current_D, "d.txt", Backup.Zip.Deflated));

      Status := Backup.Incremental.Build_From_Archive
        (Archive, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "archive incremental planning succeeds: " & To_String (Diagnostic));
      Check
        (Find_Decision (Plan, "a.txt") = Backup.Incremental.Decision_Reused,
         "unchanged stored file reused");
      Check
        (Find_Decision (Plan, "b.txt") = Backup.Incremental.Decision_Modified,
         "changed deflated file modified");
      Check
        (Find_Decision (Plan, "c.txt") = Backup.Incremental.Decision_Added,
         "new file added");
      Check
        (Find_Decision (Plan, "d.txt") = Backup.Incremental.Decision_Reused,
         "unchanged deflated file reused");
      Check
        (Find_Decision (Plan, "removed.txt") =
         Backup.Incremental.Decision_Removed,
         "missing previous file removed");
      Check (Plan.Reused_Count = 2, "reused count");
      Check (Plan.Modified_Count = 1, "modified count");
      Check (Plan.Added_Count = 1, "added count");
      Check (Plan.Removed_Count = 1, "removed count");
      Backup.Incremental.Build_JSON_Report (Plan, Diagnostic);
      Check
        (Contains (Diagnostic, '"' & "format" & '"' & ": " &
           '"' & "backup-incremental-plan-v1" & '"'),
         "incremental JSON format marker");
      Check
        (Contains (Diagnostic, '"' & "decision" & '"' & ": " &
           '"' & "reused" & '"'),
         "incremental JSON includes reused decision");
      Backup.Incremental.Build_Dry_Run_Report (Plan, Diagnostic);
      Check
        (Contains (Diagnostic, "strategy: synthetic-full-archive"),
         "incremental dry-run strategy");
      Check
        (Contains (Diagnostic, "payload-reuse: semantic-plan"),
         "incremental dry-run states payload reuse strategy");
      Check
        (Contains (Diagnostic, "trust-model:"),
         "incremental dry-run states trust model");
   end Test_Archive_Planning;

   procedure Test_Manifest_And_Symlink_Planning is
      Current_File : constant String :=
        Ada.Directories.Compose (Root, "same.txt");
      Prior        : Backup.Scanner.Entry_Vectors.Vector;
      Current      : Backup.Scanner.Entry_Vectors.Vector;
      Manifest     : Unbounded_String;
      Manifest_Path : constant String :=
        Ada.Directories.Compose (Root, "manifest.json");
      Plan         : Backup.Incremental.Plan;
      Diagnostic   : Unbounded_String;
      Status       : Backup.Incremental.Plan_Status;
   begin
      Write_Text (Current_File, "same");
      Prior.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Prior.Append (Scan_Symlink ("link", "target-one"));
      Prior.Append (Scan_Symlink ("quoted-link", "target""quoted"));
      Prior.Append
        (Scan_Symlink
           ("tricky-link",
            "note ""archive_path"": ""ghost.txt"""));
      Check
        (Backup.Manifest.Build (Prior, Manifest) = Backup.Manifest.Build_Ok,
         "prior manifest built");
      declare
         Text : constant String := To_String (Manifest);
      begin
         if Text'Length > 0 and then Text (Text'Last) = ASCII.LF then
            Write_Text (Manifest_Path, Text (Text'First .. Text'Last - 1));
         else
            Write_Text (Manifest_Path, Text);
         end if;
      end;

      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Current.Append (Scan_Symlink ("link", "target-two"));
      Current.Append (Scan_Symlink ("quoted-link", "target""quoted"));
      Current.Append
        (Scan_Symlink
           ("tricky-link",
            "note ""archive_path"": ""ghost.txt"""));
      Status := Backup.Incremental.Build_From_Manifest
        (Manifest_Path, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "manifest incremental planning succeeds: " & To_String (Diagnostic));
      Check
        (Find_Decision (Plan, "same.txt") =
         Backup.Incremental.Decision_Reused,
         "manifest unchanged file reused");
      Check
        (Find_Decision (Plan, "link") =
         Backup.Incremental.Decision_Modified,
         "manifest changed symlink modified");
      Check
        (Find_Decision (Plan, "quoted-link") =
         Backup.Incremental.Decision_Reused,
         "manifest escaped symlink target reused");
      Check
        (Find_Decision (Plan, "tricky-link") =
         Backup.Incremental.Decision_Reused,
         "manifest escaped key-like symlink target reused");
      Check
        (Natural (Plan.Items.Length) = 4,
         "escaped key-like symlink target does not create phantom entries");
   end Test_Manifest_And_Symlink_Planning;

   procedure Test_Rejection_Paths is
      Current_File : constant String :=
        Ada.Directories.Compose (Root, "reject-current.txt");
      Bad_Manifest : constant String :=
        Ada.Directories.Compose (Root, "bad-manifest.json");
      Out_File     : Ada.Text_IO.File_Type;
      Current      : Backup.Scanner.Entry_Vectors.Vector;
      Plan         : Backup.Incremental.Plan;
      Diagnostic   : Unbounded_String;
      Status       : Backup.Incremental.Plan_Status;
   begin
      Write_Text (Current_File, "same");
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"" " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest root fields without comma are rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""bad-separator.txt"" " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entry fields without comma are rejected");

      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest & ".missing", Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Previous_Open_Failed,
         "missing manifest rejected as open failure");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""same.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}," &
         "{""archive_path"": ""same.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Current.Clear;
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Duplicate_Archive_Path,
         "duplicate prior manifest path rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""../evil"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Archive_Path,
         "invalid prior manifest path rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""note"": ""{"", " &
         """archive_path"": ""brace.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "manifest parser ignores braces inside string fields: " &
         To_String (Diagnostic));
      Check
        (Find_Decision (Plan, "brace.txt") =
         Backup.Incremental.Decision_Removed,
         "manifest parser found entry after string brace");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""link"", " &
         """kind"": ""symlink"", " &
         """compression_method"": ""stored"", " &
         """link_target"": ""x"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 1, " &
         """compressed_size"": 1}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Conflicting_Metadata,
         "conflicting prior symlink metadata rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""bad-link-size"", " &
         """kind"": ""symlink"", " &
         """compression_method"": ""stored"", " &
         """link_target"": ""x"", " &
         """crc32"": 2363233923, " &
         """uncompressed_size"": 2, " &
         """compressed_size"": 2}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Conflicting_Metadata,
         "prior symlink target length mismatch rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""file-with-link-target.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """link_target"": ""not-valid-for-file"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "prior file manifest entry with link_target rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""dup-link-target"", " &
         """kind"": ""symlink"", " &
         """compression_method"": ""stored"", " &
         """link_target"": ""x"", " &
         """link_target"": ""y"", " &
         """crc32"": 2363233923, " &
         """uncompressed_size"": 1, " &
         """compressed_size"": 1}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate symlink link_target is rejected");



      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "[]");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest with non-object root is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": []} " &
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest with trailing root content is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """format"": ""backup-manifest-v1"", " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate top-level manifest format is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [], ""entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate top-level manifest entries are rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""one.txt"", " &
         """archive_path"": ""two.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate manifest entry archive_path is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""dup-kind.txt"", " &
         """kind"": ""file"", " &
         """kind"": ""symlink"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate manifest entry required metadata is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"" " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest root fields without comma are rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""bad-separator.txt"" " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entry fields without comma are rejected");

      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """archive_path"": ""outside-entries.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0, " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Current.Clear;
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "manifest planning ignores archive_path outside entries array: " &
         To_String (Diagnostic));
      Check
        (Natural (Plan.Items.Length) = 0,
         "archive_path outside entries array does not create prior entry");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1""}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest without entries array rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """metadata"": {""entries"": [" &
         "{""archive_path"": ""nested-only.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}, " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Current.Clear;
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "nested metadata entries are not used for incremental planning: " &
         To_String (Diagnostic));
      Check
        (Natural (Plan.Items.Length) = 0,
         "nested metadata entries do not create prior entries");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""metadata"": {""format"": ""backup-manifest-v1""}, " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "nested-only manifest format is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [42]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "non-object manifest entry is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [42, " &
         "{""archive_path"": ""after-scalar.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "non-object manifest entry before valid object is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""trailing-comma.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0},]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entries trailing comma is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""bad-string.txt"" false, " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Current.Clear;
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entry string with invalid trailing token is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""bad-number.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0x0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entry number with invalid trailing token is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""leading-zero.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 00, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entry number with leading zero is rejected");


      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """format"": ""backup-manifest-v1"", " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate top-level manifest format is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [], ""entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate top-level manifest entries are rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""one.txt"", " &
         """archive_path"": ""two.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate manifest entry archive_path is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""dup-kind.txt"", " &
         """kind"": ""file"", " &
         """kind"": ""symlink"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "duplicate manifest entry required metadata is rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"" " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest root fields without comma are rejected");

      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""bad-separator.txt"" " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Invalid_Manifest,
         "manifest entry fields without comma are rejected");

      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Current.Append (Scan_File (Current_File, "same.txt", Backup.Zip.Stored));
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Bad_Manifest);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);
      Status := Backup.Incremental.Build_From_Manifest
        (Bad_Manifest, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Duplicate_Archive_Path,
         "duplicate current archive path rejected");
   end Test_Rejection_Paths;



   procedure Test_Skipped_Report_Planning is
      Manifest_Path : constant String :=
        Ada.Directories.Compose (Root, "empty-manifest.json");
      Out_File      : Ada.Text_IO.File_Type;
      Current       : Backup.Scanner.Entry_Vectors.Vector;
      Scan_Report   : Backup.Scanner.Scan_Report;
      Plan          : Backup.Incremental.Plan;
      Diagnostic    : Unbounded_String;
      Status        : Backup.Incremental.Plan_Status;
   begin
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Manifest_Path);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": []}");
      Ada.Text_IO.Close (Out_File);

      Status := Backup.Incremental.Build_From_Manifest
        (Manifest_Path, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "empty manifest incremental planning succeeds");

      Scan_Report.Ignored_Diagnostics.Append
        (Backup.Scanner.Ignored_Diagnostic'(Archive_Path             => To_Unbounded_String ("ignored-dir"),
          Kind                     => Backup.Scanner.Ignored_Directory,
          Matching_Ignore_File     => To_Unbounded_String (".gitignore"),
          Matching_Line_Number     => 1,
          Matching_Original_Text   => To_Unbounded_String ("ignored-dir/"),
          Pruned_Descendants       => True,
          Descendants_Unreachable  => True));
      Scan_Report.Symlink_Diagnostics.Append
        (Backup.Scanner.Symlink_Diagnostic'(Archive_Path => To_Unbounded_String ("skipped-link"),
          Source_Path  => To_Unbounded_String ("link"),
          Target_Text  => To_Unbounded_String ("target"),
          Action       => Backup.Scanner.Symlink_Skipped));

      Backup.Incremental.Append_Skipped_From_Report (Plan, Scan_Report);
      Check (Plan.Skipped_Count = 2, "skipped diagnostics counted");
      Check
        (Find_Decision (Plan, "ignored-dir") =
         Backup.Incremental.Decision_Skipped,
         "ignored directory represented as skipped");
      Check
        (Find_Decision (Plan, "skipped-link") =
         Backup.Incremental.Decision_Skipped,
         "skipped symlink represented as skipped");
      Backup.Incremental.Build_JSON_Report (Plan, Diagnostic);
      Check
        (Contains (Diagnostic, '"' & "decision" & '"' & ": " &
           '"' & "skipped" & '"'),
         "incremental JSON includes skipped decision");
      Check
        (Contains (Diagnostic, '"' & "kind" & '"' & ": " &
           '"' & "directory" & '"'),
         "incremental JSON includes skipped directory kind");
   end Test_Skipped_Report_Planning;


   procedure Test_Prior_Path_Now_Skipped_Supersedes_Removed is
      Manifest_Path : constant String :=
        Ada.Directories.Compose (Root, "prior-now-ignored.json");
      Out_File      : Ada.Text_IO.File_Type;
      Current       : Backup.Scanner.Entry_Vectors.Vector;
      Scan_Report   : Backup.Scanner.Scan_Report;
      Plan          : Backup.Incremental.Plan;
      Diagnostic    : Unbounded_String;
      Status        : Backup.Incremental.Plan_Status;
   begin
      Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Manifest_Path);
      Ada.Text_IO.Put_Line
        (Out_File,
         "{""format"": ""backup-manifest-v1"", " &
         """entries"": [" &
         "{""archive_path"": ""ignored-now.txt"", " &
         """kind"": ""file"", " &
         """compression_method"": ""stored"", " &
         """crc32"": 0, " &
         """uncompressed_size"": 0, " &
         """compressed_size"": 0}]}");
      Ada.Text_IO.Close (Out_File);

      Status := Backup.Incremental.Build_From_Manifest
        (Manifest_Path, Current, Plan, Diagnostic);
      Check
        (Status = Backup.Incremental.Plan_Ok,
         "prior-now-ignored manifest planning succeeds: " &
         To_String (Diagnostic));
      Check
        (Find_Decision (Plan, "ignored-now.txt") =
         Backup.Incremental.Decision_Removed,
         "prior-now-ignored initially appears removed");

      Scan_Report.Ignored_Diagnostics.Append
        (Backup.Scanner.Ignored_Diagnostic'(Archive_Path             => To_Unbounded_String ("ignored-now.txt"),
          Kind                     => Backup.Scanner.Ignored_File,
          Matching_Ignore_File     => To_Unbounded_String (".gitignore"),
          Matching_Line_Number     => 1,
          Matching_Original_Text   => To_Unbounded_String ("ignored-now.txt"),
          Pruned_Descendants       => False,
          Descendants_Unreachable  => False));

      Backup.Incremental.Append_Skipped_From_Report (Plan, Scan_Report);
      Check
        (Find_Decision (Plan, "ignored-now.txt") =
         Backup.Incremental.Decision_Skipped,
         "current ignored prior path is reported as skipped");
      Check (Plan.Removed_Count = 0, "removed count is superseded");
      Check (Plan.Skipped_Count = 1, "skipped count supersedes removed");
      Check
        (Natural (Plan.Items.Length) = 1,
         "no duplicate skipped path added");
   end Test_Prior_Path_Now_Skipped_Supersedes_Removed;

begin
   Ensure_Clean_Root;
   Test_Archive_Planning;
   Test_Manifest_And_Symlink_Planning;
   Test_Rejection_Paths;
   Test_Skipped_Report_Planning;
   Test_Prior_Path_Now_Skipped_Supersedes_Removed;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup incremental tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup incremental test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Incremental_Tests;
