with Backup_Test_Temp;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with CryptoLib.Ciphers;
with CryptoLib.Errors;
with CryptoLib.Macs;
with GNAT.OS_Lib;
with Zlib;

with Project_Tools.Files;
with Project_Tools.Processes;

with Backup.Checksums;
with Backup.CLI;
with Backup.Manifest;
with Backup.Paths;
with Backup.Verify;
with Backup.Workflow;
with Backup.Zip;

procedure Backup_Verify_Tests is
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Backup.Verify.Verify_Status;
   use type Backup.Verify.Entry_Kind;
   use type Backup.Workflow.Execution_Status;
   use type Backup.Zip.Write_Result;
   use type Backup.Paths.Validation_Status;
   use type Zlib.Status_Code;
   use type CryptoLib.Errors.Status;

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
         "backup_verify_tests");
   end Root;

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

   function Make_Entry
     (Source_Path  : String;
      Archive_Path : String;
      Method       : Backup.Zip.Compression_Method)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
   begin
      pragma Assert (Status = Backup.Paths.Valid, "test archive path valid");
      return
        (Source_Path  => Backup.Paths.Normalize_File_System_Path (Source_Path),
         Archive_Path => Archive,
         Byte_Size    => 0,
         Method       => Method,
         Kind         => Backup.Zip.Source_File,
         Generated    => False,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Content      => Null_Unbounded_String);
   end Make_Entry;

   function Make_Symlink
     (Archive_Path : String;
      Target       : String)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
   begin
      pragma Assert (Status = Backup.Paths.Valid, "test symlink path valid");
      return
        (Source_Path  => Backup.Paths.Normalize_File_System_Path ("."),
         Archive_Path => Archive,
         Byte_Size    => Unsigned_64 (Target'Length),
         Method       => Backup.Zip.Stored,
         Kind         => Backup.Zip.Source_Symlink,
         Generated    => False,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Content      => To_Unbounded_String (Target));
   end Make_Symlink;

   function Make_Generated
     (Archive_Path : String;
      Content      : String)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
   begin
      pragma Assert (Status = Backup.Paths.Valid, "test generated path valid");
      return
        (Source_Path  => Backup.Paths.Normalize_File_System_Path ("."),
         Archive_Path => Archive,
         Byte_Size    => Unsigned_64 (Content'Length),
         Method       => Backup.Zip.Stored,
         Kind         => Backup.Zip.Source_Generated,
         Generated    => True,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Content      => To_Unbounded_String (Content));
   end Make_Generated;

   function Args
     (A01 : String := "";
      A02 : String := "";
      A03 : String := "";
      A04 : String := "";
      A05 : String := "";
      A06 : String := "")
      return Backup.CLI.String_Vectors.Vector
   is
      Result : Backup.CLI.String_Vectors.Vector;
   begin
      if A01 /= "" then Result.Append (A01); end if;
      if A02 /= "" then Result.Append (A02); end if;
      if A03 /= "" then Result.Append (A03); end if;
      if A04 /= "" then Result.Append (A04); end if;
      if A05 /= "" then Result.Append (A05); end if;
      if A06 /= "" then Result.Append (A06); end if;
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
      Check (OK, "verify fixture CLI parse: " & To_String (Diagnostic));
      return Config;
   end Parsed;

   function Decimal (Value : Unsigned_64) return String is
      Image : constant String := Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Symlink_Manifest_Text
     (Manifest_Method : String;
      Link_Target     : String)
      return String
   is
      Crc : constant Unsigned_32 :=
        Backup.Zip.Crc32_Of_Text (To_Unbounded_String ("../target"));
      Q   : constant String := """";
   begin
      return
        "{" & ASCII.LF &
        "  " & Q & "format" & Q & ": " & Q & "backup-manifest-v1" & Q & "," & ASCII.LF &
        "  " & Q & "manifest_path" & Q & ": " & Q & Backup.Manifest.Manifest_Path & Q & "," & ASCII.LF &
        "  " & Q & "manifest_method" & Q & ": " & Q & Manifest_Method & Q & "," & ASCII.LF &
        "  " & Q & "timestamp" & Q & ": {" & Q & "dos_time" & Q & ": 0, " & Q & "dos_date" & Q & ": 33}," & ASCII.LF &
        "  " & Q & "entries" & Q & ": [" & ASCII.LF &
        "    {" & Q & "source" & Q & ": " & Q & "<normalized-input>" & Q & ", " &
        Q & "archive_path" & Q & ": " & Q & "links/current" & Q & ", " &
        Q & "kind" & Q & ": " & Q & "symlink" & Q & ", " &
        Q & "compression_method" & Q & ": " & Q & "stored" & Q & ", " &
        Q & "link_target" & Q & ": " & Q & Link_Target & Q & ", " &
        Q & "crc32" & Q & ": " & Decimal (Unsigned_64 (Crc)) & ", " &
        Q & "uncompressed_size" & Q & ": 9, " &
        Q & "compressed_size" & Q & ": 9, " &
        Q & "timestamp" & Q & ": {" & Q & "dos_time" & Q & ": 0, " & Q & "dos_date" & Q & ": 33}}" & ASCII.LF &
        "  ]" & ASCII.LF &
        "}" & ASCII.LF;
   end Symlink_Manifest_Text;

   function Read_All (Path : String) return Stream_Element_Array is
      File   : Ada.Streams.Stream_IO.File_Type;
      Length : Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Length := Stream_Element_Offset (Ada.Streams.Stream_IO.Size (File));
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

   procedure Write_All
     (Path : String;
      Data : Stream_Element_Array)
   is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);
   end Write_All;

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

   procedure Put_U16_At
     (Data  : in out Stream_Element_Array;
      Pos   : Stream_Element_Offset;
      Value : Unsigned_16)
   is
   begin
      Data (Pos) := Stream_Element (Value and 16#FF#);
      Data (Pos + 1) := Stream_Element (Shift_Right (Value, 8) and 16#FF#);
   end Put_U16_At;

   procedure Put_U32_At
     (Data  : in out Stream_Element_Array;
      Pos   : Stream_Element_Offset;
      Value : Unsigned_32)
   is
   begin
      Data (Pos) := Stream_Element (Value and 16#FF#);
      Data (Pos + 1) := Stream_Element (Shift_Right (Value, 8) and 16#FF#);
      Data (Pos + 2) := Stream_Element (Shift_Right (Value, 16) and 16#FF#);
      Data (Pos + 3) := Stream_Element (Shift_Right (Value, 24) and 16#FF#);
   end Put_U32_At;


   procedure Put_U64_At
     (Data  : in out Stream_Element_Array;
      Pos   : Stream_Element_Offset;
      Value : Unsigned_64)
   is
   begin
      Data (Pos) := Stream_Element (Value and 16#FF#);
      Data (Pos + 1) := Stream_Element (Shift_Right (Value, 8) and 16#FF#);
      Data (Pos + 2) := Stream_Element (Shift_Right (Value, 16) and 16#FF#);
      Data (Pos + 3) := Stream_Element (Shift_Right (Value, 24) and 16#FF#);
      Data (Pos + 4) := Stream_Element (Shift_Right (Value, 32) and 16#FF#);
      Data (Pos + 5) := Stream_Element (Shift_Right (Value, 40) and 16#FF#);
      Data (Pos + 6) := Stream_Element (Shift_Right (Value, 48) and 16#FF#);
      Data (Pos + 7) := Stream_Element (Shift_Right (Value, 56) and 16#FF#);
   end Put_U64_At;

   function Zlib_Bytes (Text : String) return Zlib.Byte_Array is
      Result : Zlib.Byte_Array (1 .. Text'Length);
   begin
      for I in Text'Range loop
         Result (I - Text'First + 1) := Zlib.Byte (Character'Pos (Text (I)));
      end loop;
      return Result;
   end Zlib_Bytes;

   procedure Put_Name
     (Data : in out Stream_Element_Array;
      Pos  : Stream_Element_Offset;
      Name : String)
   is
   begin
      for I in Name'Range loop
         Data (Pos + Stream_Element_Offset (I - Name'First)) :=
           Stream_Element (Character'Pos (Name (I)));
      end loop;
   end Put_Name;

   procedure Put_Zlib_Bytes
     (Data  : in out Stream_Element_Array;
      Pos   : Stream_Element_Offset;
      Bytes : Zlib.Byte_Array)
   is
   begin
      for I in Bytes'Range loop
         Data (Pos + Stream_Element_Offset (I - Bytes'First)) :=
           Stream_Element (Bytes (I));
      end loop;
   end Put_Zlib_Bytes;



   function Zipcrypto_CRC32_Update
     (Crc : Unsigned_32;
      B   : Stream_Element)
      return Unsigned_32
   is
      Value : Unsigned_32 := Crc xor Unsigned_32 (B);
   begin
      for Bit in 1 .. 8 loop
         if (Value and 1) /= 0 then
            Value := Shift_Right (Value, 1) xor 16#EDB8_8320#;
         else
            Value := Shift_Right (Value, 1);
         end if;
      end loop;
      return Value;
   end Zipcrypto_CRC32_Update;

   type Zipcrypto_Keys is record
      Key_0 : Unsigned_32 := 16#1234_5678#;
      Key_1 : Unsigned_32 := 16#2345_6789#;
      Key_2 : Unsigned_32 := 16#3456_7890#;
   end record;

   procedure Zipcrypto_Update_Keys
     (Keys : in out Zipcrypto_Keys;
      B    : Stream_Element)
   is
   begin
      Keys.Key_0 := Zipcrypto_CRC32_Update (Keys.Key_0, B);
      Keys.Key_1 := Keys.Key_1 + (Keys.Key_0 and 16#0000_00FF#);
      Keys.Key_1 := Keys.Key_1 * 134775813 + 1;
      Keys.Key_2 :=
        Zipcrypto_CRC32_Update
          (Keys.Key_2, Stream_Element (Shift_Right (Keys.Key_1, 24)));
   end Zipcrypto_Update_Keys;

   function Zipcrypto_Key_Byte (Keys : Zipcrypto_Keys) return Stream_Element is
      Temp : constant Unsigned_32 := (Keys.Key_2 or 2) and 16#0000_FFFF#;
   begin
      return Stream_Element
        (Shift_Right ((Temp * (Temp xor 1)) and 16#FFFF_FFFF#, 8)
         and 16#0000_00FF#);
   end Zipcrypto_Key_Byte;

   function Zipcrypto_Initial_Keys (Password : String) return Zipcrypto_Keys is
      Keys : Zipcrypto_Keys;
   begin
      for Ch of Password loop
         Zipcrypto_Update_Keys (Keys, Stream_Element (Character'Pos (Ch)));
      end loop;
      return Keys;
   end Zipcrypto_Initial_Keys;

   procedure Put_Encrypted_Bytes
     (Data      : in out Stream_Element_Array;
      Pos       : Stream_Element_Offset;
      Plain     : Stream_Element_Array;
      Password  : String)
   is
      Keys    : Zipcrypto_Keys := Zipcrypto_Initial_Keys (Password);
      Out_Pos : Stream_Element_Offset := Pos;
      Enc     : Stream_Element;
   begin
      for B of Plain loop
         Enc := B xor Zipcrypto_Key_Byte (Keys);
         Data (Out_Pos) := Enc;
         Zipcrypto_Update_Keys (Keys, B);
         Out_Pos := Out_Pos + 1;
      end loop;
   end Put_Encrypted_Bytes;

   function String_Bytes (Text : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
   begin
      for I in Text'Range loop
         Result (Stream_Element_Offset (I - Text'First + 1)) :=
           Stream_Element (Character'Pos (Text (I)));
      end loop;
      return Result;
   end String_Bytes;

   procedure Write_Encrypted_Stored_Zip
     (Path     : String;
      Name     : String;
      Content  : String;
      Password : String)
   is
      Name_Len   : constant Unsigned_16 := Unsigned_16 (Name'Length);
      Plain      : constant Stream_Element_Array := String_Bytes (Content);
      Plain_Zlib : constant Zlib.Byte_Array := Zlib_Bytes (Content);
      Crc        : constant Unsigned_32 := Backup.Checksums.CRC32 (Plain_Zlib);
      Comp_Len   : constant Unsigned_32 := Unsigned_32 (Content'Length + 12);
      Uncomp_Len : constant Unsigned_32 := Unsigned_32 (Content'Length);
      Local      : constant Stream_Element_Offset := 1;
      Header     : constant Stream_Element_Offset :=
        Local + 30 + Stream_Element_Offset (Name_Len);
      Payload    : constant Stream_Element_Offset := Header + 12;
      Central    : constant Stream_Element_Offset :=
        Payload + Stream_Element_Offset (Content'Length);
      Eocd       : constant Stream_Element_Offset :=
        Central + 46 + Stream_Element_Offset (Name_Len);
      Data       : Stream_Element_Array (1 .. Eocd + 21) := [others => 0];
      Encryption_Header : Stream_Element_Array (1 .. 12) := [others => 0];
   begin
      Encryption_Header (12) := Stream_Element (Shift_Right (Crc, 24));

      Put_U32_At (Data, Local, 16#0403_4B50#);
      Put_U16_At (Data, Local + 4, 20);
      Put_U16_At (Data, Local + 6, 16#0801#);
      Put_U16_At (Data, Local + 8, 0);
      Put_U16_At (Data, Local + 10, 0);
      Put_U16_At (Data, Local + 12, 33);
      Put_U32_At (Data, Local + 14, Crc);
      Put_U32_At (Data, Local + 18, Comp_Len);
      Put_U32_At (Data, Local + 22, Uncomp_Len);
      Put_U16_At (Data, Local + 26, Name_Len);
      Put_Name (Data, Local + 30, Name);
      Put_Encrypted_Bytes (Data, Header, Encryption_Header & Plain, Password);

      Put_U32_At (Data, Central, 16#0201_4B50#);
      Put_U16_At (Data, Central + 4, 20);
      Put_U16_At (Data, Central + 6, 20);
      Put_U16_At (Data, Central + 8, 16#0801#);
      Put_U16_At (Data, Central + 10, 0);
      Put_U16_At (Data, Central + 12, 0);
      Put_U16_At (Data, Central + 14, 33);
      Put_U32_At (Data, Central + 16, Crc);
      Put_U32_At (Data, Central + 20, Comp_Len);
      Put_U32_At (Data, Central + 24, Uncomp_Len);
      Put_U16_At (Data, Central + 28, Name_Len);
      Put_Name (Data, Central + 46, Name);

      Put_U32_At (Data, Eocd, 16#0605_4B50#);
      Put_U16_At (Data, Eocd + 8, 1);
      Put_U16_At (Data, Eocd + 10, 1);
      Put_U32_At (Data, Eocd + 12, Unsigned_32 (46 + Name'Length));
      Put_U32_At (Data, Eocd + 16, Unsigned_32 (Central - 1));
      Write_All (Path, Data);
   end Write_Encrypted_Stored_Zip;


   procedure Put_Stream_Bytes
     (Data  : in out Stream_Element_Array;
      Pos   : Stream_Element_Offset;
      Bytes : Stream_Element_Array)
   is
   begin
      for I in Bytes'Range loop
         Data (Pos + (I - Bytes'First)) := Bytes (I);
      end loop;
   end Put_Stream_Bytes;

   procedure Write_AES_Stored_Zip
     (Path     : String;
      Name     : String;
      Content  : String;
      Password : String)
   is
      Name_Len      : constant Unsigned_16 := Unsigned_16 (Name'Length);
      Extra_Len     : constant Unsigned_16 := 11;
      Plain         : constant Stream_Element_Array := String_Bytes (Content);
      Plain_Zlib    : constant Zlib.Byte_Array := Zlib_Bytes (Content);
      Salt          : constant Stream_Element_Array (1 .. 8) :=
        [1, 2, 3, 4, 5, 6, 7, 8];
      Derived       : constant Stream_Element_Array :=
        CryptoLib.Macs.PBKDF2_HMAC_SHA1
          (String_Bytes (Password), Salt, 1000, 34);
      AES_Key       : constant Stream_Element_Array := Derived (1 .. 16);
      Auth_Key      : constant Stream_Element_Array := Derived (17 .. 32);
      Verifier      : constant Stream_Element_Array := Derived (33 .. 34);
      Ciphertext    : Stream_Element_Array (Plain'Range);
      Auth          : CryptoLib.Macs.HMAC_SHA1_Digest;
      Crc           : constant Unsigned_32 := Backup.Checksums.CRC32 (Plain_Zlib);
      Comp_Len      : constant Unsigned_32 := Unsigned_32 (Salt'Length + 2 + Content'Length + 10);
      Uncomp_Len    : constant Unsigned_32 := Unsigned_32 (Content'Length);
      Local         : constant Stream_Element_Offset := 1;
      Local_Extra   : constant Stream_Element_Offset := Local + 30 + Stream_Element_Offset (Name_Len);
      Payload       : constant Stream_Element_Offset := Local_Extra + Stream_Element_Offset (Extra_Len);
      Central       : constant Stream_Element_Offset := Payload + Stream_Element_Offset (Comp_Len);
      Central_Extra : constant Stream_Element_Offset := Central + 46 + Stream_Element_Offset (Name_Len);
      Eocd          : constant Stream_Element_Offset := Central_Extra + Stream_Element_Offset (Extra_Len);
      Data          : Stream_Element_Array (1 .. Eocd + 21) := [others => 0];
      Status        : CryptoLib.Errors.Status;
   begin
      Status := CryptoLib.Ciphers.Apply_ZIP_AES_CTR ("aes128", AES_Key, Plain, Ciphertext);
      Check (Status = CryptoLib.Errors.Ok, "AES fixture encryption succeeds");
      Auth := CryptoLib.Macs.HMAC_SHA1 (Auth_Key, Ciphertext);

      Put_U32_At (Data, Local, 16#0403_4B50#);
      Put_U16_At (Data, Local + 4, 51);
      Put_U16_At (Data, Local + 6, 16#0801#);
      Put_U16_At (Data, Local + 8, 99);
      Put_U16_At (Data, Local + 10, 0);
      Put_U16_At (Data, Local + 12, 33);
      Put_U32_At (Data, Local + 14, Crc);
      Put_U32_At (Data, Local + 18, Comp_Len);
      Put_U32_At (Data, Local + 22, Uncomp_Len);
      Put_U16_At (Data, Local + 26, Name_Len);
      Put_U16_At (Data, Local + 28, Extra_Len);
      Put_Name (Data, Local + 30, Name);
      Put_U16_At (Data, Local_Extra, 16#9901#);
      Put_U16_At (Data, Local_Extra + 2, 7);
      Put_U16_At (Data, Local_Extra + 4, 1);
      Data (Local_Extra + 6) := Stream_Element (Character'Pos ('A'));
      Data (Local_Extra + 7) := Stream_Element (Character'Pos ('E'));
      Data (Local_Extra + 8) := 1;
      Put_U16_At (Data, Local_Extra + 9, 0);
      Put_Stream_Bytes (Data, Payload, Salt);
      Put_Stream_Bytes (Data, Payload + 8, Verifier);
      Put_Stream_Bytes (Data, Payload + 10, Ciphertext);
      for I in 0 .. 9 loop
         Data (Payload + 10 + Stream_Element_Offset (Content'Length) + Stream_Element_Offset (I)) := Auth (I + 1);
      end loop;

      Put_U32_At (Data, Central, 16#0201_4B50#);
      Put_U16_At (Data, Central + 4, 51);
      Put_U16_At (Data, Central + 6, 51);
      Put_U16_At (Data, Central + 8, 16#0801#);
      Put_U16_At (Data, Central + 10, 99);
      Put_U16_At (Data, Central + 12, 0);
      Put_U16_At (Data, Central + 14, 33);
      Put_U32_At (Data, Central + 16, Crc);
      Put_U32_At (Data, Central + 20, Comp_Len);
      Put_U32_At (Data, Central + 24, Uncomp_Len);
      Put_U16_At (Data, Central + 28, Name_Len);
      Put_U16_At (Data, Central + 30, Extra_Len);
      Put_Name (Data, Central + 46, Name);
      Put_U16_At (Data, Central_Extra, 16#9901#);
      Put_U16_At (Data, Central_Extra + 2, 7);
      Put_U16_At (Data, Central_Extra + 4, 1);
      Data (Central_Extra + 6) := Stream_Element (Character'Pos ('A'));
      Data (Central_Extra + 7) := Stream_Element (Character'Pos ('E'));
      Data (Central_Extra + 8) := 1;
      Put_U16_At (Data, Central_Extra + 9, 0);

      Put_U32_At (Data, Eocd, 16#0605_4B50#);
      Put_U16_At (Data, Eocd + 8, 1);
      Put_U16_At (Data, Eocd + 10, 1);
      Put_U32_At (Data, Eocd + 12, Unsigned_32 (46 + Name'Length + Extra_Len));
      Put_U32_At (Data, Eocd + 16, Unsigned_32 (Central - 1));
      Write_All (Path, Data);
   end Write_AES_Stored_Zip;

   procedure Write_Directory_Zip
     (Path : String;
      Name : String)
   is
      Name_Len : constant Unsigned_16 := Unsigned_16 (Name'Length);
      Local    : constant Stream_Element_Offset := 1;
      Central  : constant Stream_Element_Offset :=
        Local + 30 + Stream_Element_Offset (Name_Len);
      Eocd     : constant Stream_Element_Offset :=
        Central + 46 + Stream_Element_Offset (Name_Len);
      Data     : Stream_Element_Array (1 .. Eocd + 21) := [others => 0];
   begin
      Put_U32_At (Data, Local, 16#0403_4B50#);
      Put_U16_At (Data, Local + 4, 20);
      Put_U16_At (Data, Local + 6, 16#0800#);
      Put_U16_At (Data, Local + 8, 0);
      Put_U16_At (Data, Local + 26, Name_Len);
      Put_Name (Data, Local + 30, Name);

      Put_U32_At (Data, Central, 16#0201_4B50#);
      Put_U16_At (Data, Central + 4, 20);
      Put_U16_At (Data, Central + 6, 20);
      Put_U16_At (Data, Central + 8, 16#0800#);
      Put_U16_At (Data, Central + 10, 0);
      Put_U16_At (Data, Central + 28, Name_Len);
      Put_U32_At (Data, Central + 38, 16#4000_0000#);
      Put_Name (Data, Central + 46, Name);

      Put_U32_At (Data, Eocd, 16#0605_4B50#);
      Put_U16_At (Data, Eocd + 8, 1);
      Put_U16_At (Data, Eocd + 10, 1);
      Put_U32_At (Data, Eocd + 12, Unsigned_32 (46 + Name'Length));
      Put_U32_At (Data, Eocd + 16, Unsigned_32 (Central - 1));
      Write_All (Path, Data);
   end Write_Directory_Zip;

   procedure Write_Raw_Deflate_Zip
     (Path    : String;
      Name    : String;
      Content : String;
      Mode    : Zlib.Compression_Mode)
   is
      Compress_Status : Zlib.Status_Code := Zlib.Ok;
      Plain           : constant Zlib.Byte_Array := Zlib_Bytes (Content);
      Deflated        : constant Zlib.Byte_Array :=
        Zlib.Deflate_Raw (Plain, Mode, Compress_Status);
      Name_Len        : constant Unsigned_16 := Unsigned_16 (Name'Length);
      Comp_Len        : constant Unsigned_32 := Unsigned_32 (Deflated'Length);
      Uncomp_Len      : constant Unsigned_32 := Unsigned_32 (Plain'Length);
      Local           : constant Stream_Element_Offset := 1;
      Payload         : constant Stream_Element_Offset := Local + 30 + Stream_Element_Offset (Name_Len);
      Central         : constant Stream_Element_Offset := Payload + Stream_Element_Offset (Deflated'Length);
      Eocd            : constant Stream_Element_Offset := Central + 46 + Stream_Element_Offset (Name_Len);
      Data            : Stream_Element_Array (1 .. Eocd + 21) := [others => 0];
   begin
      Check (Compress_Status = Zlib.Ok, "zlib raw deflate fixture compression succeeds");
      Put_U32_At (Data, Local, 16#0403_4B50#);
      Put_U16_At (Data, Local + 4, 20);
      Put_U16_At (Data, Local + 6, 16#0800#);
      Put_U16_At (Data, Local + 8, 8);
      Put_U32_At (Data, Local + 14, Backup.Checksums.CRC32 (Plain));
      Put_U32_At (Data, Local + 18, Comp_Len);
      Put_U32_At (Data, Local + 22, Uncomp_Len);
      Put_U16_At (Data, Local + 26, Name_Len);
      Put_Name (Data, Local + 30, Name);
      Put_Zlib_Bytes (Data, Payload, Deflated);

      Put_U32_At (Data, Central, 16#0201_4B50#);
      Put_U16_At (Data, Central + 4, 20);
      Put_U16_At (Data, Central + 6, 20);
      Put_U16_At (Data, Central + 8, 16#0800#);
      Put_U16_At (Data, Central + 10, 8);
      Put_U32_At (Data, Central + 16, Backup.Checksums.CRC32 (Plain));
      Put_U32_At (Data, Central + 20, Comp_Len);
      Put_U32_At (Data, Central + 24, Uncomp_Len);
      Put_U16_At (Data, Central + 28, Name_Len);
      Put_Name (Data, Central + 46, Name);

      Put_U32_At (Data, Eocd, 16#0605_4B50#);
      Put_U16_At (Data, Eocd + 8, 1);
      Put_U16_At (Data, Eocd + 10, 1);
      Put_U32_At (Data, Eocd + 12, Unsigned_32 (46 + Name'Length));
      Put_U32_At (Data, Eocd + 16, Unsigned_32 (Central - 1));
      Write_All (Path, Data);
   end Write_Raw_Deflate_Zip;

   function Find_Signature
     (Data      : Stream_Element_Array;
      Signature : Unsigned_32)
      return Stream_Element_Offset
   is
   begin
      for Pos in Data'First .. Data'Last - 3 loop
         if U32_At (Data, Pos) = Signature then
            return Pos;
         end if;
      end loop;
      return 0;
   end Find_Signature;


   procedure Write_Two_Part_Zip
     (Source_Zip : String;
      Final_Zip  : String)
   is
      Data    : constant Stream_Element_Array := Read_All (Source_Zip);
      Central : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0201_4B50#);
      Eocd    : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0605_4B50#);
      Base    : constant String := Final_Zip (Final_Zip'First .. Final_Zip'Last - 4);
   begin
      pragma Assert (Central > Data'First, "split fixture has local payload before central directory");
      pragma Assert (Eocd > Central, "split fixture has EOCD after central directory");
      Write_All (Base & ".z01", Data (Data'First .. Central - 1));
      declare
         Final_Data : Stream_Element_Array (1 .. Data'Last - Central + 1);
         Out_Pos    : Stream_Element_Offset := Final_Data'First;
         Eocd_Final : constant Stream_Element_Offset := Eocd - Central + 1;
      begin
         for Pos in Central .. Data'Last loop
            Final_Data (Out_Pos) := Data (Pos);
            Out_Pos := Out_Pos + 1;
         end loop;
         Put_U16_At (Final_Data, Eocd_Final + 4, 1);
         Put_U16_At (Final_Data, Eocd_Final + 6, 1);
         Put_U16_At (Final_Data, Eocd_Final + 8, U16_At (Data, Eocd + 10));
         Put_U32_At (Final_Data, Eocd_Final + 16, 0);
         Write_All (Final_Zip, Final_Data);
      end;
   end Write_Two_Part_Zip;

   procedure Write_ZIP64_Metadata_Copy
     (Source_Zip : String;
      Final_Zip  : String)
   is
      Data    : constant Stream_Element_Array := Read_All (Source_Zip);
      Local   : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0403_4B50#);
      Central : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0201_4B50#);
      Eocd    : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0605_4B50#);
      Central_Name_Len : constant Unsigned_16 := U16_At (Data, Central + 28);
      Central_Extra_Len : constant Unsigned_16 := U16_At (Data, Central + 30);
      CSize : constant Unsigned_32 := U32_At (Data, Central + 20);
      USize : constant Unsigned_32 := U32_At (Data, Central + 24);
      Local_Offset : constant Unsigned_32 := U32_At (Data, Central + 42);
      Central_Insert_Original : constant Stream_Element_Offset :=
        Central + 46 + Stream_Element_Offset (Central_Name_Len) +
        Stream_Element_Offset (Central_Extra_Len);
      Descriptor : constant Stream_Element_Offset := Central - 16;
      Has_Descriptor : constant Boolean :=
        Descriptor >= Data'First
        and then U32_At (Data, Descriptor) = 16#0807_4B50#;
      Added_Descriptor : constant Stream_Element_Offset :=
        (if Has_Descriptor then 8 else 0);
      Added_Central : constant Stream_Element_Offset := 28;
      Added : constant Stream_Element_Offset := Added_Descriptor + Added_Central;
      Central_Shifted : constant Stream_Element_Offset :=
        Central + Added_Descriptor;
      Central_Insert : constant Stream_Element_Offset :=
        Central_Insert_Original + Added_Descriptor;
      Eocd_Shifted : constant Stream_Element_Offset := Eocd + Added;
      Extended : Stream_Element_Array (1 .. Data'Length + Added);
   begin
      pragma Assert (Local > 0 and Central > Local and Eocd > Central,
                     "one-entry ZIP fixture has local, central, and EOCD records");

      for Pos in Data'First .. (if Has_Descriptor then Descriptor + 7 else Central - 1) loop
         Extended (Pos) := Data (Pos);
      end loop;

      if Has_Descriptor then
         Put_U64_At (Extended, Descriptor + 8, Unsigned_64 (CSize));
         Put_U64_At (Extended, Descriptor + 16, Unsigned_64 (USize));
      end if;

      for Pos in Central .. Central_Insert_Original - 1 loop
         Extended (Pos + Added_Descriptor) := Data (Pos);
      end loop;

      Put_U16_At (Extended, Central_Insert, 16#0001#);
      Put_U16_At (Extended, Central_Insert + 2, 24);
      Put_U64_At (Extended, Central_Insert + 4, Unsigned_64 (USize));
      Put_U64_At (Extended, Central_Insert + 12, Unsigned_64 (CSize));
      Put_U64_At
        (Extended, Central_Insert + 20, Unsigned_64 (Local_Offset));

      for Pos in Central_Insert_Original .. Data'Last loop
         Extended (Pos + Added) := Data (Pos);
      end loop;

      Put_U16_At (Extended, Central_Shifted + 4, 45);
      Put_U16_At (Extended, Central_Shifted + 6, 45);
      Put_U32_At (Extended, Central_Shifted + 20, 16#FFFF_FFFF#);
      Put_U32_At (Extended, Central_Shifted + 24, 16#FFFF_FFFF#);
      Put_U16_At
        (Extended, Central_Shifted + 30,
         Central_Extra_Len + Unsigned_16'(28));
      Put_U32_At (Extended, Central_Shifted + 42, 16#FFFF_FFFF#);

      Put_U32_At
        (Extended, Eocd_Shifted + 12,
         U32_At (Data, Eocd + 12) + Unsigned_32 (Added_Central));
      Put_U32_At
        (Extended, Eocd_Shifted + 16,
         U32_At (Data, Eocd + 16) + Unsigned_32 (Added_Descriptor));

      Write_All (Final_Zip, Extended);
   end Write_ZIP64_Metadata_Copy;

   procedure Write_Legacy_Zstd_Method_Copy
     (Source_Zip : String;
      Final_Zip  : String)
   is
      Data    : Stream_Element_Array := Read_All (Source_Zip);
      Local   : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0403_4B50#);
      Central : constant Stream_Element_Offset :=
        Find_Signature (Data, 16#0201_4B50#);
   begin
      pragma Assert (Local > 0 and Central > Local,
                     "one-entry Zstd ZIP fixture has local and central records");
      Check (U16_At (Data, Local + 8) = 93,
             "legacy zstd fixture source local method is 93");
      Check (U16_At (Data, Central + 10) = 93,
             "legacy zstd fixture source central method is 93");
      Put_U16_At (Data, Local + 8, 20);
      Put_U16_At (Data, Central + 10, 20);
      Write_All (Final_Zip, Data);
   end Write_Legacy_Zstd_Method_Copy;


   function Seven_Zip_Available return Boolean is
   begin
      return Project_Tools.Processes.Locate_Command ("7z") /= "";
   end Seven_Zip_Available;

   procedure Free_Args (Args : in out GNAT.OS_Lib.Argument_List) is
   begin
      for Arg of Args loop
         GNAT.OS_Lib.Free (Arg);
      end loop;
   end Free_Args;

   procedure Write_Seven_Zip_Method_Zip
     (Path       : String;
      Method     : String;
      Entry_Name : String;
      Content    : String)
   is
      Source_Dir : constant String := Path & ".source";
      Program    : constant String := Project_Tools.Processes.Locate_Command ("7z");
      Args       : GNAT.OS_Lib.Argument_List (1 .. 9);
      Index      : Positive := Args'First;
      Status     : Integer;

      procedure Add (Value : String) is
      begin
         Args (Index) := new String'(Value);
         Index := Index + 1;
      end Add;
   begin
      if Program = "" then
         return;
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      Ensure_Directory (Source_Dir);
      Write_Text (Source_Dir & "/" & Entry_Name, Content);
      Add ("a");
      Add ("-tzip");
      Add ("-mm=" & Method);
      Add ("-bb0");
      Add ("-bd");
      Add ("-bso0");
      Add ("-bsp0");
      Add (Path);
      Add (Entry_Name);
      Status := Project_Tools.Processes.Run_Status
        ("create external-method ZIP", Source_Dir, Program, Args, Quiet => True);
      Free_Args (Args);
      Check (Status = 0, "create " & Method & " ZIP fixture");
   exception
      when others =>
         Free_Args (Args);
         raise;
   end Write_Seven_Zip_Method_Zip;

   procedure Verify_OK
     (Path : String;
      Name : String)
   is
      Report     : Backup.Verify.Verification_Report;
      Diagnostic : Unbounded_String;
      Status     : constant Backup.Verify.Verify_Status :=
        Backup.Verify.Verify_Archive (Path, Report, Diagnostic);
   begin
      Check (Status = Backup.Verify.Verify_Ok,
             Name & " should verify: " & To_String (Diagnostic));
   end Verify_OK;

   procedure Verify_Fails
     (Path   : String;
      Expect : Backup.Verify.Verify_Status;
      Name   : String)
   is
      Report     : Backup.Verify.Verification_Report;
      Diagnostic : Unbounded_String;
      Status     : constant Backup.Verify.Verify_Status :=
        Backup.Verify.Verify_Archive (Path, Report, Diagnostic);
   begin
      Check (Status = Expect,
             Name & " status expected " & Backup.Verify.Status_Text (Expect) &
             ", got " & Backup.Verify.Status_Text (Status) &
             ": " & To_String (Diagnostic));
   end Verify_Fails;

   Base       : constant String := Root;
   Input_Dir  : constant String := Root & "/input";
   Stored_Zip : constant String := Root & "/stored.zip";
   Split_Source_Zip : constant String := Root & "/split-source.zip";
   Split_Zip : constant String := Root & "/split.zip";
   Empty_Zip  : constant String := Root & "/empty.zip";
   Def_Zip    : constant String := Root & "/deflated.zip";
   Native_BZip2_Zip : constant String := Root & "/native-bzip2.zip";
   Native_BZip2_ZIP64_Zip : constant String := Root & "/native-bzip2-zip64.zip";
   Native_Zstd_Zip : constant String := Root & "/native-zstd.zip";
   Native_Zstd_ZIP64_Zip : constant String := Root & "/native-zstd-zip64.zip";
   Legacy_Zstd_Zip : constant String := Root & "/legacy-zstd.zip";
   Legacy_Zstd_ZIP64_Zip : constant String := Root & "/legacy-zstd-zip64.zip";
   BZip2_Zip  : constant String := Root & "/bzip2.zip";
   LZMA_Zip   : constant String := Root & "/lzma.zip";
   LZMA_ZIP64_Zip : constant String := Root & "/lzma-zip64.zip";
   Link_Zip   : constant String := Root & "/links.zip";
   Manifest_Zip : constant String := Root & "/manifest.zip";
   Entries    : Backup.Zip.Source_Entry_Vectors.Vector;
   Status     : Backup.Zip.Write_Result;
   Diagnostic : Unbounded_String;
begin
   if Ada.Directories.Exists (Base) then
      Project_Tools.Files.Delete_Tree (Base);
   end if;
   Ensure_Directory (Input_Dir);
   Write_Text (Input_Dir & "/a.txt", "alpha");
   Write_Text (Input_Dir & "/b.txt", "bravo");
   Write_Text (Input_Dir & "/empty.txt", "");

   Entries.Append (Make_Entry (Input_Dir & "/a.txt", "a.txt", Backup.Zip.Stored));
   Status := Backup.Zip.Create_Archive (Stored_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "stored archive created");
   Verify_OK (Stored_Zip, "stored archive");
   Check (Backup.Zip.Create_Archive (Split_Source_Zip, Entries) = Backup.Zip.Write_Ok,
          "split archive source created");
   Write_Two_Part_Zip (Split_Source_Zip, Split_Zip);
   Verify_OK (Split_Zip, "split ZIP archive");

   Entries.Clear;
   Entries.Append (Make_Entry (Input_Dir & "/empty.txt", "empty.txt", Backup.Zip.Stored));
   Status := Backup.Zip.Create_Archive (Empty_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "empty stored archive created");
   Verify_OK (Empty_Zip, "empty stored archive");

   Entries.Clear;
   Entries.Append (Make_Entry (Input_Dir & "/a.txt", "a.txt", Backup.Zip.Deflated));
   Status := Backup.Zip.Create_Archive (Def_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "deflated archive created");
   Verify_OK (Def_Zip, "deflated archive");

   Entries.Clear;
   Entries.Append (Make_Entry (Input_Dir & "/b.txt", "bzip2-native.txt", Backup.Zip.BZip2));
   Status := Backup.Zip.Create_Archive (Native_BZip2_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "native bzip2 archive created");
   Verify_OK (Native_BZip2_Zip, "native bzip2 ZIP archive");
   Write_ZIP64_Metadata_Copy (Native_BZip2_Zip, Native_BZip2_ZIP64_Zip);
   Verify_OK (Native_BZip2_ZIP64_Zip, "native bzip2 ZIP64 archive");
   Entries.Clear;
   Entries.Append (Make_Entry (Input_Dir & "/b.txt", "zstd-native.txt", Backup.Zip.Zstd));
   Status := Backup.Zip.Create_Archive (Native_Zstd_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "native zstd archive created");
   Verify_OK (Native_Zstd_Zip, "native zstd ZIP archive");
   Write_ZIP64_Metadata_Copy (Native_Zstd_Zip, Native_Zstd_ZIP64_Zip);
   Verify_OK (Native_Zstd_ZIP64_Zip, "native zstd ZIP64 archive");
   Write_Legacy_Zstd_Method_Copy (Native_Zstd_Zip, Legacy_Zstd_Zip);
   Verify_OK (Legacy_Zstd_Zip, "legacy zstd ZIP archive");
   Write_ZIP64_Metadata_Copy (Legacy_Zstd_Zip, Legacy_Zstd_ZIP64_Zip);
   Verify_OK (Legacy_Zstd_ZIP64_Zip, "legacy zstd ZIP64 archive");
   Entries.Clear;
   Entries.Append (Make_Entry (Input_Dir & "/b.txt", "lzma-native.txt", Backup.Zip.LZMA));
   Status := Backup.Zip.Create_Archive (LZMA_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "native LZMA archive created");
   Verify_OK (LZMA_Zip, "LZMA ZIP archive");
   Write_ZIP64_Metadata_Copy (LZMA_Zip, LZMA_ZIP64_Zip);
   Verify_OK (LZMA_ZIP64_Zip, "LZMA ZIP64 archive");

   if Seven_Zip_Available then
      Write_Seven_Zip_Method_Zip (BZip2_Zip, "BZip2", "bzip2.txt", "bzip2 payload" & [1 .. 4096 => 'b']);
      Verify_OK (BZip2_Zip, "bzip2 ZIP archive");
   end if;


   declare
      Directory_Zip : constant String := Root & "/directory-entry.zip";
      Report        : Backup.Verify.Verification_Report;
      Text          : Unbounded_String;
      Status        : Backup.Verify.Verify_Status;
   begin
      Write_Directory_Zip (Directory_Zip, "explicit-dir/");
      Status := Backup.Verify.Verify_Archive (Directory_Zip, Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Ok,
             "ZIP explicit directory entry verifies: " & To_String (Diagnostic));
      Check (Natural (Report.Entries.Length) = 1,
             "ZIP explicit directory entry appears in report");
      if not Report.Entries.Is_Empty then
         Check (Report.Entries.Element (1).Kind = Backup.Verify.Entry_Directory,
                "ZIP explicit directory entry has directory kind");
         Check (To_String (Report.Entries.Element (1).Archive_Path) = "explicit-dir",
                "ZIP explicit directory entry strips trailing slash");
      end if;
      Backup.Verify.Build_JSON_Report (Report, Text);
      Check (Index (Text, Character'Val (34) & "directory" & Character'Val (34)) /= 0,
             "verify JSON reports explicit directory kind");
   end;



   declare
      AES_Zip : constant String := Root & "/aes-stored.zip";
      Report  : Backup.Verify.Verification_Report;
      Status  : Backup.Verify.Verify_Status;
   begin
      Write_AES_Stored_Zip (AES_Zip, "aes.txt", "aes secret", "secret");
      Status := Backup.Verify.Verify_Archive (AES_Zip, Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Unsupported_Feature,
             "AES ZIP entry without password fails closed");
      Status := Backup.Verify.Verify_Archive (AES_Zip, "wrong", Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Crc_Mismatch,
             "AES ZIP entry rejects wrong password/authentication");
      Status := Backup.Verify.Verify_Archive (AES_Zip, "secret", Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Ok,
             "AES stored ZIP entry verifies with password: " & To_String (Diagnostic));
   end;

   declare
      Encrypted_Zip : constant String := Root & "/zipcrypto-stored.zip";
      Report        : Backup.Verify.Verification_Report;
      Status        : Backup.Verify.Verify_Status;
   begin
      Write_Encrypted_Stored_Zip
        (Encrypted_Zip, "secret.txt", "classified", "secret");
      Status := Backup.Verify.Verify_Archive (Encrypted_Zip, Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Unsupported_Feature,
             "traditional encrypted ZIP entry without password fails closed");
      Status := Backup.Verify.Verify_Archive
        (Encrypted_Zip, "wrong", Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Crc_Mismatch,
             "traditional encrypted ZIP entry rejects wrong password");
      Status := Backup.Verify.Verify_Archive
        (Encrypted_Zip, "secret", Report, Diagnostic);
      Check (Status = Backup.Verify.Verify_Ok,
             "traditional encrypted stored ZIP entry verifies with password: " &
             To_String (Diagnostic));
   end;

   Write_Raw_Deflate_Zip
     (Root & "/zlib-fixed-raw-deflate.zip", "fixed.txt",
      "fixed fixed fixed fixed fixed", Zlib.Fixed);
   Verify_OK
     (Root & "/zlib-fixed-raw-deflate.zip",
      "ZIP method 8 accepts zlib fixed-Huffman raw deflate");

   Write_Raw_Deflate_Zip
     (Root & "/zlib-dynamic-raw-deflate.zip", "dynamic.txt",
      "dynamic dynamic dynamic dynamic dynamic dynamic", Zlib.Dynamic);
   Verify_OK
     (Root & "/zlib-dynamic-raw-deflate.zip",
      "ZIP method 8 accepts zlib dynamic-Huffman raw deflate");

   declare
      No_Sig : constant String := Root & "/descriptor-no-signature.zip";
      Data   : constant Stream_Element_Array := Read_All (Def_Zip);
      Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Eocd    : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
      Descriptor : constant Stream_Element_Offset := Central - 16;
      Mutated : Stream_Element_Array (1 .. Data'Length - 4);
   begin
      for Pos in Data'First .. Descriptor - 1 loop
         Mutated (Pos) := Data (Pos);
      end loop;
      for Pos in Descriptor + 4 .. Data'Last loop
         Mutated (Pos - 4) := Data (Pos);
      end loop;
      Put_U32_At (Mutated, Eocd - 4 + 16, U32_At (Data, Eocd + 16) - 4);
      Write_All (No_Sig, Mutated);
      Verify_OK (No_Sig, "ZIP data descriptor without optional signature");
   end;

   Entries.Clear;
   Entries.Append (Make_Symlink ("links/current", "../target"));
   Status := Backup.Zip.Create_Archive (Link_Zip, Entries);
   Check (Status = Backup.Zip.Write_Ok, "symlink archive created");
   Verify_OK (Link_Zip, "symlink archive");

   declare
      Link_Manifest_Zip : constant String := Root & "/link-manifest.zip";
   begin
      Entries.Clear;
      Entries.Append (Make_Symlink ("links/current", "../target"));
      Entries.Append
        (Make_Generated
           (Backup.Manifest.Manifest_Path,
            Symlink_Manifest_Text ("stored", "../target")));
      Status := Backup.Zip.Create_Archive (Link_Manifest_Zip, Entries);
      Check (Status = Backup.Zip.Write_Ok, "symlink manifest archive created");
      Verify_OK (Link_Manifest_Zip, "symlink manifest archive");
   end;

   declare
      Bad_Link_Manifest_Zip : constant String := Root & "/bad-link-manifest.zip";
   begin
      Entries.Clear;
      Entries.Append (Make_Symlink ("links/current", "../target"));
      Entries.Append
        (Make_Generated
           (Backup.Manifest.Manifest_Path,
            Symlink_Manifest_Text ("stored", "../targex")));
      Status := Backup.Zip.Create_Archive (Bad_Link_Manifest_Zip, Entries);
      Check (Status = Backup.Zip.Write_Ok, "bad symlink manifest archive created");
      Verify_Fails
        (Bad_Link_Manifest_Zip,
         Backup.Verify.Verify_Manifest_Mismatch,
         "manifest symlink link_target must match stored link payload");
   end;

   declare
      Bad_Method_Manifest_Zip : constant String := Root & "/bad-method-manifest.zip";
   begin
      Entries.Clear;
      Entries.Append (Make_Symlink ("links/current", "../target"));
      Entries.Append
        (Make_Generated
           (Backup.Manifest.Manifest_Path,
            Symlink_Manifest_Text ("deflated", "../target")));
      Status := Backup.Zip.Create_Archive (Bad_Method_Manifest_Zip, Entries);
      Check (Status = Backup.Zip.Write_Ok, "bad manifest method marker archive created");
      Verify_Fails
        (Bad_Method_Manifest_Zip,
         Backup.Verify.Verify_Manifest_Mismatch,
         "manifest_method marker must be stored");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--manifest", Manifest_Zip, Input_Dir));
      Run_Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Run_Status = Backup.Workflow.Execution_Ok,
             "manifest archive workflow: " & To_String (Diagnostic));
      Verify_OK (Manifest_Zip, "manifest archive");
   end;

   declare
      Corrupt : constant String := Root & "/manifest-deflated-entry.zip";
      Data    : Stream_Element_Array := Read_All (Manifest_Zip);
      Central : Stream_Element_Offset := 0;
   begin
      for Pos in Data'First .. Data'Last - 3 loop
         if U32_At (Data, Pos) = 16#0201_4B50# then
            declare
               Name_Len   : constant Unsigned_16 := U16_At (Data, Pos + 28);
               Name_Start : constant Stream_Element_Offset := Pos + 46;
               Matched    : Boolean :=
                 Stream_Element_Offset (Backup.Manifest.Manifest_Path'Length) =
                 Stream_Element_Offset (Name_Len);
            begin
               if Matched and then
                 Name_Start + Stream_Element_Offset (Name_Len) - 1 <= Data'Last
               then
                  for Index in Backup.Manifest.Manifest_Path'Range loop
                     if Data
                       (Name_Start + Stream_Element_Offset
                          (Index - Backup.Manifest.Manifest_Path'First)) /=
                       Stream_Element
                         (Character'Pos (Backup.Manifest.Manifest_Path (Index)))
                     then
                        Matched := False;
                        exit;
                     end if;
                  end loop;
                  if Matched then
                     Central := Pos;
                     exit;
                  end if;
               end if;
            end;
         end if;
      end loop;

      if Central = 0 then
         Check (False, "manifest method fixture found manifest central record");
      else
         declare
            Local : constant Stream_Element_Offset :=
              Data'First + Stream_Element_Offset (U32_At (Data, Central + 42));
         begin
            Put_U16_At (Data, Local + 8, 8);
            Put_U16_At (Data, Central + 10, 8);
         end;
         Write_All (Corrupt, Data);
         Verify_Fails (Corrupt, Backup.Verify.Verify_Manifest_Mismatch,
                       "manifest entry must be stored");
      end if;
   end;

   declare
      Corrupt : constant String := Root & "/symlink-deflated-entry.zip";
      Data    : Stream_Element_Array := Read_All (Link_Zip);
      Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
   begin
      Put_U16_At (Data, Central + 10, 8);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Metadata_Mismatch,
                    "symlink entry must be stored");
   end;

   declare
      Corrupt : constant String := Root & "/crc-corrupt.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
      Name_Len : constant Unsigned_16 := U16_At (Data, Local + 26);
      Extra_Len : constant Unsigned_16 := U16_At (Data, Local + 28);
      Payload : constant Stream_Element_Offset :=
        Local + 30 + Stream_Element_Offset (Name_Len) +
        Stream_Element_Offset (Extra_Len);
   begin
      Data (Payload) := Data (Payload) xor Stream_Element (16#01#);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Crc_Mismatch,
                    "CRC mismatch detection");
   end;

   declare
      Corrupt : constant String := Root & "/duplicate.zip";
   begin
      Entries.Clear;
      Entries.Append
        (Make_Entry (Input_Dir & "/a.txt", "a.txt", Backup.Zip.Stored));
      Entries.Append
        (Make_Entry (Input_Dir & "/b.txt", "b.txt", Backup.Zip.Stored));
      Status := Backup.Zip.Create_Archive (Corrupt, Entries);
      Check (Status = Backup.Zip.Write_Ok, "duplicate fixture archive created");
      declare
         Data          : Stream_Element_Array := Read_All (Corrupt);
         First_Central : constant Stream_Element_Offset :=
           Find_Signature (Data, 16#0201_4B50#);
         Name_Len      : constant Unsigned_16 := U16_At (Data, First_Central + 28);
         Extra_Len     : constant Unsigned_16 := U16_At (Data, First_Central + 30);
         Comment_Len   : constant Unsigned_16 := U16_At (Data, First_Central + 32);
         Second_Central : constant Stream_Element_Offset :=
           First_Central + 46 + Stream_Element_Offset (Name_Len) +
           Stream_Element_Offset (Extra_Len) +
           Stream_Element_Offset (Comment_Len);
         Second_Name    : constant Stream_Element_Offset := Second_Central + 46;
      begin
         Check (U32_At (Data, Second_Central) = 16#0201_4B50#,
                "duplicate fixture has second central record");
         Check (Character'Val (Data (Second_Name)) = 'b',
                "duplicate fixture central name starts as b.txt");
         Data (Second_Name) := Stream_Element (Character'Pos ('a'));
         Write_All (Corrupt, Data);
      end;
      Verify_Fails (Corrupt, Backup.Verify.Verify_Duplicate_Archive_Path,
                    "duplicate archive-entry detection");
   end;

   declare
      Corrupt : constant String := Root & "/unsupported.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
   begin
      Data (Local + 8) := 97;
      Data (Central + 10) := 97;
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Unsupported_Method,
                    "unsupported compression-method diagnostics");
   end;



   declare
      Report : Backup.Verify.Verification_Report;
      Status : constant Backup.Verify.Verify_Status :=
        Backup.Verify.Verify_Archive
          (Root & "/does-not-exist.zip", Report, Diagnostic);
   begin
      Check (Status = Backup.Verify.Verify_Open_Failed,
             "missing archive reports open failure");
   end;


   declare
      Corrupt : constant String := Root & "/truncated-payload.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
   begin
      Put_U32_At (Data, Local + 18, 100);
      Put_U32_At (Data, Local + 22, 100);
      Put_U32_At (Data, Central + 20, 100);
      Put_U32_At (Data, Central + 24, 100);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Truncated_Payload,
                    "truncated payload detection");
   end;

   declare
      Corrupt : constant String := Root & "/zero-length-overlap.zip";
      Data    : Stream_Element_Array := Read_All (Empty_Zip);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
   begin
      Put_U16_At (Data, Local + 26, 20);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Truncated_Payload,
                    "zero-length payload placement before central directory");
   end;

   declare
      Corrupt : constant String := Root & "/bad-central-offset.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Eocd    : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
   begin
      Put_U32_At (Data, Eocd + 16, 16#0FFF_FFFF#);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Invalid_Offset,
                    "invalid central-directory offset detection");
   end;

   declare
      Corrupt : constant String := Root & "/invalid-zip64.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Eocd    : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
   begin
      Put_U32_At (Data, Eocd + 16, 16#FFFF_FFFF#);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Invalid_Zip64,
                    "invalid ZIP64 structure detection");
   end;

   declare
      Config : Backup.CLI.Configuration;
      OK     : constant Boolean := Backup.CLI.Parse
        (Args ("--verify", "--compression=store", Stored_Zip),
         Config,
         Diagnostic);
   begin
      Check (not OK,
             "verify rejects archive-creation compression option");
      Check (Index (Diagnostic, "--compression") /= 0,
             "verify compression diagnostic names unsupported option");
   end;


   declare
      Compatible : constant String := Root & "/deflate-maximum-compression-flag.zip";
      Data       : Stream_Element_Array := Read_All (Def_Zip);
      Central    : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Local      : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
      Flags      : constant Unsigned_16 := U16_At (Data, Central + 8) or 16#0004#;
   begin
      Put_U16_At (Data, Local + 6, Flags);
      Put_U16_At (Data, Central + 8, Flags);
      Write_All (Compatible, Data);
      Verify_OK
        (Compatible,
         "deflated ZIP entries accept general-purpose compression option bit 2");
   end;

   declare
      Corrupt : constant String := Root & "/unsupported-flags.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
   begin
      Put_U16_At (Data, Local + 6, 16#0004#);
      Put_U16_At (Data, Central + 8, 16#0004#);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Unsupported_Feature,
                    "deflate-only general-purpose bit flag is rejected for stored entries");
   end;

   declare
      Corrupt : constant String := Root & "/mismatched-flags.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
   begin
      Put_U16_At (Data, Local + 6, 16#0800#);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Metadata_Mismatch,
                    "local and central general-purpose flags must match");
   end;



   declare
      Corrupt : constant String := Root & "/central-disk-start.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
   begin
      Put_U16_At (Data, Central + 34, 1);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Unsupported_Feature,
                    "central directory per-entry disk start is rejected");
   end;

   declare
      Compatible : constant String := Root & "/higher-version-needed.zip";
      Data       : Stream_Element_Array := Read_All (Stored_Zip);
      Local      : constant Stream_Element_Offset := 1;
      Central    : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
   begin
      Put_U16_At (Data, Local + 4, 63);
      Put_U16_At (Data, Central + 6, 63);
      Write_All (Compatible, Data);
      Verify_OK
        (Compatible,
         "safe ZIP entries with higher version-needed values are accepted");
   end;

   declare
      Corrupt : constant String := Root & "/noncanonical-deflate-header.zip";
      Data    : Stream_Element_Array := Read_All (Def_Zip);
      Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
      Name_Len : constant Unsigned_16 := U16_At (Data, Local + 26);
      Extra_Len : constant Unsigned_16 := U16_At (Data, Local + 28);
      Payload : constant Stream_Element_Offset :=
        Local + 30 + Stream_Element_Offset (Name_Len) +
        Stream_Element_Offset (Extra_Len);
   begin
      Data (Payload) := Stream_Element (16#06#);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Deflate_Invalid,
                    "invalid raw deflate block type is rejected");
   end;

   declare
      Zip64_Descriptor : constant String := Root & "/zip64-descriptor.zip";
      Data          : constant Stream_Element_Array := Read_All (Def_Zip);
      Local         : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
      Central       : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Eocd          : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
      Name_Len      : constant Unsigned_16 := U16_At (Data, Local + 26);
      Extra_Len     : constant Unsigned_16 := U16_At (Data, Local + 28);
      Central_Name_Len  : constant Unsigned_16 := U16_At (Data, Central + 28);
      Central_Extra_Len : constant Unsigned_16 := U16_At (Data, Central + 30);
      Payload       : constant Stream_Element_Offset :=
        Local + 30 + Stream_Element_Offset (Name_Len) +
        Stream_Element_Offset (Extra_Len);
      CSize         : constant Unsigned_32 := U32_At (Data, Central + 20);
      USize         : constant Unsigned_32 := U32_At (Data, Central + 24);
      Descriptor    : constant Stream_Element_Offset :=
        Payload + Stream_Element_Offset (CSize);
      Central_Insert : constant Stream_Element_Offset :=
        Central + 46 + Stream_Element_Offset (Central_Name_Len) +
        Stream_Element_Offset (Central_Extra_Len);
      Added         : constant Stream_Element_Offset := 28;
      Extended      : Stream_Element_Array (1 .. Data'Length + Added);
   begin
      for Pos in Data'First .. Descriptor + 7 loop
         Extended (Pos) := Data (Pos);
      end loop;
      Put_U64_At (Extended, Descriptor + 8, Unsigned_64 (CSize));
      Put_U64_At (Extended, Descriptor + 16, Unsigned_64 (USize));
      for Pos in Descriptor + 16 .. Central_Insert - 1 loop
         Extended (Pos + 8) := Data (Pos);
      end loop;
      Put_U16_At (Extended, Central_Insert + 8, 16#0001#);
      Put_U16_At (Extended, Central_Insert + 10, 16);
      Put_U64_At (Extended, Central_Insert + 12, Unsigned_64 (USize));
      Put_U64_At (Extended, Central_Insert + 20, Unsigned_64 (CSize));
      for Pos in Central_Insert .. Data'Last loop
         Extended (Pos + Added) := Data (Pos);
      end loop;
      Put_U16_At (Extended, Central + 8 + 6, 45);
      Put_U32_At (Extended, Central + 8 + 20, 16#FFFF_FFFF#);
      Put_U32_At (Extended, Central + 8 + 24, 16#FFFF_FFFF#);
      Put_U16_At (Extended, Central + 8 + 30, Central_Extra_Len + Unsigned_16'(20));
      Put_U32_At
        (Extended, Eocd + Added + 12,
         U32_At (Data, Eocd + 12) + Unsigned_32 (20));
      Put_U32_At
        (Extended, Eocd + Added + 16,
         U32_At (Data, Eocd + 16) + Unsigned_32 (8));
      Write_All (Zip64_Descriptor, Extended);
      Verify_OK
        (Zip64_Descriptor,
         "ZIP64 data descriptor size fields are accepted");

      declare
         Bad_Comp : constant String := Root & "/zip64-descriptor-bad-comp.zip";
         Mutated  : Stream_Element_Array := Extended;
      begin
         Put_U64_At (Mutated, Descriptor + 8, Unsigned_64 (CSize) + 1);
         Write_All (Bad_Comp, Mutated);
         Verify_Fails
           (Bad_Comp, Backup.Verify.Verify_Metadata_Mismatch,
            "ZIP64 data descriptor compressed size mismatch is rejected");
      end;

      declare
         Bad_Uncomp : constant String := Root & "/zip64-descriptor-bad-uncomp.zip";
         Mutated    : Stream_Element_Array := Extended;
      begin
         Put_U64_At (Mutated, Descriptor + 16, Unsigned_64 (USize) + 1);
         Write_All (Bad_Uncomp, Mutated);
         Verify_Fails
           (Bad_Uncomp, Backup.Verify.Verify_Metadata_Mismatch,
            "ZIP64 data descriptor uncompressed size mismatch is rejected");
      end;

      declare
         Truncated : constant String := Root & "/zip64-descriptor-truncated.zip";
         Mutated   : Stream_Element_Array (1 .. Extended'Length - 1);
      begin
         for Pos in Mutated'Range loop
            Mutated (Pos) := Extended (Pos);
         end loop;
         Write_All (Truncated, Mutated);
         Verify_Fails
           (Truncated, Backup.Verify.Verify_Malformed_Zip,
            "truncated ZIP64 data descriptor is rejected");
      end;
   end;

   declare
      Zip64_Offset_Only : constant String := Root & "/zip64-offset-only.zip";
      Data          : constant Stream_Element_Array := Read_All (Stored_Zip);
      Central       : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      Eocd          : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
      Name_Len      : constant Unsigned_16 := U16_At (Data, Central + 28);
      Insert_Pos    : constant Stream_Element_Offset := Central + 46 + Stream_Element_Offset (Name_Len);
      Added         : constant Stream_Element_Offset := 12;
      Extended      : Stream_Element_Array (1 .. Data'Length + Added);
   begin
      for Pos in Data'First .. Insert_Pos - 1 loop
         Extended (Pos) := Data (Pos);
      end loop;
      Put_U16_At (Extended, Insert_Pos, 16#0001#);
      Put_U16_At (Extended, Insert_Pos + 2, 8);
      Put_U64_At (Extended, Insert_Pos + 4, 0);
      for Pos in Insert_Pos .. Data'Last loop
         Extended (Pos + Added) := Data (Pos);
      end loop;
      Put_U16_At (Extended, Central + 6, 45);
      Put_U16_At
        (Extended, Central + 30, U16_At (Data, Central + 30) + 12);
      Put_U32_At (Extended, Central + 42, 16#FFFF_FFFF#);
      Put_U32_At
        (Extended, Eocd + Added + 12,
         U32_At (Data, Eocd + 12) + Unsigned_32 (Added));
      Write_All (Zip64_Offset_Only, Extended);
      Verify_OK
        (Zip64_Offset_Only,
         "ZIP64 central local-header offset extra field uses zero-based offset");
   end;

   declare
      Corrupt : constant String := Root & "/multi-disk.zip";
      Data    : Stream_Element_Array := Read_All (Stored_Zip);
      Eocd    : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
   begin
      Put_U16_At (Data, Eocd + 4, 1);
      Write_All (Corrupt, Data);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Malformed_Zip,
                    "multi-disk archive metadata is rejected");
   end;

   declare
      Commented : constant String := Root & "/comment-signature.zip";
      Data      : constant Stream_Element_Array := Read_All (Stored_Zip);
      Eocd      : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
      Extended  : Stream_Element_Array (1 .. Data'Length + 4);
   begin
      for Pos in Data'Range loop
         Extended (Pos) := Data (Pos);
      end loop;
      Extended (Data'Last + 1) := Stream_Element (Character'Pos ('P'));
      Extended (Data'Last + 2) := Stream_Element (Character'Pos ('K'));
      Extended (Data'Last + 3) := 5;
      Extended (Data'Last + 4) := 6;
      Put_U16_At (Extended, Eocd + 20, 4);
      Write_All (Commented, Extended);
      Verify_OK (Commented, "EOCD signature bytes inside ZIP comment");
   end;

   declare
      Corrupt : constant String := Root & "/backslash-path.zip";
   begin
      Entries.Clear;
      Entries.Append
        (Make_Entry (Input_Dir & "/a.txt", "dir/a.txt", Backup.Zip.Stored));
      Status := Backup.Zip.Create_Archive (Corrupt, Entries);
      Check (Status = Backup.Zip.Write_Ok, "backslash path fixture archive created");
      declare
         Data    : Stream_Element_Array := Read_All (Corrupt);
         Local   : constant Stream_Element_Offset := Find_Signature (Data, 16#0403_4B50#);
         Central : constant Stream_Element_Offset := Find_Signature (Data, 16#0201_4B50#);
      begin
         Data (Local + 33) := Stream_Element (Character'Pos ('\'));
         Data (Central + 49) := Stream_Element (Character'Pos ('\'));
         Write_All (Corrupt, Data);
      end;
      Verify_Fails (Corrupt, Backup.Verify.Verify_Invalid_Archive_Path,
                    "archive path with host separator is rejected");
   end;

   declare
      Corrupt  : constant String := Root & "/central-gap.zip";
      Data     : constant Stream_Element_Array := Read_All (Stored_Zip);
      Eocd     : constant Stream_Element_Offset := Find_Signature (Data, 16#0605_4B50#);
      Extended : Stream_Element_Array (1 .. Data'Length + 1);
   begin
      for Pos in Data'First .. Eocd - 1 loop
         Extended (Pos) := Data (Pos);
      end loop;
      Extended (Eocd) := 0;
      for Pos in Eocd .. Data'Last loop
         Extended (Pos + 1) := Data (Pos);
      end loop;
      Write_All (Corrupt, Extended);
      Verify_Fails (Corrupt, Backup.Verify.Verify_Invalid_Offset,
                    "unexpected bytes between central directory and EOCD are rejected");
   end;

   declare
      Report : Backup.Verify.Verification_Report;
      Text   : Unbounded_String;
      Target : constant String := "alpha" & Character'Val (1) & "omega";
      Needle : constant String := "\" & "u0001";
   begin
      Report.Status := Backup.Verify.Verify_Ok;
      Report.Entries.Append
        (Backup.Verify.Verified_Entry'(Archive_Path      => To_Unbounded_String ("links/control"),
          Kind              => Backup.Verify.Entry_Symlink,
          Method            => 0,
          Crc32             => 0,
          Compressed_Size   => Unsigned_64 (Target'Length),
          Uncompressed_Size => Unsigned_64 (Target'Length),
          Local_Offset      => 1,
          Dos_Time          => 0,
          Dos_Date          => 33,
          External_Attrs    => 16#A1FF_0000#,
          Has_Owner         => False,
          Owner_UID         => 0,
          Owner_GID         => 0,
          Xattr_Blob        => Null_Unbounded_String,
          Link_Target       => To_Unbounded_String (Target)));
      Backup.Verify.Build_JSON_Report (Report, Text);
      Check (Index (Text, Needle) /= 0,
             "verify JSON escapes low control characters deterministically");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--verify", "--list-json", Stored_Zip));
      Run_Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Run_Status = Backup.Workflow.Execution_Ok,
             "workflow verify succeeds: " & To_String (Diagnostic));
      Check (Index (Diagnostic, "backup-verify-v1") /= 0,
             "workflow verify JSON output is deterministic format");
      Check (Index (Diagnostic, Character'Val (34) & "metadata" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "mode" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "has_owner" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "xattr_count" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "has_acl" & Character'Val (34)) /= 0,
             "workflow verify JSON exposes metadata object");
   end;

   Project_Tools.Files.Delete_Tree (Base);

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup verify tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup verify test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Verify_Tests;
