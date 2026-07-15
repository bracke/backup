with Backup_Test_Temp;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Files;

with Backup.CLI;
with Backup.Encryption;

procedure Backup_Encryption_Tests is
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Backup.Encryption.Envelope_Status;
   use type Backup.Encryption.Password_Source_Kind;
   use type Backup.Encryption.Cipher_Kind;

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
         "backup_encryption_tests");
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

   function Read_All (Path : String) return Stream_Element_Array is
      File   : Ada.Streams.Stream_IO.File_Type;
      Length : Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Length := Stream_Element_Offset
        (Ada.Streams.Stream_IO.Size (File));
      if Length = 0 then
         Ada.Streams.Stream_IO.Close (File);
         declare
            Data : Stream_Element_Array (1 .. 0);
         begin
            return Data;
         end;
      else
         declare
            Data : Stream_Element_Array (1 .. Length);
            Last : Stream_Element_Offset;
         begin
            Ada.Streams.Stream_IO.Read (File, Data, Last);
            Ada.Streams.Stream_IO.Close (File);
            pragma Assert (Last = Data'Last, "read complete file");
            return Data;
         end;
      end if;
   end Read_All;

   function Stream_To_Text (Data : Stream_Element_Array) return String is
      Result : String (1 .. Data'Length);
      Pos    : Natural := 1;
   begin
      for Item of Data loop
         Result (Pos) := Character'Val (Item);
         Pos := Pos + 1;
      end loop;
      return Result;
   end Stream_To_Text;

   procedure Write_All
     (Path : String;
      Data : Stream_Element_Array)
   is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      if Data'Length > 0 then
         Ada.Streams.Stream_IO.Write (File, Data);
      end if;
      Ada.Streams.Stream_IO.Close (File);
   end Write_All;

   procedure Flip_Last_Byte (Path : String) is
      Data : Stream_Element_Array := Read_All (Path);
   begin
      pragma Assert (Data'Length > 0, "tamper fixture is non-empty");
      Data (Data'Last) := Data (Data'Last) xor Stream_Element (16#01#);
      Write_All (Path, Data);
   end Flip_Last_Byte;

   procedure Mutate_Header_Salt_Byte (Path : String) is
      Data    : Stream_Element_Array := Read_All (Path);
      Pattern : constant String := "salt:";
      Found   : Boolean := False;
   begin
      for Index in Data'First .. Data'Last - Stream_Element_Offset (Pattern'Length) loop
         declare
            Matches : Boolean := True;
         begin
            for Offset in Pattern'Range loop
               if Data (Index + Stream_Element_Offset (Offset - Pattern'First))
                 /= Stream_Element (Character'Pos (Pattern (Offset)))
               then
                  Matches := False;
               end if;
            end loop;

            if Matches then
               declare
                  Target : constant Stream_Element_Offset :=
                    Index + Stream_Element_Offset (Pattern'Length);
               begin
                  if Data (Target) = Stream_Element (Character'Pos ('0')) then
                     Data (Target) := Stream_Element (Character'Pos ('1'));
                  else
                     Data (Target) := Stream_Element (Character'Pos ('0'));
                  end if;
               end;
               Found := True;
               exit;
            end if;
         end;
      end loop;

      pragma Assert (Found, "encrypted envelope contains a salt field");
      Write_All (Path, Data);
   end Mutate_Header_Salt_Byte;


   procedure Insert_Unexpected_Header_Line (Path : String) is
      Data    : constant Stream_Element_Array := Read_All (Path);
      Extra   : constant String := "ignored:unexpected" & ASCII.LF;
      Found   : Boolean := False;
      Split   : Stream_Element_Offset := Data'First;
   begin
      if Data'Length >= 2 then
         for Index in Data'First .. Data'Last - 1 loop
            if Data (Index) = Stream_Element (Character'Pos (ASCII.LF))
              and then Data (Index + 1) = Stream_Element (Character'Pos (ASCII.LF))
            then
               Split := Index;
               Found := True;
               exit;
            end if;
         end loop;
      end if;

      pragma Assert (Found, "encrypted envelope contains header terminator");

      declare
         Output : Stream_Element_Array
           (1 .. Data'Length + Stream_Element_Offset (Extra'Length));
         Pos    : Stream_Element_Offset := Output'First;
      begin
         for Index in Data'First .. Split loop
            Output (Pos) := Data (Index);
            Pos := Pos + 1;
         end loop;

         for Ch of Extra loop
            Output (Pos) := Stream_Element (Character'Pos (Ch));
            Pos := Pos + 1;
         end loop;

         for Index in Split + 1 .. Data'Last loop
            Output (Pos) := Data (Index);
            Pos := Pos + 1;
         end loop;

         Write_All (Path, Output);
      end;

   end Insert_Unexpected_Header_Line;

   procedure Insert_Duplicate_Salt_Line (Path : String) is
      Data    : constant Stream_Element_Array := Read_All (Path);
      Extra   : constant String := "salt:0000000000000000" & ASCII.LF;
      Found   : Boolean := False;
      Split   : Stream_Element_Offset := Data'First;
   begin
      if Data'Length >= 2 then
         for Index in Data'First .. Data'Last - 1 loop
            if Data (Index) = Stream_Element (Character'Pos (ASCII.LF))
              and then Data (Index + 1) = Stream_Element (Character'Pos (ASCII.LF))
            then
               Split := Index;
               Found := True;
               exit;
            end if;
         end loop;
      end if;

      pragma Assert (Found, "encrypted envelope contains header terminator");

      declare
         Output : Stream_Element_Array
           (1 .. Data'Length + Stream_Element_Offset (Extra'Length));
         Pos    : Stream_Element_Offset := Output'First;
      begin
         for Index in Data'First .. Split loop
            Output (Pos) := Data (Index);
            Pos := Pos + 1;
         end loop;

         for Ch of Extra loop
            Output (Pos) := Stream_Element (Character'Pos (Ch));
            Pos := Pos + 1;
         end loop;

         for Index in Split + 1 .. Data'Last loop
            Output (Pos) := Data (Index);
            Pos := Pos + 1;
         end loop;

         Write_All (Path, Output);
      end;
   end Insert_Duplicate_Salt_Line;

   procedure Mutate_Field_First_Byte
     (Path        : String;
      Field_Name  : String;
      Replacement : Character)
   is
      Data    : Stream_Element_Array := Read_All (Path);
      Pattern : constant String := Field_Name & ":";
      Found   : Boolean := False;
   begin
      for Index in Data'First .. Data'Last - Stream_Element_Offset (Pattern'Length) loop
         declare
            Matches : Boolean := True;
         begin
            for Offset in Pattern'Range loop
               if Data (Index + Stream_Element_Offset (Offset - Pattern'First))
                 /= Stream_Element (Character'Pos (Pattern (Offset)))
               then
                  Matches := False;
               end if;
            end loop;

            if Matches then
               Data (Index + Stream_Element_Offset (Pattern'Length)) :=
                 Stream_Element (Character'Pos (Replacement));
               Found := True;
               exit;
            end if;
         end;
      end loop;

      pragma Assert (Found, "encrypted envelope contains requested field");
      Write_All (Path, Data);
   end Mutate_Field_First_Byte;

   procedure Replace_Field_Value_Same_Length
     (Path       : String;
      Field_Name : String;
      New_Value  : String)
   is
      Data    : Stream_Element_Array := Read_All (Path);
      Pattern : constant String := Field_Name & ":";
      Found   : Boolean := False;
   begin
      for Index in Data'First .. Data'Last - Stream_Element_Offset (Pattern'Length) loop
         declare
            Matches : Boolean := True;
         begin
            for Offset in Pattern'Range loop
               if Data (Index + Stream_Element_Offset (Offset - Pattern'First))
                 /= Stream_Element (Character'Pos (Pattern (Offset)))
               then
                  Matches := False;
               end if;
            end loop;

            if Matches then
               declare
                  Value_First : constant Stream_Element_Offset :=
                    Index + Stream_Element_Offset (Pattern'Length);
               begin
                  for Offset in New_Value'Range loop
                     Data
                       (Value_First + Stream_Element_Offset (Offset - New_Value'First)) :=
                       Stream_Element (Character'Pos (New_Value (Offset)));
                  end loop;
               end;
               Found := True;
               exit;
            end if;
         end;
      end loop;

      pragma Assert (Found, "encrypted envelope contains requested field");
      Write_All (Path, Data);
   end Replace_Field_Value_Same_Length;

   procedure Break_Header_Terminator (Path : String) is
      Data  : Stream_Element_Array := Read_All (Path);
      Found : Boolean := False;
   begin
      if Data'Length >= 2 then
         for Index in Data'First .. Data'Last - 1 loop
            if Data (Index) = Stream_Element (Character'Pos (ASCII.LF))
              and then Data (Index + 1) = Stream_Element (Character'Pos (ASCII.LF))
            then
               Data (Index + 1) := Stream_Element (Character'Pos ('X'));
               Found := True;
               exit;
            end if;
         end loop;
      end if;

      pragma Assert (Found, "encrypted envelope contains header terminator");
      Write_All (Path, Data);
   end Break_Header_Terminator;

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
      A10 : String := "")
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
      return Result;
   end Args;


   procedure Test_Encryption_Helper_Texts is
      Cipher     : Backup.Encryption.Cipher_Kind;
      Diagnostic : Unbounded_String;
      OK         : Boolean;
   begin
      Check
        (Backup.Encryption.Cipher_Name
           (Backup.Encryption.Cipher_AES256_GCM) = "aes256-gcm",
         "cipher helper returns canonical aes256-gcm name");

      OK := Backup.Encryption.Parse_Cipher
        ("aes256-gcm", Cipher, Diagnostic);
      Check (OK, "direct cipher parser accepts aes256-gcm");
      OK := Backup.Encryption.Parse_Cipher
        ("AES256-GCM", Cipher, Diagnostic);
      Check (not OK, "direct cipher parser rejects non-canonical spelling");
      Check
        (Index (Diagnostic, "invalid --cipher value") /= 0,
         "direct cipher parser reports invalid value diagnostic");

      Check
        (Backup.Encryption.Status_Text
           (Backup.Encryption.Envelope_Ok) = "ok",
         "envelope ok status text is stable");
      Check
        (Backup.Encryption.Status_Text
           (Backup.Encryption.Envelope_Authentication_Failed) =
         "encrypted archive authentication failed",
         "authentication failure status text is stable");
      Check
        (Backup.Encryption.Status_Text
           (Backup.Encryption.Envelope_Not_Encrypted) =
         "archive is not encrypted",
         "not-encrypted status text is stable");
   end Test_Encryption_Helper_Texts;

   procedure Test_CLI_Encryption_Options is
      Config     : Backup.CLI.Configuration;
      Diagnostic : Unbounded_String;
      OK         : Boolean;
   begin
      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-env", "BACKUP_TEST_PASSWORD",
               "out.zip", "."),
         Config, Diagnostic);
      Check (OK, "--encrypt with --password-env parses: " & To_String (Diagnostic));
      Check (Config.Encrypt, "parsed config enables encryption");
      Check
        (Config.Password.Kind = Backup.Encryption.Password_Env,
         "parsed config records password env source");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-env", "BACKUP_TEST_PASSWORD",
               "--deterministic", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "--encrypt rejects --deterministic");

      OK := Backup.CLI.Parse
        (Args ("--cipher", "aes256-gcm", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "--cipher without --encrypt is rejected");

      OK := Backup.CLI.Parse
        (Args ("--password-env", "BACKUP_TEST_PASSWORD", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK,
             "unused password source is rejected for normal archive create");

      OK := Backup.CLI.Parse
        (Args ("--verify", "--password-env", "BACKUP_TEST_PASSWORD",
               "out.zip"),
         Config, Diagnostic);
      Check (OK,
             "password source is allowed for encrypted archive verification: " &
             To_String (Diagnostic));

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file=pass.txt",
               "--cipher=aes256-gcm", "out.zip", "."),
         Config, Diagnostic);
      Check (OK,
             "equals-form password file and cipher parse: " &
             To_String (Diagnostic));
      Check (Config.Password.Kind = Backup.Encryption.Password_File,
             "equals-form password file records file source");
      Check (Config.Cipher_Set,
             "equals-form cipher records explicit cipher setting");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-env=BACKUP_TEST_PASSWORD",
               "out.zip", "."),
         Config, Diagnostic);
      Check (OK,
             "equals-form password env parses: " & To_String (Diagnostic));
      Check (Config.Password.Kind = Backup.Encryption.Password_Env,
             "equals-form password env records environment source");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-prompt", "out.zip", "."),
         Config, Diagnostic);
      Check (OK,
             "password prompt source parses: " & To_String (Diagnostic));
      Check (Config.Password.Kind = Backup.Encryption.Password_Prompt,
             "parsed config records password prompt source");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "out.zip", "."), Config, Diagnostic);
      Check (not OK, "--encrypt without password source is rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file", "", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "empty separate --password-file value is rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file=", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "empty equals-form --password-file value is rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-env", "", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "empty separate --password-env value is rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-env=", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "empty equals-form --password-env value is rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file=pass.txt",
               "--password-env=BACKUP_TEST_PASSWORD", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "duplicate password sources are rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file=pass.txt",
               "--cipher=", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "empty equals-form --cipher value is rejected");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file=pass.txt",
               "--cipher", "bogus", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "unsupported separate --cipher value is rejected");
   end Test_CLI_Encryption_Options;

   procedure Test_Envelope_Round_Trip is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "archive.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "not-a-real-zip-but-envelope-round-trip");
      Write_Text (Pass_File, "correct horse battery staple" & ASCII.LF);
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "encrypt file succeeds: " & To_String (Diagnostic));
      Check (Backup.Encryption.Is_Encrypted (Enc),
             "encrypted file has phase 19 envelope magic");
      Check
        (Ada.Strings.Fixed.Index
           (Stream_To_Text (Read_All (Enc)), "kdf:bcrypt-pbkdf") /= 0,
         "encrypted file records KDF metadata");
      Check
        (Ada.Strings.Fixed.Index
           (Stream_To_Text (Read_All (Enc)), "rounds:512") /= 0,
         "encrypted file records KDF round metadata");

      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "decrypt file succeeds: " & To_String (Diagnostic));
      Check (Read_All (Plain) = Read_All (Dec),
             "decrypted bytes match plaintext");
   end Test_Envelope_Round_Trip;

   procedure Test_Wrong_Password_Fails is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain2.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "archive2.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "decrypted2.zip");
      Good_File  : constant String := Ada.Directories.Compose (Root, "good.txt");
      Bad_File   : constant String := Ada.Directories.Compose (Root, "bad.txt");
      Good       : Backup.Encryption.Password_Source;
      Bad        : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload");
      Write_Text (Good_File, "good");
      Write_Text (Bad_File, "bad");
      Good :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Good_File));
      Bad :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Bad_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Good, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before wrong-password check");
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Bad, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Authentication_Failed,
         "wrong password fails authentication before plaintext write");
      Check (not Ada.Directories.Exists (Dec),
             "wrong-password decrypt removes stale plaintext target");
   end Test_Wrong_Password_Fails;

   procedure Test_Tamper_Detection_Fails is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain3.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "archive3.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "decrypted3.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password3.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-tamper");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before tamper check");
      Flip_Last_Byte (Enc);
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Authentication_Failed,
         "tampered ciphertext fails authentication before plaintext write");
   end Test_Tamper_Detection_Fails;

   procedure Test_Header_Tamper_Detection_Fails is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain4.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "archive4.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "decrypted4.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password4.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-header-tamper");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before header-tamper check");
      Mutate_Header_Salt_Byte (Enc);
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Authentication_Failed,
         "tampered envelope header fails authentication before plaintext write");
      Check (not Ada.Directories.Exists (Dec),
             "header-tamper decrypt removes stale plaintext target");
   end Test_Header_Tamper_Detection_Fails;


   procedure Test_Unexpected_Header_Line_Is_Rejected is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-extra-header.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "archive-extra-header.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "extra-header-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-extra-header.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-extra-header");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before extra-header check");
      Insert_Unexpected_Header_Line (Enc);
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Malformed,
         "unexpected envelope header line is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "extra-header failure removes stale plaintext target");
   end Test_Unexpected_Header_Line_Is_Rejected;


   procedure Test_Duplicate_Header_Field_Is_Rejected is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-duplicate-header.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "archive-duplicate-header.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "duplicate-header-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-duplicate-header.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-duplicate-header");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before duplicate-header check");
      Insert_Duplicate_Salt_Line (Enc);
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Malformed,
         "duplicate envelope header field is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "duplicate-header failure removes stale plaintext target");
   end Test_Duplicate_Header_Field_Is_Rejected;


   procedure Test_Magic_Prefix_Without_Envelope_Is_Not_Encrypted is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "magic-prefix.bin");
      Dec        : constant String := Ada.Directories.Compose (Root, "magic-prefix-target.zip");
      Source     : constant Backup.Encryption.Password_Source :=
        (Kind  => Backup.Encryption.Password_None,
         Value => Null_Unbounded_String);
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "BACKUP-ENC-20-but-not-an-envelope");
      Write_Text (Dec, "existing target must survive");

      Check (not Backup.Encryption.Is_Encrypted (Plain),
             "magic prefix without line delimiter is not encrypted");
      Status := Backup.Encryption.Decrypt_File (Plain, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Not_Encrypted,
         "magic prefix without envelope reports not encrypted");
      Check (Ada.Directories.Exists (Dec),
             "magic-prefix not-encrypted case preserves target");
   end Test_Magic_Prefix_Without_Envelope_Is_Not_Encrypted;

   procedure Test_Empty_Payload_Round_Trip is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "empty.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "empty.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "empty-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-empty.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "");
      Write_Text (Pass_File, "empty-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "empty plaintext encrypts: " & To_String (Diagnostic));
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "empty plaintext decrypts: " & To_String (Diagnostic));
      Check (Read_All (Dec)'Length = 0,
             "empty decrypted payload remains empty");
   end Test_Empty_Payload_Round_Trip;

   procedure Test_Not_Encrypted_Does_Not_Delete_Target is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "ordinary.zip");
      Dec        : constant String := Ada.Directories.Compose (Root, "ordinary-target.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password5.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "ordinary-not-encrypted");
      Write_Text (Dec, "existing target must survive");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Decrypt_File (Plain, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Not_Encrypted,
         "decrypt reports not-encrypted before touching target");
      Check (Ada.Directories.Exists (Dec),
             "not-encrypted decrypt preserves existing plaintext target");
      Check (Read_All (Dec)'Length > 0,
             "not-encrypted target remains readable");
   end Test_Not_Encrypted_Does_Not_Delete_Target;


   procedure Test_Password_Resolution_Errors is
      Root       : constant String := Root_Path;
      Empty_File : constant String := Ada.Directories.Compose (Root, "empty-password.txt");
      Source     : Backup.Encryption.Password_Source;
      Password   : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);

      Source :=
        (Kind  => Backup.Encryption.Password_None,
         Value => Null_Unbounded_String);
      Status := Backup.Encryption.Resolve_Password
        (Source, Password, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Missing_Password,
             "missing password source is reported");

      Write_Text (Empty_File, "");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Empty_File));
      Status := Backup.Encryption.Resolve_Password
        (Source, Password, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Missing_Password,
             "empty password file is rejected");

      Source :=
        (Kind  => Backup.Encryption.Password_Env,
         Value => To_Unbounded_String ("BACKUP_PHASE19_TEST_MISSING_ENV"));
      if Ada.Environment_Variables.Exists
        ("BACKUP_PHASE19_TEST_MISSING_ENV")
      then
         Ada.Environment_Variables.Clear
           ("BACKUP_PHASE19_TEST_MISSING_ENV");
      end if;
      Status := Backup.Encryption.Resolve_Password
        (Source, Password, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Missing_Password,
             "missing password environment variable is rejected");

      Ada.Environment_Variables.Set
        ("BACKUP_PHASE19_TEST_PRESENT_ENV", "env-password");
      Source :=
        (Kind  => Backup.Encryption.Password_Env,
         Value => To_Unbounded_String ("BACKUP_PHASE19_TEST_PRESENT_ENV"));
      Status := Backup.Encryption.Resolve_Password
        (Source, Password, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "present password environment variable resolves");
      Check (To_String (Password) = "env-password",
             "environment password value is returned exactly");
      Ada.Environment_Variables.Clear ("BACKUP_PHASE19_TEST_PRESENT_ENV");

      Ada.Environment_Variables.Set
        ("BACKUP_PHASE19_TEST_EMPTY_ENV", "");
      Source :=
        (Kind  => Backup.Encryption.Password_Env,
         Value => To_Unbounded_String ("BACKUP_PHASE19_TEST_EMPTY_ENV"));
      Status := Backup.Encryption.Resolve_Password
        (Source, Password, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Missing_Password,
             "empty password environment variable is rejected");
      Ada.Environment_Variables.Clear ("BACKUP_PHASE19_TEST_EMPTY_ENV");
   end Test_Password_Resolution_Errors;



   procedure Test_Open_Failures_Preserve_Targets is
      Root       : constant String := Root_Path;
      Missing    : constant String := Ada.Directories.Compose (Root, "missing-input.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "missing-output.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "missing-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-open-failures.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Pass_File, "open-failure-secret");
      Write_Text (Dec, "existing target must survive missing encrypted input");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      if Ada.Directories.Exists (Missing) then
         Ada.Directories.Delete_File (Missing);
      end if;
      if Ada.Directories.Exists (Enc) then
         Ada.Directories.Delete_File (Enc);
      end if;

      Status := Backup.Encryption.Encrypt_File
        (Missing, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Open_Failed,
         "encrypting missing plaintext reports open failure");
      Check
        (not Ada.Directories.Exists (Enc),
         "missing plaintext encryption does not create envelope output");

      Status := Backup.Encryption.Decrypt_File (Missing, Dec, Source, Diagnostic);
      Check
        (Status = Backup.Encryption.Envelope_Open_Failed,
         "decrypting missing encrypted file reports open failure");
      Check
        (Ada.Directories.Exists (Dec),
         "missing encrypted input does not delete existing target");
   end Test_Open_Failures_Preserve_Targets;

   procedure Test_Malformed_Header_Terminator_Is_Rejected is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-broken-header.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "broken-header.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "broken-header-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-broken-header.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-broken-header");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before broken-header check");
      Break_Header_Terminator (Enc);
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "missing envelope header terminator is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "broken-header failure removes stale plaintext target");
   end Test_Malformed_Header_Terminator_Is_Rejected;

   procedure Test_Malformed_Metadata_Is_Rejected is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-malformed-metadata.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "malformed-metadata.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "malformed-metadata-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-malformed-metadata.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-malformed-metadata");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before malformed salt check");
      Mutate_Field_First_Byte (Enc, "salt", 'z');
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "non-hex salt is rejected as malformed metadata");
      Check (not Ada.Directories.Exists (Dec),
             "malformed salt removes stale plaintext target");

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before malformed plain-size check");
      Mutate_Field_First_Byte (Enc, "plain-size", 'x');
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "non-decimal plain-size is rejected as malformed metadata");
      Check (not Ada.Directories.Exists (Dec),
             "malformed plain-size removes stale plaintext target");

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before malformed nonce check");
      Mutate_Field_First_Byte (Enc, "nonce", 'z');
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "non-hex nonce is rejected as malformed metadata");
      Check (not Ada.Directories.Exists (Dec),
             "malformed nonce removes stale plaintext target");

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before malformed tag check");
      Mutate_Field_First_Byte (Enc, "tag", 'z');
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "non-hex tag is rejected as malformed metadata");
      Check (not Ada.Directories.Exists (Dec),
             "malformed tag removes stale plaintext target");
   end Test_Malformed_Metadata_Is_Rejected;

   procedure Test_Unsupported_Cipher_Is_Rejected is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-unsupported-cipher.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "unsupported-cipher.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "unsupported-cipher-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-unsupported-cipher.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-unsupported-cipher");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before unsupported-cipher check");
      Replace_Field_Value_Same_Length (Enc, "cipher", "x-invalid!");
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Unsupported_Cipher,
             "unsupported envelope cipher is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "unsupported cipher removes stale plaintext target");
   end Test_Unsupported_Cipher_Is_Rejected;



   procedure Test_CLI_Additional_Rejection_Cases is
      Config     : Backup.CLI.Configuration;
      Diagnostic : Unbounded_String;
      OK         : Boolean;
   begin
      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file", "pass.txt",
               "--cipher", "aes256-gcm", "out.zip", "."),
         Config, Diagnostic);
      Check (OK,
             "separate-form supported --cipher value parses: " &
             To_String (Diagnostic));
      Check (Config.Cipher_Set,
             "separate-form supported --cipher records explicit cipher");

      OK := Backup.CLI.Parse
        (Args ("--encrypt", "--password-file", "pass.txt",
               "--cipher=bogus", "out.zip", "."),
         Config, Diagnostic);
      Check (not OK, "unsupported equals-form --cipher value is rejected");

      OK := Backup.CLI.Parse
        (Args ("--verify", "--encrypt", "--password-file", "pass.txt",
               "out.zip"),
         Config, Diagnostic);
      Check (not OK, "--verify rejects --encrypt combination");

      OK := Backup.CLI.Parse
        (Args ("--extract", "archive.zip", "--encrypt",
               "--password-file", "pass.txt", "--output-dir", "restore"),
         Config, Diagnostic);
      Check (not OK, "--extract rejects --encrypt combination");

      Ensure_Directory (Root_Path);
      Write_Text (Ada.Directories.Compose (Root_Path, "old.zip"), "fixture");
      OK := Backup.CLI.Parse
        (Args ("--incremental-from", Ada.Directories.Compose (Root_Path, "old.zip"),
               "--password-file", "pass.txt", "new.zip", "."),
         Config, Diagnostic);
      Check (OK,
             "password source is accepted with --incremental-from: " &
             To_String (Diagnostic));
      Check (Config.Password.Kind = Backup.Encryption.Password_File,
             "incremental password source is recorded");
   end Test_CLI_Additional_Rejection_Cases;

   procedure Test_Password_File_CRLF_Is_Trimmed is
      Root       : constant String := Root_Path;
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-crlf.txt");
      Source     : Backup.Encryption.Password_Source;
      Password   : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Pass_File, "secret-with-crlf" & ASCII.CR & ASCII.LF);
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Resolve_Password
        (Source, Password, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "CRLF password file resolves: " & To_String (Diagnostic));
      Check (To_String (Password) = "secret-with-crlf",
             "password file resolver trims CRLF line ending");
   end Test_Password_File_CRLF_Is_Trimmed;

   procedure Test_Encrypt_Without_Password_Preserves_Output is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-no-password.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "no-password-output.benc");
      Source     : constant Backup.Encryption.Password_Source :=
        (Kind  => Backup.Encryption.Password_None,
         Value => Null_Unbounded_String);
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload requiring password source");
      Write_Text (Enc, "existing encrypted target must survive");

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Missing_Password,
             "encrypt without password source is rejected");
      Check (Stream_To_Text (Read_All (Enc)) = "existing encrypted target must survive",
             "existing encrypted output content survives missing password");
      Check (not Backup.Encryption.Is_Encrypted (Enc),
             "missing-password encryption does not overwrite existing target");
   end Test_Encrypt_Without_Password_Preserves_Output;

   procedure Test_Decrypt_Without_Password_Removes_Stale_Target is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-direct-no-password.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "direct-no-password.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "direct-no-password-dec.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-direct-no-password.txt");
      Good       : Backup.Encryption.Password_Source;
      None       : constant Backup.Encryption.Password_Source :=
        (Kind  => Backup.Encryption.Password_None,
         Value => Null_Unbounded_String);
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload for direct no-password decrypt");
      Write_Text (Pass_File, "direct-secret");
      Good :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Good, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypts before direct no-password decrypt test");

      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, None, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Missing_Password,
             "direct encrypted decrypt without password is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "direct encrypted decrypt without password removes stale target");
   end Test_Decrypt_Without_Password_Removes_Stale_Target;

   procedure Test_Missing_Metadata_Field_Is_Rejected is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-missing-field.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "missing-field.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "missing-field-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-missing-field.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-missing-field");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before missing-field check");
      Mutate_Field_First_Byte (Enc, "tag", 'x');
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "missing tag metadata field is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "missing field failure removes stale plaintext target");
   end Test_Missing_Metadata_Field_Is_Rejected;

   procedure Test_Plain_Size_Metadata_Tamper_Fails_Authentication is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "plain-size-auth.zip");
      Enc        : constant String := Ada.Directories.Compose (Root, "plain-size-auth.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "plain-size-auth-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "password-plain-size-auth.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Plain, "payload-before-plain-size-auth");
      Write_Text (Pass_File, "same-password");
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypted before plain-size auth check");
      Mutate_Field_First_Byte (Enc, "plain-size", '9');
      Write_Text (Dec, "stale plaintext must be removed");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed
             or else Status = Backup.Encryption.Envelope_Authentication_Failed,
             "well-formed plain-size metadata tamper is rejected");
      Check (not Ada.Directories.Exists (Dec),
             "plain-size tamper removes stale plaintext target");
   end Test_Plain_Size_Metadata_Tamper_Fails_Authentication;

   procedure Test_Empty_Input_Is_Not_Encrypted_And_Preserves_Target is
      Root       : constant String := Root_Path;
      Empty      : constant String := Ada.Directories.Compose (Root, "empty-input.bin");
      Target     : constant String := Ada.Directories.Compose (Root, "empty-input-target.zip");
      Source     : constant Backup.Encryption.Password_Source :=
        (Kind  => Backup.Encryption.Password_None,
         Value => Null_Unbounded_String);
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Empty, "");
      Write_Text (Target, "existing target must survive empty input");

      Check (not Backup.Encryption.Is_Encrypted (Empty),
             "empty file is not reported as encrypted");
      Status := Backup.Encryption.Decrypt_File
        (Empty, Target, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Not_Encrypted,
             "empty file decrypt reports not encrypted");
      Check (Ada.Directories.Exists (Target),
             "empty not-encrypted input preserves existing target");
   end Test_Empty_Input_Is_Not_Encrypted_And_Preserves_Target;

   procedure Test_Minimal_Magic_Header_Is_Malformed_And_Cleans_Target is
      Root       : constant String := Root_Path;
      Enc        : constant String := Ada.Directories.Compose (Root, "minimal-magic-envelope.benc");
      Dec        : constant String := Ada.Directories.Compose (Root, "minimal-magic-target.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "minimal-magic-password.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;
   begin
      Ensure_Directory (Root);
      Write_Text (Enc, "BACKUP-ENC-20" & ASCII.LF);
      Write_Text (Dec, "stale plaintext must be removed");
      Write_Text (Pass_File, "minimal-magic-secret" & ASCII.LF);
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Check (Backup.Encryption.Is_Encrypted (Enc),
             "minimal magic-line file is classified as encrypted envelope");
      Status := Backup.Encryption.Decrypt_File (Enc, Dec, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Malformed,
             "minimal magic-line envelope is rejected as malformed");
      Check (not Ada.Directories.Exists (Dec),
             "minimal malformed envelope removes stale plaintext target");
   end Test_Minimal_Magic_Header_Is_Malformed_And_Cleans_Target;


   procedure Test_Output_Write_Failures_Are_Reported is
      Root       : constant String := Root_Path;
      Plain      : constant String := Ada.Directories.Compose (Root, "write-failure-plain.zip");
      Enc_Dir    : constant String := Ada.Directories.Compose (Root, "write-failure-output.benc");
      Enc_File   : constant String := Ada.Directories.Compose (Root, "write-failure-good.benc");
      Dec_Dir    : constant String := Ada.Directories.Compose (Root, "write-failure-decrypted.zip");
      Pass_File  : constant String := Ada.Directories.Compose (Root, "write-failure-password.txt");
      Source     : Backup.Encryption.Password_Source;
      Diagnostic : Unbounded_String;
      Status     : Backup.Encryption.Envelope_Status;

      procedure Remove_Path (Path : String) is
      begin
         if Ada.Directories.Exists (Path) then
            begin
               Ada.Directories.Delete_File (Path);
            exception
               when others =>
                  Ada.Directories.Delete_Tree (Path);
            end;
         end if;
      exception
         when others =>
            null;
      end Remove_Path;
   begin
      Ensure_Directory (Root);
      Remove_Path (Enc_Dir);
      Remove_Path (Enc_File);
      Remove_Path (Dec_Dir);

      Write_Text (Plain, "payload for write failure checks");
      Write_Text (Pass_File, "write-failure-secret" & ASCII.LF);
      Source :=
        (Kind  => Backup.Encryption.Password_File,
         Value => To_Unbounded_String (Pass_File));

      Ada.Directories.Create_Directory (Enc_Dir);
      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc_Dir, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Write_Failed,
             "encrypting to a directory reports write failure");
      Check (Ada.Directories.Exists (Enc_Dir),
             "failed encrypted write does not remove output directory");

      Status := Backup.Encryption.Encrypt_File
        (Plain, Enc_File, Source, Backup.Encryption.Cipher_AES256_GCM,
         Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Ok,
             "fixture encrypts before decrypt write-failure check");

      Ada.Directories.Create_Directory (Dec_Dir);
      Status := Backup.Encryption.Decrypt_File
        (Enc_File, Dec_Dir, Source, Diagnostic);
      Check (Status = Backup.Encryption.Envelope_Write_Failed,
             "decrypting to a directory reports write failure");
      Check (Ada.Directories.Exists (Dec_Dir),
             "failed decrypted write does not remove output directory");
   end Test_Output_Write_Failures_Are_Reported;

   procedure Test_Is_Encrypted_Missing_File_Is_False is
      Root    : constant String := Root_Path;
      Missing : constant String := Ada.Directories.Compose (Root, "missing-is-encrypted.benc");
   begin
      Ensure_Directory (Root);
      if Ada.Directories.Exists (Missing) then
         Ada.Directories.Delete_File (Missing);
      end if;
      Check (not Backup.Encryption.Is_Encrypted (Missing),
             "missing file is not reported as encrypted");
   end Test_Is_Encrypted_Missing_File_Is_False;

