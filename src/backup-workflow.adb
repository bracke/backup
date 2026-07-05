with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Interfaces;

with Backup.Catalog;
with Backup.Compression;
with Backup.Encryption;
with Backup.Incremental;
with Backup.Manifest;
with Backup.Metadata;
with Backup.Paths;
with Backup.Restore;
with Backup.Remote;
with Backup.Scanner;
with Backup.Zip;
with Zlib;
with Backup.Verify;

package body Backup.Workflow is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;
   use type Zlib.Status_Code;
   use type Backup.Zip.Compression_Method;
   use type Backup.Scanner.Scan_Status;
   use type Backup.Scanner.Ignored_Kind;
   use type Backup.Scanner.Entry_Kind;
   use type Backup.Paths.Validation_Status;
   use type Backup.Zip.Write_Result;
   use type Backup.Manifest.Build_Result;
   use type Backup.Verify.Verify_Status;
   use type Backup.Restore.Restore_Status;
   use type Backup.Incremental.Plan_Status;
   use type Backup.Encryption.Envelope_Status;
   use type Backup.Encryption.Password_Source_Kind;
   use type Backup.Remote.Remote_Status;
   use type Backup.Catalog.Catalog_Status;

   function Zip_Result_Text
     (Result : Backup.Zip.Write_Result)
      return String
   is
   begin
      case Result is
         when Backup.Zip.Write_Ok =>
            return "ok";
         when Backup.Zip.Write_Unsupported_Entry =>
            return "unsupported archive entry";
         when Backup.Zip.Write_Unreadable_Source =>
            return "unreadable source file";
         when Backup.Zip.Write_Invalid_Archive_Path =>
            return "invalid archive path";
         when Backup.Zip.Write_Duplicate_Archive_Path =>
            return "duplicate archive path";
         when Backup.Zip.Write_Output_Error =>
            return "output ZIP write error";
         when Backup.Zip.Write_Compression_Failed =>
            return "deflate compression failed";
         when Backup.Zip.Write_Size_Overflow =>
            return "ZIP size accounting overflow";
         when Backup.Zip.Write_Archive_Name_Too_Long =>
            return "archive path name is too long for ZIP";
      end case;
   end Zip_Result_Text;

   function Counter_Text (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Counter_Text;

   function Unique_Temp_Path
     (Base   : String;
      Suffix : String)
      return String
   is
   begin
      for Counter in Natural range 0 .. 10_000 loop
         declare
            Candidate : constant String :=
              Base & Suffix & "." & Counter_Text (Counter);
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;

      return Base & Suffix & ".overflow";
   end Unique_Temp_Path;

   procedure Delete_If_Exists (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Delete_If_Exists;


   function Move_Temp_To_Final
     (Temp_Path   : String;
      Final_Path  : String;
      Diagnostic  : out Unbounded_String)
      return Boolean
   is
      Backup_Path : constant String :=
        Unique_Temp_Path (Final_Path, ".phase19-replace-old");
      Old_Moved   : Boolean := False;
   begin
      if Ada.Directories.Exists (Final_Path) then
         Ada.Directories.Rename (Final_Path, Backup_Path);
         Old_Moved := True;
      end if;

      begin
         Ada.Directories.Rename (Temp_Path, Final_Path);
      exception
         when others =>
            if Old_Moved then
               begin
                  Ada.Directories.Rename (Backup_Path, Final_Path);
               exception
                  when others =>
                     null;
               end;
            end if;

            Diagnostic := To_Unbounded_String
              ("could not replace output archive with encrypted archive: " &
               Final_Path);
            return False;
      end;

      if Old_Moved then
         Delete_If_Exists (Backup_Path);
      end if;

      return True;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("could not replace output archive with encrypted archive: " &
            Final_Path);
         return False;
   end Move_Temp_To_Final;

   function Prepare_Archive_For_Read
     (Archive_Path : String;
      Password     : Backup.Encryption.Password_Source;
      Work_Path    : out Unbounded_String;
      Diagnostic   : out Unbounded_String)
      return Backup.Encryption.Envelope_Status
   is
      Status : Backup.Encryption.Envelope_Status;
   begin
      Work_Path := To_Unbounded_String (Archive_Path);
      if not Backup.Encryption.Is_Encrypted (Archive_Path) then
         return Backup.Encryption.Envelope_Not_Encrypted;
      end if;

      Work_Path := To_Unbounded_String
        (Unique_Temp_Path (Archive_Path, ".phase19-decrypted.zip"));
      Status := Backup.Encryption.Decrypt_File
        (Archive_Path, To_String (Work_Path), Password, Diagnostic);
      if Status /= Backup.Encryption.Envelope_Ok then
         Delete_If_Exists (To_String (Work_Path));
      end if;
      return Status;
   end Prepare_Archive_For_Read;


   procedure Convert_To_Zip_Entries
     (Scanned : Backup.Scanner.Entry_Vectors.Vector;
      Zipped  : out Backup.Zip.Source_Entry_Vectors.Vector)
   is
   begin
      Zipped.Clear;
      for Item of Scanned loop
         Zipped.Append
           (Backup.Zip.Source_Entry'(Source_Path  => Item.Source_Path,
             Archive_Path => Item.Archive_Path,
             Byte_Size    => Item.Byte_Size,
             Method       =>
               (if Item.Kind = Backup.Scanner.Entry_Symlink then
                  Backup.Zip.Stored
                else Item.Compression_Method),
             Kind         =>
               (if Item.Kind = Backup.Scanner.Entry_Symlink then
                  Backup.Zip.Source_Symlink
                else Backup.Zip.Source_File),
             Generated    => False,
             Has_Prepared_Payload  => Item.Has_Prepared_Payload,
             Prepared_Payload_Path => Item.Prepared_Payload_Path,
             Prepared_Compressed_Size => Item.Prepared_Compressed_Size,
             Content      => Item.Link_Target));
      end loop;
   end Convert_To_Zip_Entries;


   procedure Cleanup_Prepared_Payloads
     (Entries : in out Backup.Scanner.Entry_Vectors.Vector)
   is
   begin
      if Entries.Is_Empty then
         return;
      end if;

      for Index in Entries.First_Index .. Entries.Last_Index loop
         declare
            Item : Backup.Scanner.Discovered_Entry := Entries.Element (Index);
         begin
            if Item.Has_Prepared_Payload then
               Delete_If_Exists (To_String (Item.Prepared_Payload_Path));
               Item.Has_Prepared_Payload := False;
               Item.Prepared_Payload_Path := Null_Unbounded_String;
               Item.Prepared_Compressed_Size := 0;
               Entries.Replace_Element (Index, Item);
            end if;
         end;
      end loop;
   end Cleanup_Prepared_Payloads;


   function Prepare_Compressed_Payloads
     (Base_Path  : String;
      Entries    : in out Backup.Scanner.Entry_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Entries.Is_Empty then
         return True;
      end if;

      for Index in Entries.First_Index .. Entries.Last_Index loop
         declare
            Item : Backup.Scanner.Discovered_Entry := Entries.Element (Index);
         begin
            if Item.Kind = Backup.Scanner.Entry_File
              and then Item.Compression_Method = Backup.Zip.Deflated
            then
               declare
                  Temp_Path : constant String :=
                    Unique_Temp_Path (Base_Path, ".prepared-deflate.tmp");
                  Output : Ada.Streams.Stream_IO.File_Type;
                  Opened : Boolean := False;
                  Size   : Interfaces.Unsigned_64 := 0;
                  Status : Zlib.Status_Code := Zlib.Ok;
               begin
                  Ada.Streams.Stream_IO.Create
                    (Output, Ada.Streams.Stream_IO.Out_File, Temp_Path);
                  Opened := True;
                  Zlib.Deflate_Raw_File_To_Stream
                    (Input_Path      => Backup.Paths.To_String (Item.Source_Path),
                     Output          => Output,
                     Mode            => Zlib.Auto,
                     Compressed_Size => Size,
                     Status          => Status);
                  Ada.Streams.Stream_IO.Close (Output);
                  Opened := False;

                  if Status /= Zlib.Ok then
                     Delete_If_Exists (Temp_Path);
                     Cleanup_Prepared_Payloads (Entries);
                     Diagnostic := To_Unbounded_String
                       ("could not prepare deflated payload: " &
                        Backup.Paths.To_String (Item.Archive_Path));
                     return False;
                  end if;

                  Item.Has_Prepared_Payload := True;
                  Item.Prepared_Payload_Path := To_Unbounded_String (Temp_Path);
                  Item.Prepared_Compressed_Size := Size;
                  Entries.Replace_Element (Index, Item);
               exception
                  when others =>
                     if Opened then
                        begin
                           Ada.Streams.Stream_IO.Close (Output);
                        exception
                           when others =>
                              null;
                        end;
                     end if;
                     Delete_If_Exists (Temp_Path);
                     Cleanup_Prepared_Payloads (Entries);
                     Diagnostic := To_Unbounded_String
                       ("could not prepare deflated payload: " &
                        Backup.Paths.To_String (Item.Archive_Path));
                     return False;
               end;
            end if;
         end;
      end loop;

      return True;
   end Prepare_Compressed_Payloads;


   procedure Append_Manifest_Entry
     (Entries          : in out Backup.Zip.Source_Entry_Vectors.Vector;
      Manifest_Content : Unbounded_String)
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path
          (Backup.Manifest.Manifest_Path, Archive);
   begin
      pragma Assert
        (Status = Backup.Paths.Valid,
         "manifest archive path is a valid normalized ZIP path");
      Entries.Append
        (Backup.Zip.Source_Entry'(Source_Path  => Backup.Paths.Normalize_File_System_Path (""),
          Archive_Path => Archive,
          Byte_Size    => 0,
          Method       => Backup.Zip.Stored,
          Kind         => Backup.Zip.Source_Generated,
          Generated    => True,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Content      => Manifest_Content));
   end Append_Manifest_Entry;

   function Kind_Name (Kind : Backup.Scanner.Entry_Kind) return String is
   begin
      case Kind is
         when Backup.Scanner.Entry_File =>
            return "file";
         when Backup.Scanner.Entry_Symlink =>
            return "symlink";
      end case;
   end Kind_Name;

   function Ignored_Kind_Name
     (Kind : Backup.Scanner.Ignored_Kind)
      return String
   is
   begin
      case Kind is
         when Backup.Scanner.Ignored_File =>
            return "file";
         when Backup.Scanner.Ignored_Directory =>
            return "directory";
         when Backup.Scanner.Ignored_Symlink =>
            return "symlink";
      end case;
   end Ignored_Kind_Name;

   function Symlink_Action_Name
     (Action : Backup.Scanner.Symlink_Action)
      return String
   is
   begin
      case Action is
         when Backup.Scanner.Symlink_Skipped =>
            return "skipped";
         when Backup.Scanner.Symlink_Stored =>
            return "stored";
         when Backup.Scanner.Symlink_Followed =>
            return "followed";
         when Backup.Scanner.Symlink_Broken =>
            return "broken";
         when Backup.Scanner.Symlink_Cycle =>
            return "cycle";
         when Backup.Scanner.Symlink_Outside_Input =>
            return "outside-input";
      end case;
   end Symlink_Action_Name;

   procedure Build_Dry_Run_Report
     (Report          : Backup.Scanner.Scan_Report;
      Include_Manifest : Boolean;
      Text            : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String ("backup dry run" & ASCII.LF);
      Append (Text, "output: not written" & ASCII.LF);
      Append (Text, "included entries:" & ASCII.LF);
      for Item of Report.Entries loop
         Append (Text, "  include ");
         Append (Text, Backup.Paths.To_String (Item.Archive_Path));
         Append (Text, " kind=");
         Append (Text, Kind_Name (Item.Kind));
         Append (Text, " method=");
         Append (Text, Backup.Manifest.Method_Name (Item.Compression_Method));
         if Item.Kind = Backup.Scanner.Entry_Symlink then
            Append (Text, " link-target=");
            Append (Text, To_String (Item.Link_Target));
         end if;
         Append (Text, " source=<normalized-input>");
         Append (Text, ASCII.LF);
      end loop;

      if Include_Manifest then
         Append (Text, "  include ");
         Append (Text, Backup.Manifest.Manifest_Path);
         Append (Text, " method=stored source=<generated-manifest>");
         Append (Text, ASCII.LF);
      end if;

      Append (Text, "ignored entries:" & ASCII.LF);
      for Ignored of Report.Ignored_Diagnostics loop
         Append (Text, "  ignore ");
         Append (Text, To_String (Ignored.Archive_Path));
         Append (Text, " kind=");
         Append (Text, Ignored_Kind_Name (Ignored.Kind));
         Append (Text, " rule-line=");
         Append (Text, Positive'Image (Ignored.Matching_Line_Number));
         Append (Text, " text=");
         Append (Text, To_String (Ignored.Matching_Original_Text));
         if Ignored.Pruned_Descendants then
            Append (Text, " pruned-descendants=yes");
         end if;
         Append (Text, ASCII.LF);
      end loop;

      Append (Text, "symlink entries:" & ASCII.LF);
      for Link of Report.Symlink_Diagnostics loop
         Append (Text, "  symlink ");
         Append (Text, To_String (Link.Archive_Path));
         Append (Text, " action=");
         Append (Text, Symlink_Action_Name (Link.Action));
         Append (Text, " target=");
         Append (Text, To_String (Link.Target_Text));
         Append (Text, ASCII.LF);
      end loop;
   end Build_Dry_Run_Report;


   function Decimal (Value : Interfaces.Unsigned_64) return String is
      Image : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Decimal_32 (Value : Interfaces.Unsigned_32) return String is
   begin
      return Decimal (Interfaces.Unsigned_64 (Value));
   end Decimal_32;

   procedure Append_Escape
     (Result : in out Unbounded_String;
      Code   : Character)
   is
   begin
      Append (Result, '\');
      Append (Result, Code);
   end Append_Escape;

   function Json_Escape (Text : String) return String is
      Result : Unbounded_String;
      Hex    : constant array (Natural range 0 .. 15) of Character :=
        "0123456789abcdef";
      Code   : Natural;
   begin
      for Ch of Text loop
         case Ch is
            when '"' =>
               Append_Escape (Result, '"');
            when '\' =>
               Append_Escape (Result, '\');
            when ASCII.BS =>
               Append_Escape (Result, 'b');
            when ASCII.HT =>
               Append_Escape (Result, 't');
            when ASCII.LF =>
               Append_Escape (Result, 'n');
            when ASCII.FF =>
               Append_Escape (Result, 'f');
            when ASCII.CR =>
               Append_Escape (Result, 'r');
            when others =>
               Code := Character'Pos (Ch);
               if Code < 32 then
                  Append (Result, "\u00");
                  Append (Result, Hex (Code / 16));
                  Append (Result, Hex (Code mod 16));
               else
                  Append (Result, Ch);
               end if;
         end case;
      end loop;
      return To_String (Result);
   end Json_Escape;

   function Q (Text : String) return String is
   begin
      return '"' & Json_Escape (Text) & '"';
   end Q;

   function Known_Compressed_Size
     (Method            : Backup.Zip.Compression_Method;
      Path              : Backup.Paths.File_System_Path;
      Uncompressed_Size : Interfaces.Unsigned_64)
      return String
   is
      Size : Interfaces.Unsigned_64 := 0;
   begin
      if Backup.Metadata.Estimate_Compressed_Size_For_Direct_Metadata
        (Method, Path, Uncompressed_Size, Size)
      then
         return Decimal (Size);
      else
         return "null";
      end if;
   end Known_Compressed_Size;

   function Check_Size_Limits
     (Config     : Backup.CLI.Configuration;
      Entries    : Backup.Scanner.Entry_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Total : Interfaces.Unsigned_64 := 0;
   begin
      for Item of Entries loop
         if Config.Max_File_Size.Is_Set
           and then Item.Byte_Size > Config.Max_File_Size.Value
         then
            Diagnostic := To_Unbounded_String
              ("file exceeds --max-file-size: " &
               Backup.Paths.To_String (Item.Archive_Path) &
               " size=" & Decimal (Item.Byte_Size) &
               " limit=" & Decimal (Config.Max_File_Size.Value));
            return False;
         end if;

         if Total > Interfaces.Unsigned_64'Last - Item.Byte_Size then
            Diagnostic := To_Unbounded_String
              ("total candidate size overflows unsigned 64-bit accounting");
            return False;
         end if;

         Total := Total + Item.Byte_Size;
      end loop;

      if Config.Max_Total_Size.Is_Set
        and then Total > Config.Max_Total_Size.Value
      then
         Diagnostic := To_Unbounded_String
           ("total candidate size exceeds --max-total-size: total=" &
            Decimal (Total) & " limit=" &
            Decimal (Config.Max_Total_Size.Value) &
            " ignored-files-contribute=no");
         return False;
      end if;

      return True;
   end Check_Size_Limits;


   function Total_Uncompressed_Size
     (Entries : Backup.Scanner.Entry_Vectors.Vector)
      return Interfaces.Unsigned_64
   is
      Total : Interfaces.Unsigned_64 := 0;
   begin
      for Item of Entries loop
         pragma Assert
           (Total <= Interfaces.Unsigned_64'Last - Item.Byte_Size,
            "candidate total size does not overflow");
         Total := Total + Item.Byte_Size;
      end loop;

      return Total;
   end Total_Uncompressed_Size;

   procedure Build_JSON_Report
     (Config           : Backup.CLI.Configuration;
      Report           : Backup.Scanner.Scan_Report;
      Include_Manifest : Boolean;
      Manifest_Content : Unbounded_String;
      Dry_Run          : Boolean;
      Output_Path      : String;
      Text             : out Unbounded_String)
   is
      First : Boolean := True;
      pragma Unreferenced (Output_Path);
   begin
      Text := To_Unbounded_String ("{" & ASCII.LF);
      Append (Text, "  " & Q ("format") & ": " &
        Q ("backup-list-v1") & "," & ASCII.LF);
      Append (Text, "  " & Q ("dry_run") & ": ");
      if Dry_Run then
         Append (Text, "true");
      else
         Append (Text, "false");
      end if;
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("output_path") & ": " &
        Q ("<configured-output>") & "," & ASCII.LF);
      Append (Text, "  " & Q ("encryption") & ": {");
      Append (Text, Q ("enabled") & ": ");
      if Config.Encrypt then
         Append (Text, "true, " & Q ("cipher") & ": " &
           Q (Backup.Encryption.Cipher_Name (Config.Cipher)) &
           ", " & Q ("password_source") & ": ");
         case Config.Password.Kind is
            when Backup.Encryption.Password_File =>
               Append (Text, Q ("file"));
            when Backup.Encryption.Password_Env =>
               Append (Text, Q ("env"));
            when Backup.Encryption.Password_Prompt =>
               Append (Text, Q ("prompt"));
            when Backup.Encryption.Password_None =>
               Append (Text, "null");
         end case;
      else
         Append (Text, "false, " & Q ("cipher") & ": null, " &
           Q ("password_source") & ": null");
      end if;
      Append (Text, "}," & ASCII.LF);
      Append (Text, "  " & Q ("ignored_files_contribute_to_total_size") &
        ": false," & ASCII.LF);
      Append (Text, "  " & Q ("total_uncompressed_size") & ": " &
        Decimal (Total_Uncompressed_Size (Report.Entries)) & "," & ASCII.LF);
      Append (Text, "  " & Q ("limits") & ": {");
      Append (Text, Q ("max_file_size") & ": ");
      if Config.Max_File_Size.Is_Set then
         Append (Text, Decimal (Config.Max_File_Size.Value));
      else
         Append (Text, "null");
      end if;
      Append (Text, ", " & Q ("max_total_size") & ": ");
      if Config.Max_Total_Size.Is_Set then
         Append (Text, Decimal (Config.Max_Total_Size.Value));
      else
         Append (Text, "null");
      end if;
      Append (Text, "}," & ASCII.LF);
      Append (Text, "  " & Q ("included_entries") & ": [" & ASCII.LF);

      for Item of Report.Entries loop
         declare
            Crc             : Interfaces.Unsigned_32 := 0;
            Observed_Size   : Interfaces.Unsigned_64 := 0;
            Metadata_Status : Backup.Zip.Write_Result := Backup.Zip.Write_Ok;
         begin
            pragma Assert
              (Backup.Paths.To_String (Item.Archive_Path)'Length > 0,
               "JSON report entries have non-empty archive paths");
            if Item.Kind = Backup.Scanner.Entry_Symlink then
               Observed_Size := Item.Byte_Size;
               Crc := Backup.Zip.Crc32_Of_Text (Item.Link_Target);
            else
               Metadata_Status :=
                 Backup.Zip.Analyze_File
                   (Item.Source_Path, Crc, Observed_Size);
            end if;
            if First then
               First := False;
            else
               Append (Text, "," & ASCII.LF);
            end if;

            Append (Text, "    {" & Q ("archive_path") & ": " &
              Q (Backup.Paths.To_String (Item.Archive_Path)));
            Append (Text, ", " & Q ("source") & ": " &
              Q ("<normalized-input>"));
            Append
              (Text, ", " & Q ("kind") & ": " &
               Q (Kind_Name (Item.Kind)));
            Append (Text, ", " & Q ("compression_method") & ": " &
              Q (Backup.Manifest.Method_Name (Item.Compression_Method)));
            if Item.Kind = Backup.Scanner.Entry_Symlink then
               Append (Text, ", " & Q ("link_target") & ": " &
                 Q (To_String (Item.Link_Target)));
            end if;
            Append (Text, ", " & Q ("uncompressed_size") & ": " &
              Decimal (Item.Byte_Size));
            Append (Text, ", " & Q ("compressed_size") & ": ");
            if Item.Has_Prepared_Payload then
               Append (Text, Decimal (Item.Prepared_Compressed_Size));
            else
               Append
                 (Text,
                  Known_Compressed_Size
                    (Item.Compression_Method, Item.Source_Path, Item.Byte_Size));
            end if;
            Append (Text, ", " & Q ("crc32") & ": ");
            if Metadata_Status = Backup.Zip.Write_Ok
              and then Observed_Size = Item.Byte_Size
            then
               Append (Text, Decimal_32 (Crc));
            else
               Append (Text, "null");
            end if;
            Append (Text, "}");
         end;
      end loop;
      Append (Text, ASCII.LF & "  ]," & ASCII.LF);

      Append (Text, "  " & Q ("ignored_entries") & ": [" & ASCII.LF);
      First := True;
      for Ignored of Report.Ignored_Diagnostics loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;

         Append (Text, "    {" & Q ("archive_path") & ": " &
           Q (To_String (Ignored.Archive_Path)));
         Append (Text, ", " & Q ("kind") & ": " &
           Q (Ignored_Kind_Name (Ignored.Kind)));
         Append (Text, ", " & Q ("matching_ignore_file") & ": " &
           Q ("<normalized-ignore-source>"));
         Append (Text, ", " & Q ("matching_line_number") & ": " &
           Positive'Image (Ignored.Matching_Line_Number));
         Append (Text, ", " & Q ("matching_original_text") & ": " &
           Q (To_String (Ignored.Matching_Original_Text)));
         Append (Text, ", " & Q ("pruned_descendants") & ": ");
         if Ignored.Pruned_Descendants then
            Append (Text, "true");
         else
            Append (Text, "false");
         end if;
         Append (Text, ", " & Q ("descendants_unreachable") & ": ");
         if Ignored.Descendants_Unreachable then
            Append (Text, "true");
         else
            Append (Text, "false");
         end if;
         Append (Text, "}");
      end loop;
      Append (Text, ASCII.LF & "  ]," & ASCII.LF);

      Append (Text, "  " & Q ("symlink_entries") & ": [" & ASCII.LF);
      First := True;
      for Link of Report.Symlink_Diagnostics loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_path") & ": " &
           Q (To_String (Link.Archive_Path)));
         Append (Text, ", " & Q ("source") & ": " &
           Q ("<normalized-input>"));
         Append (Text, ", " & Q ("target") & ": " &
           Q (To_String (Link.Target_Text)));
         Append (Text, ", " & Q ("action") & ": " &
           Q (Symlink_Action_Name (Link.Action)));
         Append (Text, "}");
      end loop;
      Append (Text, ASCII.LF & "  ]," & ASCII.LF);

      Append (Text, "  " & Q ("manifest") & ": {");
      Append (Text, Q ("enabled") & ": ");
      if Include_Manifest then
         Append (Text, "true, " & Q ("archive_path") & ": " &
           Q (Backup.Manifest.Manifest_Path) & ", " &
           Q ("compression_method") & ": " & Q ("stored") &
           ", " & Q ("content") & ": " & Q (To_String (Manifest_Content)));
      else
         Append (Text, "false, " & Q ("archive_path") & ": null, " &
           Q ("compression_method") & ": null, " & Q ("content") &
           ": null");
      end if;
      Append (Text, "}" & ASCII.LF);
      Append (Text, "}" & ASCII.LF);
   end Build_JSON_Report;

   function Execute
     (Config     : Backup.CLI.Configuration;
      Diagnostic : out Unbounded_String)
      return Execution_Status
   is
      Report      : Backup.Scanner.Scan_Report;
      Zip_Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Scan_Status : Backup.Scanner.Scan_Status;
      Zip_Status      : Backup.Zip.Write_Result;
      Manifest_Text   : Unbounded_String;
      Manifest_Status : Backup.Manifest.Build_Result;
      Incremental_Plan : Backup.Incremental.Plan;
      Incremental_Status : Backup.Incremental.Plan_Status;
      Has_Incremental : constant Boolean :=
        Length (Config.Incremental_From_Archive) > 0
        or else Length (Config.Incremental_From_Manifest) > 0;
      Remote_Report_Emitted : Boolean := False;
      Remote_Update_Succeeded : Boolean := False;
      Prepared_Payloads_Active : Boolean := False;

      procedure Release_Prepared_Payloads is
      begin
         if Prepared_Payloads_Active then
            Cleanup_Prepared_Payloads (Report.Entries);
            Prepared_Payloads_Active := False;
         end if;
      end Release_Prepared_Payloads;
   begin
      Diagnostic := Null_Unbounded_String;

      pragma Assert
        (Config.Verify
           or else Config.List_Archive
           or else Config.Extract
           or else Config.Restore_Remote
           or else not Config.Input_Paths.Is_Empty,
         "workflow requires inputs unless operating on an existing archive");
      pragma Assert
        (To_String (Config.Output_Path)'Length > 0,
         "workflow requires a validated configuration with output path");

      if Config.Restore_Remote then
         declare
            Report : Backup.Remote.Transfer_Report;
            Transport_Status : constant Backup.Remote.Remote_Status :=
              Backup.Remote.Download_Archive
                (To_String (Config.Remote_URL), To_String (Config.Output_Path),
                 Config.Remote_Options, Report, Diagnostic);
         begin
            if Config.List_JSON then
               Backup.Remote.Build_JSON_Report (Report, Diagnostic);
            elsif Transport_Status = Backup.Remote.Remote_Ok then
               Diagnostic := To_Unbounded_String
                 ("restored remote archive to " & To_String (Config.Output_Path));
            end if;

            if Transport_Status = Backup.Remote.Remote_Ok then
               return Execution_Ok;
            else
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Remote.Status_Text (Transport_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Remote_Failed;
            end if;
         end;
      end if;

      if Config.List_Archive then
         declare
            Verify_Report : Backup.Verify.Verification_Report;
            Read_Path : Unbounded_String;
            Envelope_Status : constant Backup.Encryption.Envelope_Status :=
              Prepare_Archive_For_Read
                (To_String (Config.Output_Path), Config.Password,
                 Read_Path, Diagnostic);
            Verify_Status : Backup.Verify.Verify_Status :=
              Backup.Verify.Verify_Open_Failed;
            Zip_Password : Unbounded_String := Null_Unbounded_String;
         begin
            if Envelope_Status /= Backup.Encryption.Envelope_Ok
              and then Envelope_Status /= Backup.Encryption.Envelope_Not_Encrypted
            then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Encryption.Status_Text (Envelope_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Encryption_Failed;
            end if;

            if Config.Password.Kind /= Backup.Encryption.Password_None then
               declare
                  Password_Status : constant Backup.Encryption.Envelope_Status :=
                    Backup.Encryption.Resolve_Password
                      (Config.Password, Zip_Password, Diagnostic);
               begin
                  if Password_Status /= Backup.Encryption.Envelope_Ok then
                     if Envelope_Status = Backup.Encryption.Envelope_Ok then
                        Delete_If_Exists (To_String (Read_Path));
                     end if;
                     Release_Prepared_Payloads;
                     return Execution_Encryption_Failed;
                  end if;
               end;
            end if;

            begin
               Verify_Status := Backup.Verify.Verify_Archive
                 (To_String (Read_Path), To_String (Zip_Password),
                  Verify_Report, Diagnostic);
            exception
               when others =>
                  if Envelope_Status = Backup.Encryption.Envelope_Ok then
                     Delete_If_Exists (To_String (Read_Path));
                  end if;
                  raise;
            end;

            if Envelope_Status = Backup.Encryption.Envelope_Ok then
               Delete_If_Exists (To_String (Read_Path));
            end if;

            if Config.List_JSON then
               Backup.Verify.Build_List_JSON_Report (Verify_Report, Diagnostic);
            elsif Verify_Status = Backup.Verify.Verify_Ok then
               Backup.Verify.Build_List_Human_Report (Verify_Report, Diagnostic);
            end if;

            if Verify_Status = Backup.Verify.Verify_Ok then
               return Execution_Ok;
            else
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Verify.Status_Text (Verify_Status));
               end if;
               return Execution_Verify_Failed;
            end if;
         end;
      end if;

      if Config.Verify then
         declare
            Verify_Report : Backup.Verify.Verification_Report;
            Read_Path : Unbounded_String;
            Envelope_Status : constant Backup.Encryption.Envelope_Status :=
              Prepare_Archive_For_Read
                (To_String (Config.Output_Path), Config.Password,
                 Read_Path, Diagnostic);
            Verify_Status : Backup.Verify.Verify_Status :=
              Backup.Verify.Verify_Open_Failed;
            Zip_Password : Unbounded_String := Null_Unbounded_String;
         begin
            if Envelope_Status /= Backup.Encryption.Envelope_Ok
              and then Envelope_Status /= Backup.Encryption.Envelope_Not_Encrypted
            then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Encryption.Status_Text (Envelope_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Encryption_Failed;
            end if;

            if Config.Password.Kind /= Backup.Encryption.Password_None then
               declare
                  Password_Status : constant Backup.Encryption.Envelope_Status :=
                    Backup.Encryption.Resolve_Password
                      (Config.Password, Zip_Password, Diagnostic);
               begin
                  if Password_Status /= Backup.Encryption.Envelope_Ok then
                     if Envelope_Status = Backup.Encryption.Envelope_Ok then
                        Delete_If_Exists (To_String (Read_Path));
                     end if;
                     Release_Prepared_Payloads;
                     return Execution_Encryption_Failed;
                  end if;
               end;
            end if;

            begin
               Verify_Status := Backup.Verify.Verify_Archive
                 (To_String (Read_Path), To_String (Zip_Password),
                  Verify_Report, Diagnostic);
            exception
               when others =>
                  if Envelope_Status = Backup.Encryption.Envelope_Ok then
                     Delete_If_Exists (To_String (Read_Path));
                  end if;
                  raise;
            end;

            if Envelope_Status = Backup.Encryption.Envelope_Ok then
               Delete_If_Exists (To_String (Read_Path));
            end if;

            if Config.List_JSON then
               Backup.Verify.Build_JSON_Report (Verify_Report, Diagnostic);
            elsif Verify_Status = Backup.Verify.Verify_Ok then
               Backup.Verify.Build_Human_Report (Verify_Report, Diagnostic);
            end if;

            if Verify_Status = Backup.Verify.Verify_Ok then
               if Length (Config.Catalog_File) > 0 then
                  declare
                     Preserved_Report : constant Unbounded_String := Diagnostic;
                     Catalog : Backup.Catalog.Catalog_Data;
                     Catalog_Status : Backup.Catalog.Catalog_Status;
                  begin
                     if Backup.Encryption.Is_Encrypted
                       (To_String (Config.Output_Path))
                       and then Config.Password.Kind /=
                         Backup.Encryption.Password_None
                     then
                        Catalog_Status := Backup.Catalog.Index_Archive
                          (Catalog_Path => To_String (Config.Catalog_File),
                           Archive_Path => To_String (Config.Output_Path),
                           Password     => Config.Password,
                           Catalog      => Catalog,
                           Diagnostic   => Diagnostic);
                     else
                        Catalog_Status :=
                          Backup.Catalog.Record_Verification_Result
                            (Catalog_Path => To_String (Config.Catalog_File),
                             Archive_Path => To_String (Config.Output_Path),
                             Trusted      => True,
                             Catalog      => Catalog,
                             Diagnostic   => Diagnostic);
                     end if;
                     if Catalog_Status /= Backup.Catalog.Catalog_Ok then
                        if Length (Diagnostic) = 0 then
                           Diagnostic := To_Unbounded_String
                             (Backup.Catalog.Status_Text (Catalog_Status));
                        end if;
                        return Execution_Catalog_Failed;
                     end if;
                     Diagnostic := Preserved_Report;
                  end;
               end if;

               return Execution_Ok;
            else
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Verify.Status_Text (Verify_Status));
               end if;
               return Execution_Verify_Failed;
            end if;
         end;
      end if;

      if Config.Extract then
         declare
            Restore_Report : Backup.Restore.Restore_Report;
            Restore_Status : constant Backup.Restore.Restore_Status :=
              Backup.Restore.Extract_Archive
                (Config, Restore_Report, Diagnostic);
         begin
            if Config.List_JSON then
               Backup.Restore.Build_JSON_Report (Restore_Report, Diagnostic);
            elsif Restore_Status = Backup.Restore.Restore_Ok then
               Backup.Restore.Build_Human_Report (Restore_Report, Diagnostic);
            end if;

            if Restore_Status = Backup.Restore.Restore_Ok then
               return Execution_Ok;
            else
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Restore.Status_Text (Restore_Status));
               end if;
               return Execution_Restore_Failed;
            end if;
         end;
      end if;

      Scan_Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      if Scan_Status /= Backup.Scanner.Scan_Ok then
         return Execution_Scan_Failed;
      end if;

      Backup.Compression.Apply (Config.Compression, Report.Entries);

      if not Check_Size_Limits (Config, Report.Entries, Diagnostic) then
         return Execution_Size_Limit_Exceeded;
      end if;

      if (Config.Manifest or else Config.List_JSON)
        and then not Config.Dry_Run
      then
         if not Prepare_Compressed_Payloads
           (To_String (Config.Output_Path), Report.Entries, Diagnostic)
         then
            return Execution_Zip_Failed;
         end if;
         Prepared_Payloads_Active := True;
      end if;

      if Config.Manifest then
         Manifest_Status := Backup.Manifest.Build
           (Report.Entries, Manifest_Text);
         if Manifest_Status /= Backup.Manifest.Build_Ok then
            Diagnostic := To_Unbounded_String
              (Backup.Manifest.Build_Result_Text (Manifest_Status));
            Release_Prepared_Payloads;
            return Execution_Zip_Failed;
         end if;
      end if;

      if Has_Incremental then
         if Length (Config.Incremental_From_Archive) > 0 then
            Incremental_Status := Backup.Incremental.Build_From_Archive
              (To_String (Config.Incremental_From_Archive),
               Config.Password, Report.Entries, Incremental_Plan, Diagnostic);
         else
            Incremental_Status := Backup.Incremental.Build_From_Manifest
              (To_String (Config.Incremental_From_Manifest),
               Report.Entries, Incremental_Plan, Diagnostic);
         end if;

         if Incremental_Status /= Backup.Incremental.Plan_Ok then
            if Length (Diagnostic) = 0 then
               Diagnostic := To_Unbounded_String
                 (Backup.Incremental.Status_Text (Incremental_Status));
            end if;
            Release_Prepared_Payloads;
            return Execution_Incremental_Failed;
         end if;

         Backup.Incremental.Append_Skipped_From_Report
           (Incremental_Plan, Report);
      end if;

      if Config.Dry_Run then
         if Config.Sync_Remote then
            declare
               Inventory : Backup.Remote.Archive_Metadata_Vectors.Vector;
               Plan      : Backup.Remote.Sync_Step_Vectors.Vector;
               Transport_Status : Backup.Remote.Remote_Status;
            begin
               Transport_Status := Backup.Remote.Read_Inventory
                 (To_String (Config.Remote_URL), To_String (Config.Output_Path),
                  Config.Remote_Options, Inventory, Diagnostic);
               if Transport_Status = Backup.Remote.Remote_Ok then
                  if Ada.Directories.Exists (To_String (Config.Output_Path)) then
                     Transport_Status := Backup.Remote.Build_Sync_Plan
                       (To_String (Config.Output_Path), Inventory, Plan,
                        Diagnostic);
                  else
                     Plan.Append
                       (Backup.Remote.Sync_Step'(Action  => Backup.Remote.Sync_Upload,
                         Archive =>
                           (Archive_Id => To_Unbounded_String
                              (Backup.Remote.Archive_Id_For_Path
                                 (To_String (Config.Output_Path))),
                            Size          => 0,
                            Crc32         => 0,
                            Has_Timestamp => False,
                            Timestamp     => Ada.Calendar.Time_Of (2000, 1, 1),
                            Managed       => True,
                            Partial       => False),
                         Reason  => To_Unbounded_String
                           ("archive would be created before remote sync")));
                  end if;
               end if;

               if Transport_Status /= Backup.Remote.Remote_Ok then
                  if Length (Diagnostic) = 0 then
                     Diagnostic := To_Unbounded_String
                       (Backup.Remote.Status_Text (Transport_Status));
                  end if;
                  return Execution_Remote_Failed;
               end if;

               if Config.List_JSON then
                  Backup.Remote.Build_Sync_JSON_Report (Plan, Diagnostic);
               else
                  Backup.Remote.Build_Sync_Human_Report (Plan, Diagnostic);
               end if;
               return Execution_Ok;
            end;
         elsif Has_Incremental then
            if Config.List_JSON then
               Backup.Incremental.Build_JSON_Report
                 (Incremental_Plan, Diagnostic);
            else
               Backup.Incremental.Build_Dry_Run_Report
                 (Incremental_Plan, Diagnostic);
            end if;
         elsif Config.List_JSON then
            Build_JSON_Report
              (Config, Report, Config.Manifest, Manifest_Text, True,
               To_String (Config.Output_Path), Diagnostic);
         else
            Build_Dry_Run_Report (Report, Config.Manifest, Diagnostic);
         end if;
         return Execution_Ok;
      end if;

      Convert_To_Zip_Entries (Report.Entries, Zip_Entries);
      if Config.Manifest then
         Append_Manifest_Entry (Zip_Entries, Manifest_Text);
      end if;

      if Config.Encrypt then
         declare
            Plain_Path : constant String :=
              Unique_Temp_Path
                (To_String (Config.Output_Path), ".phase19-plain.zip");
            Encrypted_Path : constant String :=
              Unique_Temp_Path
                (To_String (Config.Output_Path), ".phase19-encrypted.tmp");
            Envelope_Status : Backup.Encryption.Envelope_Status;
         begin
            Zip_Status := Backup.Zip.Create_Archive (Plain_Path, Zip_Entries);
            if Zip_Status /= Backup.Zip.Write_Ok then
               Release_Prepared_Payloads;
               Delete_If_Exists (Plain_Path);
               Diagnostic := To_Unbounded_String (Zip_Result_Text (Zip_Status));
               return Execution_Zip_Failed;
            end if;

            Envelope_Status := Backup.Encryption.Encrypt_File
              (Plain_Path, Encrypted_Path,
               Config.Password, Config.Cipher, Diagnostic);
            Delete_If_Exists (Plain_Path);
            if Envelope_Status /= Backup.Encryption.Envelope_Ok then
               Delete_If_Exists (Encrypted_Path);
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Encryption.Status_Text (Envelope_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Encryption_Failed;
            end if;

            if not Move_Temp_To_Final
              (Encrypted_Path, To_String (Config.Output_Path), Diagnostic)
            then
               Release_Prepared_Payloads;
               return Execution_Encryption_Failed;
            end if;
         end;
      else
         Zip_Status := Backup.Zip.Create_Archive
           (To_String (Config.Output_Path), Zip_Entries);
         if Zip_Status /= Backup.Zip.Write_Ok then
            Release_Prepared_Payloads;
            Diagnostic := To_Unbounded_String (Zip_Result_Text (Zip_Status));
            return Execution_Zip_Failed;
         end if;
      end if;

      if Config.Upload_Remote or else Config.Sync_Remote then
         declare
            Upload_Report : Backup.Remote.Transfer_Report;
            Inventory     : Backup.Remote.Archive_Metadata_Vectors.Vector;
            Plan          : Backup.Remote.Sync_Step_Vectors.Vector;
            Transport_Status : Backup.Remote.Remote_Status := Backup.Remote.Remote_Ok;
            Needs_Upload  : Boolean := Config.Upload_Remote;
         begin
            if Config.Sync_Remote then
               Transport_Status := Backup.Remote.Read_Inventory
                 (To_String (Config.Remote_URL), To_String (Config.Output_Path),
                  Config.Remote_Options, Inventory, Diagnostic);
               if Transport_Status = Backup.Remote.Remote_Ok then
                  Transport_Status := Backup.Remote.Build_Sync_Plan
                    (To_String (Config.Output_Path), Inventory, Plan,
                     Diagnostic);
               end if;

               if Transport_Status = Backup.Remote.Remote_Ok then
                  for Step of Plan loop
                     case Step.Action is
                        when Backup.Remote.Sync_Upload =>
                           Needs_Upload := True;
                        when Backup.Remote.Sync_Delete_Remote =>
                           Transport_Status := Backup.Remote.Delete_Remote_Object
                             (To_String (Config.Remote_URL),
                              To_String (Config.Output_Path),
                              To_String (Step.Archive.Archive_Id),
                              Config.Remote_Options, Diagnostic);
                           exit when Transport_Status /= Backup.Remote.Remote_Ok;
                        when Backup.Remote.Sync_Keep | Backup.Remote.Sync_Download =>
                           null;
                     end case;
                  end loop;
               end if;

               if Config.List_JSON and then Transport_Status = Backup.Remote.Remote_Ok then
                  Backup.Remote.Build_Sync_JSON_Report (Plan, Diagnostic);
                  Remote_Report_Emitted := True;
               end if;
            end if;

            if Transport_Status = Backup.Remote.Remote_Ok and then Needs_Upload then
               Transport_Status := Backup.Remote.Upload_Archive
                 (To_String (Config.Remote_URL), To_String (Config.Output_Path),
                  Config.Remote_Options, Upload_Report, Diagnostic);
               if Config.List_JSON and then not Config.Sync_Remote then
                  Backup.Remote.Build_JSON_Report (Upload_Report, Diagnostic);
                  Remote_Report_Emitted := True;
               end if;
            end if;

            if Transport_Status /= Backup.Remote.Remote_Ok then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Remote.Status_Text (Transport_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Remote_Failed;
            end if;

            Remote_Update_Succeeded := True;
         end;
      end if;

      if Length (Config.Catalog_File) > 0 then
         declare
            Preserved_Report : constant Unbounded_String := Diagnostic;
            Catalog : Backup.Catalog.Catalog_Data;
            Catalog_Status : Backup.Catalog.Catalog_Status;
            Parent_Id : Unbounded_String := Null_Unbounded_String;
            Metadata_Status : Backup.Catalog.Catalog_Status;
         begin
            if Length (Config.Incremental_From_Archive) > 0 then
               Parent_Id := To_Unbounded_String
                 (Backup.Remote.Archive_Id_For_Path
                    (To_String (Config.Incremental_From_Archive)));
            elsif Length (Config.Incremental_From_Manifest) > 0 then
               Parent_Id := To_Unbounded_String
                 ("manifest:" & To_String (Config.Incremental_From_Manifest));
            end if;

            Catalog_Status := Backup.Catalog.Index_Archive
              (To_String (Config.Catalog_File),
               To_String (Config.Output_Path),
               Config.Password,
               Catalog,
               Diagnostic);
            if Catalog_Status /= Backup.Catalog.Catalog_Ok then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Catalog.Status_Text (Catalog_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Catalog_Failed;
            end if;

            Metadata_Status := Backup.Catalog.Attach_Run_Metadata
              (Catalog_Path      => To_String (Config.Catalog_File),
               Archive_Path      => To_String (Config.Output_Path),
               Scanned_Entries   => Report.Entries,
               Parent_Archive_Id => To_String (Parent_Id),
               Retention_Group   => To_String (Config.Retention_Override),
               Remote_URL        => To_String (Config.Remote_URL),
               Remote_Verified   => Remote_Update_Succeeded,
               Catalog           => Catalog,
               Diagnostic        => Diagnostic);
            if Metadata_Status /= Backup.Catalog.Catalog_Ok then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Catalog.Status_Text (Metadata_Status));
               end if;
               Release_Prepared_Payloads;
               return Execution_Catalog_Failed;
            end if;

            if Remote_Report_Emitted then
               Diagnostic := Preserved_Report;
            end if;
         end;
      end if;

      if Config.List_JSON and then not Remote_Report_Emitted then
         if Has_Incremental then
            Backup.Incremental.Build_JSON_Report
              (Incremental_Plan, Diagnostic);
         else
            Build_JSON_Report
              (Config, Report, Config.Manifest, Manifest_Text, False,
               To_String (Config.Output_Path), Diagnostic);
         end if;
      end if;

      Release_Prepared_Payloads;
      return Execution_Ok;
   exception
      when others =>
         Release_Prepared_Payloads;
         raise;
   end Execute;
end Backup.Workflow;