begin
   Test_Encryption_Helper_Texts;
   Test_CLI_Encryption_Options;
   Test_CLI_Additional_Rejection_Cases;
   Test_Password_File_CRLF_Is_Trimmed;
   Test_Is_Encrypted_Missing_File_Is_False;
   Test_Empty_Input_Is_Not_Encrypted_And_Preserves_Target;
   Test_Minimal_Magic_Header_Is_Malformed_And_Cleans_Target;
   Test_Password_Resolution_Errors;
   Test_Open_Failures_Preserve_Targets;
   Test_Output_Write_Failures_Are_Reported;
   Test_Encrypt_Without_Password_Preserves_Output;
   Test_Envelope_Round_Trip;
   Test_Wrong_Password_Fails;
   Test_Decrypt_Without_Password_Removes_Stale_Target;
   Test_Tamper_Detection_Fails;
   Test_Header_Tamper_Detection_Fails;
   Test_Unexpected_Header_Line_Is_Rejected;
   Test_Duplicate_Header_Field_Is_Rejected;
   Test_Malformed_Header_Terminator_Is_Rejected;
   Test_Malformed_Metadata_Is_Rejected;
   Test_Missing_Metadata_Field_Is_Rejected;
   Test_Plain_Size_Metadata_Tamper_Fails_Authentication;
   Test_Unsupported_Cipher_Is_Rejected;
   Test_Not_Encrypted_Does_Not_Delete_Target;
   Test_Magic_Prefix_Without_Envelope_Is_Not_Encrypted;
   Test_Empty_Payload_Round_Trip;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup encryption tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup encryption test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Encryption_Tests;
