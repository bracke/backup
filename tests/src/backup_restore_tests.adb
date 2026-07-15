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
with Backup.Platform;
with Backup.Restore_Syntax;
with Backup.Workflow;
with Backup.Zip;

procedure Backup_Restore_Tests is
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Ada.Directories.File_Kind;
   use type Backup.Workflow.Execution_Status;
   use type Backup.Zip.Write_Result;
   use type Backup.Paths.Validation_Status;
   use type CryptoLib.Errors.Status;

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Name);
      end if;
   end Check;

   function Root return String is
   begin
      return Ada.Directories.Compose
        ("/tmp", "backup_restore_tests");
   end Root;

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Directory;

   procedure Write_Text (Path : String; Text : String) is
   begin
      Project_Tools.Files.Write_Text_File (Path, Text);
   end Write_Text;

   function Read_Text (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Result : Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Result, Ada.Text_IO.Get_Line (File));
         if not Ada.Text_IO.End_Of_File (File) then
            Append (Result, ASCII.LF);
         end if;
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Result);
   end Read_Text;

   function Args
     (A01 : String := "";
      A02 : String := "";
      A03 : String := "";
      A04 : String := "";
      A05 : String := "";
      A06 : String := "";
      A07 : String := "";
      A08 : String := "")
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
      if A07 /= "" then Result.Append (A07); end if;
      if A08 /= "" then Result.Append (A08); end if;
      return Result;
   end Args;

   function Set_Test_Xattr (Path : String; Value : String) return Boolean is
   begin
      return Backup.Platform.Set_Xattr (Path, "user.backup_test", Value);
   end Set_Test_Xattr;

   function Test_Xattr_Value (Path : String) return String is
   begin
      return Backup.Platform.Get_Xattr (Path, "user.backup_test");
   end Test_Xattr_Value;

   function Create_Symlink (Target : String; Link_Path : String) return Boolean is
   begin
      return Backup.Platform.Create_Symlink (Target, Link_Path);
   end Create_Symlink;

   function Parsed
     (Arguments : Backup.CLI.String_Vectors.Vector)
      return Backup.CLI.Configuration
   is
      Config : Backup.CLI.Configuration;
      Diagnostic : Unbounded_String;
      OK : constant Boolean := Backup.CLI.Parse
        (Arguments, Config, Diagnostic);
   begin
      Check (OK, "restore fixture CLI parse: " & To_String (Diagnostic));
      return Config;
   end Parsed;

   function Make_File
     (Source_Path  : String;
      Archive_Path : String;
      Method       : Backup.Zip.Compression_Method)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status : constant Backup.Paths.Validation_Status :=
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
   end Make_File;

   function Make_Symlink
     (Archive_Path : String;
      Target       : String)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status : constant Backup.Paths.Validation_Status :=
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

   function Read_All (Path : String) return Ada.Streams.Stream_Element_Array is
      File : Ada.Streams.Stream_IO.File_Type;
      Length : Ada.Streams.Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Length := Ada.Streams.Stream_Element_Offset (Ada.Streams.Stream_IO.Size (File));
      declare
         Data : Ada.Streams.Stream_Element_Array (1 .. Length);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Ada.Streams.Stream_IO.Read (File, Data, Last);
         Ada.Streams.Stream_IO.Close (File);
         pragma Assert (Last = Data'Last, "read complete file");
         return Data;
      end;
   end Read_All;

   procedure Write_All
     (Path : String;
      Data : Ada.Streams.Stream_Element_Array)
   is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);
   end Write_All;

   function U16_At
     (Data : Ada.Streams.Stream_Element_Array;
      Pos  : Ada.Streams.Stream_Element_Offset)
      return Unsigned_16
   is
   begin
      return Unsigned_16 (Data (Pos))
        or Shift_Left (Unsigned_16 (Data (Pos + 1)), 8);
   end U16_At;

   function U32_At
     (Data : Ada.Streams.Stream_Element_Array;
      Pos  : Ada.Streams.Stream_Element_Offset)
      return Unsigned_32
   is
   begin
      return Unsigned_32 (Data (Pos))
        or Shift_Left (Unsigned_32 (Data (Pos + 1)), 8)
        or Shift_Left (Unsigned_32 (Data (Pos + 2)), 16)
        or Shift_Left (Unsigned_32 (Data (Pos + 3)), 24);
   end U32_At;

   function Find_Signature
     (Data : Ada.Streams.Stream_Element_Array;
      Sig  : Unsigned_32)
      return Ada.Streams.Stream_Element_Offset
   is
   begin
      for Pos in Data'First .. Data'Last - 3 loop
         if U32_At (Data, Pos) = Sig then
            return Pos;
         end if;
      end loop;
      return 0;
   end Find_Signature;

   procedure Put_U16_At
     (Data  : in out Ada.Streams.Stream_Element_Array;
      Pos   : Ada.Streams.Stream_Element_Offset;
      Value : Unsigned_16)
   is
   begin
      Data (Pos) := Ada.Streams.Stream_Element (Value and 16#00FF#);
      Data (Pos + 1) := Ada.Streams.Stream_Element (Shift_Right (Value, 8));
   end Put_U16_At;



   procedure Put_U32_At
     (Data  : in out Ada.Streams.Stream_Element_Array;
      Pos   : Ada.Streams.Stream_Element_Offset;
      Value : Unsigned_32)
   is
   begin
      Data (Pos) := Ada.Streams.Stream_Element (Value and 16#0000_00FF#);
      Data (Pos + 1) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 8) and 16#0000_00FF#);
      Data (Pos + 2) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 16) and 16#0000_00FF#);
      Data (Pos + 3) := Ada.Streams.Stream_Element (Shift_Right (Value, 24));
   end Put_U32_At;

   procedure Put_U64_At
     (Data  : in out Ada.Streams.Stream_Element_Array;
      Pos   : Ada.Streams.Stream_Element_Offset;
      Value : Unsigned_64)
   is
   begin
      Data (Pos) := Ada.Streams.Stream_Element (Value and 16#FF#);
      Data (Pos + 1) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 8) and 16#FF#);
      Data (Pos + 2) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 16) and 16#FF#);
      Data (Pos + 3) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 24) and 16#FF#);
      Data (Pos + 4) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 32) and 16#FF#);
      Data (Pos + 5) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 40) and 16#FF#);
      Data (Pos + 6) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 48) and 16#FF#);
      Data (Pos + 7) :=
        Ada.Streams.Stream_Element (Shift_Right (Value, 56) and 16#FF#);
   end Put_U64_At;



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

   procedure Write_Two_Part_Zip
     (Source_Zip : String;
      Final_Zip  : String)
   is
      Data    : constant Ada.Streams.Stream_Element_Array := Read_All (Source_Zip);
      Central : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0201_4B50#);
      Eocd    : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0605_4B50#);
      Base    : constant String := Final_Zip (Final_Zip'First .. Final_Zip'Last - 4);
   begin
      pragma Assert (Central > Data'First, "split fixture has local payload before central directory");
      pragma Assert (Eocd > Central, "split fixture has EOCD after central directory");
      Write_All (Base & ".z01", Data (Data'First .. Central - 1));
      declare
         Final_Data : Ada.Streams.Stream_Element_Array (1 .. Data'Last - Central + 1);
         Out_Pos    : Ada.Streams.Stream_Element_Offset := Final_Data'First;
         Eocd_Final : constant Ada.Streams.Stream_Element_Offset := Eocd - Central + 1;
      begin
         for Pos in Central .. Data'Last loop
            Final_Data (Out_Pos) := Data (Pos);
            Out_Pos := Out_Pos + 1;
         end loop;
         Put_U16_At (Final_Data, Eocd_Final + 4, 1);
         Put_U16_At (Final_Data, Eocd_Final + 6, 1);
         Put_U16_At (Final_Data, Eocd_Final + 8, 1);
         Put_U32_At (Final_Data, Eocd_Final + 16, 0);
         Write_All (Final_Zip, Final_Data);
      end;
   end Write_Two_Part_Zip;

   procedure Write_ZIP64_Metadata_Copy
     (Source_Zip : String;
      Final_Zip  : String)
   is
      Data    : constant Ada.Streams.Stream_Element_Array := Read_All (Source_Zip);
      Local   : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0403_4B50#);
      Central : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0201_4B50#);
      Eocd    : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0605_4B50#);
      Central_Name_Len : constant Unsigned_16 := U16_At (Data, Central + 28);
      Central_Extra_Len : constant Unsigned_16 := U16_At (Data, Central + 30);
      CSize : constant Unsigned_32 := U32_At (Data, Central + 20);
      USize : constant Unsigned_32 := U32_At (Data, Central + 24);
      Local_Offset : constant Unsigned_32 := U32_At (Data, Central + 42);
      Central_Insert_Original : constant Ada.Streams.Stream_Element_Offset :=
        Central + 46 + Ada.Streams.Stream_Element_Offset (Central_Name_Len) +
        Ada.Streams.Stream_Element_Offset (Central_Extra_Len);
      Descriptor : constant Ada.Streams.Stream_Element_Offset := Central - 16;
      Has_Descriptor : constant Boolean :=
        Descriptor >= Data'First
        and then U32_At (Data, Descriptor) = 16#0807_4B50#;
      Added_Descriptor : constant Ada.Streams.Stream_Element_Offset :=
        (if Has_Descriptor then 8 else 0);
      Added_Central : constant Ada.Streams.Stream_Element_Offset := 28;
      Added : constant Ada.Streams.Stream_Element_Offset :=
        Added_Descriptor + Added_Central;
      Central_Shifted : constant Ada.Streams.Stream_Element_Offset :=
        Central + Added_Descriptor;
      Central_Insert : constant Ada.Streams.Stream_Element_Offset :=
        Central_Insert_Original + Added_Descriptor;
      Eocd_Shifted : constant Ada.Streams.Stream_Element_Offset :=
        Eocd + Added;
      Extended : Ada.Streams.Stream_Element_Array (1 .. Data'Length + Added);
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
      Data    : Ada.Streams.Stream_Element_Array := Read_All (Source_Zip);
      Local   : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0403_4B50#);
      Central : constant Ada.Streams.Stream_Element_Offset :=
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

   procedure Put_Name
     (Data : in out Ada.Streams.Stream_Element_Array;
      Pos  : Ada.Streams.Stream_Element_Offset;
      Name : String)
   is
   begin
      for I in Name'Range loop
         Data (Pos + Ada.Streams.Stream_Element_Offset (I - Name'First)) :=
           Ada.Streams.Stream_Element (Character'Pos (Name (I)));
      end loop;
   end Put_Name;



   function Zlib_Bytes (Text : String) return Zlib.Byte_Array is
      Result : Zlib.Byte_Array (1 .. Text'Length);
   begin
      for I in Text'Range loop
         Result (I - Text'First + 1) := Zlib.Byte (Character'Pos (Text (I)));
      end loop;
      return Result;
   end Zlib_Bytes;

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
      Crc        : constant Unsigned_32 := Backup.Checksums.CRC32 (Zlib_Bytes (Content));
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
      Local    : constant Ada.Streams.Stream_Element_Offset := 1;
      Central  : constant Ada.Streams.Stream_Element_Offset :=
        Local + 30 + Ada.Streams.Stream_Element_Offset (Name_Len);
      Eocd     : constant Ada.Streams.Stream_Element_Offset :=
        Central + 46 + Ada.Streams.Stream_Element_Offset (Name_Len);
      Data     : Ada.Streams.Stream_Element_Array (1 .. Eocd + 21) :=
        [others => 0];
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

   Diagnostic : Unbounded_String;
   Source_Dir : constant String := Root & "/source";
   Restore_Dir : constant String := Root & "/restore";
   Dry_Dir : constant String := Root & "/dry";
   Stored_Zip : constant String := Root & "/stored.zip";
   Split_Source_Zip : constant String := Root & "/split-source.zip";
   Split_Zip : constant String := Root & "/split.zip";
   Select_Zip : constant String := Root & "/select.zip";
   Deflated_Zip : constant String := Root & "/deflated.zip";
   Native_BZip2_Zip : constant String := Root & "/native-bzip2.zip";
   Native_BZip2_ZIP64_Zip : constant String := Root & "/native-bzip2-zip64.zip";
   Native_Zstd_Zip : constant String := Root & "/native-zstd.zip";
   Native_Zstd_ZIP64_Zip : constant String := Root & "/native-zstd-zip64.zip";
   Legacy_Zstd_Zip : constant String := Root & "/legacy-zstd.zip";
   Legacy_Zstd_ZIP64_Zip : constant String := Root & "/legacy-zstd-zip64.zip";
   BZip2_Zip : constant String := Root & "/bzip2.zip";
   LZMA_Zip : constant String := Root & "/lzma.zip";
   LZMA_ZIP64_Zip : constant String := Root & "/lzma-zip64.zip";
   Link_Zip : constant String := Root & "/link.zip";
   Unsafe_Link_Zip : constant String := Root & "/unsafe-link.zip";
   Empty_Zip : constant String := Root & "/empty.zip";
   Manifest_Zip : constant String := Root & "/manifest.zip";
   Directory_Zip : constant String := Root & "/directory-entry.zip";
   Encrypted_Zip : constant String := Root & "/zipcrypto-stored.zip";
   AES_Zip : constant String := Root & "/aes-stored.zip";
   File_A : constant String := Source_Dir & "/a.txt";
   File_B : constant String := Source_Dir & "/b.txt";
   Empty_File : constant String := Source_Dir & "/empty.txt";
   Xattr_Source_Set : Boolean := False;
   Entries : Backup.Zip.Source_Entry_Vectors.Vector;
begin

   Check (Backup.Restore_Syntax.Path_Matches_Filter ("dir", "dir/a.txt"),
          "SPARK restore filter matches child path");
   Check (Backup.Restore_Syntax.Path_Matches_Filter ("dir/", "dir/a.txt"),
          "SPARK restore slash filter matches child path");
   Check (not Backup.Restore_Syntax.Path_Matches_Filter ("dir", "directory/a.txt"),
          "SPARK restore filter rejects prefix-only match");
   Check (not Backup.Restore_Syntax.Path_Matches_Filter ("", "dir/a.txt"),
          "SPARK restore filter rejects empty filter");
   Check (Backup.Restore_Syntax.Symlink_Target_Is_Safe ("dir/target"),
          "SPARK restore symlink target accepts relative path");
   Check (not Backup.Restore_Syntax.Symlink_Target_Is_Safe ("../target"),
          "SPARK restore symlink target rejects parent traversal");
   Check (not Backup.Restore_Syntax.Symlink_Target_Is_Safe ("dir//target"),
          "SPARK restore symlink target rejects empty segment");
   Check (not Backup.Restore_Syntax.Symlink_Target_Is_Safe ("dir\\target"),
          "SPARK restore symlink target rejects backslash");

   if Ada.Directories.Exists (Root & "/symlink-parent/dir") then
      Ada.Directories.Delete_File (Root & "/symlink-parent/dir");
   end if;
   if Ada.Directories.Exists (Root & "/output-link") then
      Ada.Directories.Delete_File (Root & "/output-link");
   end if;
   if GNAT.OS_Lib.Is_Symbolic_Link (Root & "/links-store/safe-link") then
      Ada.Directories.Delete_File (Root & "/links-store/safe-link");
   end if;
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;

   Ensure_Directory (Source_Dir);
   Write_Text (File_A, "alpha" & ASCII.LF & "beta");
   Write_Text (File_B, "bravo");
   Write_Text (Empty_File, "");

   Entries.Append (Make_File (File_A, "dir/a.txt", Backup.Zip.Stored));
   Check (Backup.Zip.Create_Archive (Stored_Zip, Entries) = Backup.Zip.Write_Ok,
          "create stored restore fixture");
   Check (Backup.Zip.Create_Archive (Split_Source_Zip, Entries) = Backup.Zip.Write_Ok,
          "create split restore source fixture");
   Write_Two_Part_Zip (Split_Source_Zip, Split_Zip);
   Entries.Clear;
   Entries.Append (Make_File (File_B, "bzip2-native.txt", Backup.Zip.BZip2));
   Check (Backup.Zip.Create_Archive (Native_BZip2_Zip, Entries) = Backup.Zip.Write_Ok,
          "create native bzip2 restore fixture");
   Write_ZIP64_Metadata_Copy (Native_BZip2_Zip, Native_BZip2_ZIP64_Zip);
   Entries.Clear;
   Entries.Append (Make_File (File_B, "zstd-native.txt", Backup.Zip.Zstd));
   Check (Backup.Zip.Create_Archive (Native_Zstd_Zip, Entries) = Backup.Zip.Write_Ok,
          "create native zstd restore fixture");
   Write_ZIP64_Metadata_Copy (Native_Zstd_Zip, Native_Zstd_ZIP64_Zip);
   Write_Legacy_Zstd_Method_Copy (Native_Zstd_Zip, Legacy_Zstd_Zip);
   Write_ZIP64_Metadata_Copy (Legacy_Zstd_Zip, Legacy_Zstd_ZIP64_Zip);
   Entries.Clear;
   Entries.Append (Make_File (File_B, "lzma-native.txt", Backup.Zip.LZMA));
   Check (Backup.Zip.Create_Archive (LZMA_Zip, Entries) = Backup.Zip.Write_Ok,
          "create native LZMA restore fixture");
   Write_ZIP64_Metadata_Copy (LZMA_Zip, LZMA_ZIP64_Zip);
   if Seven_Zip_Available then
      Write_Seven_Zip_Method_Zip (BZip2_Zip, "BZip2", "bzip2.txt", "bzip2 payload" & [1 .. 4096 => 'b']);
   end if;

   Write_Encrypted_Stored_Zip
     (Encrypted_Zip, "secret.txt", "classified", "secret");
   Write_Text (Root & "/zip-password.txt", "secret" & ASCII.LF);
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Encrypted_Zip, "--output-dir",
               Root & "/zipcrypto-restore", "--password-file",
               Root & "/zip-password.txt"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "traditional encrypted ZIP extraction succeeds: " &
             To_String (Diagnostic));
      Check (Read_Text (Root & "/zipcrypto-restore/secret.txt") = "classified",
             "traditional encrypted ZIP extraction restores plaintext");
   end;


   Write_AES_Stored_Zip (AES_Zip, "aes.txt", "aes secret", "secret");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", AES_Zip, "--output-dir",
               Root & "/aes-restore", "--password-file",
               Root & "/zip-password.txt"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "AES ZIP extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/aes-restore/aes.txt") = "aes secret",
             "AES ZIP extraction restores plaintext");
   end;

   Write_Directory_Zip (Directory_Zip, "explicit-dir/");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Directory_Zip, "--output-dir", Root & "/directory-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "explicit ZIP directory extraction succeeds: " & To_String (Diagnostic));
      Check (Ada.Directories.Exists (Root & "/directory-restore/explicit-dir")
             and then Ada.Directories.Kind (Root & "/directory-restore/explicit-dir") =
               Ada.Directories.Directory,
             "explicit ZIP directory entry restores as directory");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Stored_Zip, "--output-dir", Restore_Dir));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "stored archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Restore_Dir & "/dir/a.txt") = "alpha" & ASCII.LF & "beta",
             "stored archive restores file bytes");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Stored_Zip, "--output-dir", Restore_Dir));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Restore_Failed,
             "existing destination is refused by default");
      Check (Index (Diagnostic, "already exists") /= 0,
             "existing destination diagnostic is precise");
   end;

   GNAT.OS_Lib.Set_Executable (File_B);
   Xattr_Source_Set := Set_Test_Xattr (File_B, "xvalue");

   Entries.Clear;
   Entries.Append (Make_File (File_A, "dir/a.txt", Backup.Zip.Stored));
   Entries.Append (Make_File (File_B, "dir/b.txt", Backup.Zip.Stored));
   Check (Backup.Zip.Create_Archive (Select_Zip, Entries) = Backup.Zip.Write_Ok,
          "create selective restore fixture");

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--list", Select_Zip));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "direct archive listing succeeds: " & To_String (Diagnostic));
      Check (Index (Diagnostic, "backup list") /= 0,
             "archive listing uses list report");
      Check (Index (Diagnostic, "dir/a.txt") /= 0
             and then Index (Diagnostic, "dir/b.txt") /= 0,
             "archive listing includes file entries");
      Check (Index (Diagnostic, " mode=") /= 0
             and then Index (Diagnostic, " owner=") /= 0
             and then Index (Diagnostic, " xattrs=") /= 0
             and then Index (Diagnostic, " acl=") /= 0,
             "archive listing exposes metadata summary");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--list-json", "--list", Select_Zip));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "direct archive JSON listing succeeds: " & To_String (Diagnostic));
      Check (Index (Diagnostic, "backup-list-v1") /= 0,
             "archive JSON listing uses list format");
      Check (Index (Diagnostic, Character'Val (34) & "metadata" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "mode" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "has_owner" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "xattr_count" & Character'Val (34)) /= 0
             and then Index (Diagnostic, Character'Val (34) & "has_acl" & Character'Val (34)) /= 0,
             "archive JSON listing exposes metadata object");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Select_Zip, "--output-dir", Root & "/only",
               "--only", "dir/a.txt"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "selective restore with --only succeeds: " & To_String (Diagnostic));
      Check (Ada.Directories.Exists (Root & "/only/dir/a.txt"),
             "--only restores selected file");
      Check (not Ada.Directories.Exists (Root & "/only/dir/b.txt"),
             "--only skips unselected file");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Select_Zip, "--output-dir", Root & "/exclude",
               "--exclude", "dir/b.txt"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "selective restore with --exclude succeeds: " & To_String (Diagnostic));
      Check (Ada.Directories.Exists (Root & "/exclude/dir/a.txt"),
             "--exclude leaves other files restorable");
      Check (not Ada.Directories.Exists (Root & "/exclude/dir/b.txt"),
             "--exclude skips matching file");
      if Xattr_Source_Set then
         Check (Test_Xattr_Value (Root & "/exclude/dir/a.txt") = "",
                "unrelated file does not gain test xattr");
      end if;
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Select_Zip, "--output-dir", Root & "/xattrs",
               "--only", "dir/b.txt"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "xattr restore fixture succeeds: " & To_String (Diagnostic));
      if Xattr_Source_Set then
         Check (Test_Xattr_Value (Root & "/xattrs/dir/b.txt") = "xvalue",
                "restore preserves user xattr when supported");
      end if;
   end;

   Ensure_Directory (Root & "/skip/dir");
   Write_Text (Root & "/skip/dir/a.txt", "keep");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Select_Zip, "--output-dir", Root & "/skip",
               "--skip-existing"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "restore --skip-existing succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/skip/dir/a.txt") = "keep",
             "--skip-existing preserves existing file");
      Check (Ada.Directories.Exists (Root & "/skip/dir/b.txt"),
             "--skip-existing restores missing file");
      Check (GNAT.OS_Lib.Is_Executable_File (Root & "/skip/dir/b.txt"),
             "restore preserves executable mode metadata");
   end;

   Ensure_Directory (Root & "/overwrite/dir");
   Write_Text (Root & "/overwrite/dir/a.txt", "old");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Select_Zip, "--output-dir", Root & "/overwrite",
               "--overwrite"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "restore --overwrite succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/overwrite/dir/a.txt") =
             "alpha" & ASCII.LF & "beta",
             "--overwrite replaces existing ordinary file");
      Check (Ada.Directories.Exists (Root & "/overwrite/dir/b.txt"),
             "--overwrite restores missing file");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Native_BZip2_Zip, "--output-dir",
               Root & "/native-bzip2-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "native bzip2 ZIP archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/native-bzip2-restore/bzip2-native.txt") = "bravo",
             "native bzip2 ZIP archive restores file bytes");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Native_BZip2_ZIP64_Zip, "--output-dir",
               Root & "/native-bzip2-zip64-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "native bzip2 ZIP64 archive extraction succeeds: " &
         To_String (Diagnostic));
      Check
        (Read_Text
           (Root & "/native-bzip2-zip64-restore/bzip2-native.txt") =
         "bravo",
         "native bzip2 ZIP64 archive restores file bytes");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Native_Zstd_Zip, "--output-dir",
               Root & "/native-zstd-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "native zstd ZIP archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/native-zstd-restore/zstd-native.txt") = "bravo",
             "native zstd ZIP archive restores file bytes");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Native_Zstd_ZIP64_Zip, "--output-dir",
               Root & "/native-zstd-zip64-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "native zstd ZIP64 archive extraction succeeds: " &
         To_String (Diagnostic));
      Check
        (Read_Text
           (Root & "/native-zstd-zip64-restore/zstd-native.txt") =
         "bravo",
         "native zstd ZIP64 archive restores file bytes");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Legacy_Zstd_Zip, "--output-dir",
               Root & "/legacy-zstd-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "legacy zstd ZIP archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/legacy-zstd-restore/zstd-native.txt") = "bravo",
             "legacy zstd ZIP archive restores file bytes");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Legacy_Zstd_ZIP64_Zip, "--output-dir",
               Root & "/legacy-zstd-zip64-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check
        (Status = Backup.Workflow.Execution_Ok,
         "legacy zstd ZIP64 archive extraction succeeds: " &
         To_String (Diagnostic));
      Check
        (Read_Text
           (Root & "/legacy-zstd-zip64-restore/zstd-native.txt") =
         "bravo",
         "legacy zstd ZIP64 archive restores file bytes");
   end;

   Ensure_Directory (Root & "/rename/dir");
   Write_Text (Root & "/rename/dir/a.txt", "old");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Select_Zip, "--output-dir", Root & "/rename",
               "--rename-existing"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "restore --rename-existing succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/rename/dir/a.txt") =
             "alpha" & ASCII.LF & "beta",
             "--rename-existing restores replacement file");
      Check (Read_Text (Root & "/rename/dir/a.txt.existing.0") = "old",
             "--rename-existing preserves old destination beside restore");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", LZMA_Zip, "--output-dir", Root & "/lzma-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "LZMA ZIP archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/lzma-restore/lzma-native.txt") = "bravo",
             "LZMA ZIP archive restores file bytes");
   end;
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", LZMA_ZIP64_Zip, "--output-dir",
               Root & "/lzma-zip64-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "LZMA ZIP64 archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/lzma-zip64-restore/lzma-native.txt") = "bravo",
             "LZMA ZIP64 archive restores file bytes");
   end;

   if Seven_Zip_Available then
      declare
         Config : constant Backup.CLI.Configuration := Parsed
           (Args ("--extract", BZip2_Zip, "--output-dir", Root & "/bzip2-restore"));
         Status : constant Backup.Workflow.Execution_Status :=
           Backup.Workflow.Execute (Config, Diagnostic);
      begin
         Check (Status = Backup.Workflow.Execution_Ok,
                "bzip2 ZIP archive extraction succeeds: " & To_String (Diagnostic));
         Check (Read_Text (Root & "/bzip2-restore/bzip2.txt") = "bzip2 payload" & [1 .. 4096 => 'b'],
                "bzip2 ZIP archive restores file bytes");
      end;
   end if;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Split_Zip, "--output-dir", Root & "/split-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "split ZIP archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/split-restore/dir/a.txt") = "alpha" & ASCII.LF & "beta",
             "split ZIP archive restores file bytes");
   end;

   Entries.Clear;
   Entries.Append (Make_File (File_A, "deflated.txt", Backup.Zip.Deflated));
   Check (Backup.Zip.Create_Archive (Deflated_Zip, Entries) = Backup.Zip.Write_Ok,
          "create deflated restore fixture");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Deflated_Zip, "--output-dir", Root & "/inflate"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "deflated archive extraction succeeds: " & To_String (Diagnostic));
      Check (Read_Text (Root & "/inflate/deflated.txt") = "alpha" & ASCII.LF & "beta",
             "deflated archive restores file bytes");
   end;

   Entries.Clear;
   Entries.Append (Make_File (Empty_File, "empty.txt", Backup.Zip.Stored));
   Check (Backup.Zip.Create_Archive (Empty_Zip, Entries) = Backup.Zip.Write_Ok,
          "create empty stored restore fixture");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Empty_Zip, "--output-dir", Root & "/empty-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "zero-byte stored file extraction succeeds: " & To_String (Diagnostic));
      Check (Ada.Directories.Exists (Root & "/empty-restore/empty.txt"),
             "zero-byte stored file is created");
      Check (Read_Text (Root & "/empty-restore/empty.txt") = "",
             "zero-byte stored file remains empty");
   end;

   declare
      Make_Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--manifest", Manifest_Zip, Source_Dir));
      Make_Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Make_Config, Diagnostic);
   begin
      Check (Make_Status = Backup.Workflow.Execution_Ok,
             "create manifest restore fixture: " & To_String (Diagnostic));
   end;
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Manifest_Zip, "--output-dir", Root & "/manifest-restore"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "manifest archive extraction succeeds: " & To_String (Diagnostic));
      Check (not Ada.Directories.Exists
               (Root & "/manifest-restore/" & Backup.Manifest.Manifest_Path),
             "manifest metadata is validated but not restored as a payload file");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--dry-run", "--list-json", "--extract", Stored_Zip,
               "--output-dir", Dry_Dir));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "dry-run JSON extraction succeeds");
      Check (not Ada.Directories.Exists (Dry_Dir),
             "dry-run extraction does not create target directory");
      Check (Index (Diagnostic, "backup-restore-v1") /= 0,
             "dry-run extraction emits deterministic JSON format marker");
      Check (Index (Diagnostic, "would-restore") /= 0,
             "dry-run extraction reports planned restore action");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--dry-run", "--list-json", "--extract", Stored_Zip,
               "--output-dir", Restore_Dir));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "dry-run existing destination reports rejection without failing");
      Check (Index (Diagnostic, "would-reject") /= 0,
             "dry-run existing destination is classified as would-reject");
      Check (Index (Diagnostic, "destination already exists") /= 0,
             "dry-run existing destination preserves diagnostic reason");
   end;

   declare
      Outside_Dir : constant String := Root & "/outside-parent";
      Symlink_Root : constant String := Root & "/symlink-parent";
      Link_Dir : constant String := Symlink_Root & "/dir";
   begin
      Ensure_Directory (Outside_Dir);
      Ensure_Directory (Symlink_Root);
      if Create_Symlink (Outside_Dir, Link_Dir) then
         declare
            Config : constant Backup.CLI.Configuration := Parsed
              (Args ("--extract", Stored_Zip, "--output-dir", Symlink_Root));
            Status : constant Backup.Workflow.Execution_Status :=
              Backup.Workflow.Execute (Config, Diagnostic);
         begin
            Check (Status = Backup.Workflow.Execution_Restore_Failed,
                   "restore refuses a symlinked destination parent");
            Check (Index (Diagnostic, "symbolic link") /= 0,
                   "symlinked parent diagnostic is precise");
            Check (not Ada.Directories.Exists (Outside_Dir & "/a.txt"),
                   "restore does not write through a symlinked parent");
         end;
      end if;
   end;

   declare
      Outside_Dir : constant String := Root & "/outside-output";
      Output_Link : constant String := Root & "/output-link";
   begin
      Ensure_Directory (Outside_Dir);
      if Create_Symlink (Outside_Dir, Output_Link) then
         declare
            Config : constant Backup.CLI.Configuration := Parsed
              (Args ("--extract", Stored_Zip, "--output-dir", Output_Link));
            Status : constant Backup.Workflow.Execution_Status :=
              Backup.Workflow.Execute (Config, Diagnostic);
         begin
            Check (Status = Backup.Workflow.Execution_Restore_Failed,
                   "restore refuses a symlinked output directory");
            Check (Index (Diagnostic, "--output-dir") /= 0
                   and then Index (Diagnostic, "symbolic link") /= 0,
                   "symlinked output directory diagnostic is precise");
         end;
         declare
            Config : constant Backup.CLI.Configuration := Parsed
              (Args ("--dry-run", "--list-json", "--extract", Stored_Zip,
                     "--output-dir", Output_Link));
            Status : constant Backup.Workflow.Execution_Status :=
              Backup.Workflow.Execute (Config, Diagnostic);
         begin
            Check (Status = Backup.Workflow.Execution_Ok,
                   "dry-run symlinked output directory reports without failing");
            Check (Index (Diagnostic, "would-reject") /= 0
                   and then Index (Diagnostic, "--output-dir path is unsafe") /= 0,
                   "dry-run symlinked output directory is classified as would-reject");
         end;
      end if;
   end;

   Entries.Clear;
   Entries.Append (Make_Symlink ("safe-link", "inside/target"));
   Check (Backup.Zip.Create_Archive (Link_Zip, Entries) = Backup.Zip.Write_Ok,
          "create symlink restore fixture");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--extract", Link_Zip, "--output-dir", Root & "/links"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "default symlink extraction policy skips link entries");
      Check (Index (Diagnostic, "symlink restoration skipped by default") /= 0,
             "symlink skip diagnostic is reported");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--symlinks=store-link", "--extract", Link_Zip,
               "--output-dir", Root & "/links-store"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "store-link symlink extraction succeeds: " & To_String (Diagnostic));
      Check (GNAT.OS_Lib.Is_Symbolic_Link (Root & "/links-store/safe-link"),
             "store-link restore creates symlink entry");
   end;

   Entries.Clear;
   Entries.Append (Make_Symlink ("unsafe-link", "../outside"));
   Check (Backup.Zip.Create_Archive (Unsafe_Link_Zip, Entries) = Backup.Zip.Write_Ok,
          "create unsafe symlink restore fixture");
   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--symlinks=store-link", "--extract", Unsafe_Link_Zip,
               "--output-dir", Root & "/unsafe-links"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Restore_Failed,
             "unsafe symlink target is rejected when link restoration is requested");
      Check (Index (Diagnostic, "unsafe symlink target") /= 0,
             "unsafe symlink diagnostic is precise");
   end;

   declare
      Config : constant Backup.CLI.Configuration := Parsed
        (Args ("--dry-run", "--list-json", "--symlinks=store-link",
               "--extract", Unsafe_Link_Zip, "--output-dir",
               Root & "/unsafe-link-dry-run"));
      Status : constant Backup.Workflow.Execution_Status :=
        Backup.Workflow.Execute (Config, Diagnostic);
   begin
      Check (Status = Backup.Workflow.Execution_Ok,
             "dry-run unsafe symlink reports rejection without failing");
      Check (Index (Diagnostic, "would-reject") /= 0,
             "dry-run unsafe symlink is classified as would-reject");
      Check (not Ada.Directories.Exists (Root & "/unsafe-link-dry-run"),
             "dry-run unsafe symlink does not create target directory");
   end;

   declare
      Corrupt : constant String := Root & "/traversal.zip";
      Data : Ada.Streams.Stream_Element_Array := Read_All (Stored_Zip);
      Central : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0201_4B50#);
      Local : constant Ada.Streams.Stream_Element_Offset :=
        Find_Signature (Data, 16#0403_4B50#);
   begin
      --  Replace the first six bytes of dir/a.txt with ../bad.
      Data (Local + 30) := Ada.Streams.Stream_Element (Character'Pos ('.'));
      Data (Local + 31) := Ada.Streams.Stream_Element (Character'Pos ('.'));
      Data (Local + 32) := Ada.Streams.Stream_Element (Character'Pos ('/'));
      Data (Local + 33) := Ada.Streams.Stream_Element (Character'Pos ('b'));
      Data (Local + 34) := Ada.Streams.Stream_Element (Character'Pos ('a'));
      Data (Local + 35) := Ada.Streams.Stream_Element (Character'Pos ('d'));
      Put_U16_At (Data, Local + 26, 6);
      Data (Central + 46) := Ada.Streams.Stream_Element (Character'Pos ('.'));
      Data (Central + 47) := Ada.Streams.Stream_Element (Character'Pos ('.'));
      Data (Central + 48) := Ada.Streams.Stream_Element (Character'Pos ('/'));
      Data (Central + 49) := Ada.Streams.Stream_Element (Character'Pos ('b'));
      Data (Central + 50) := Ada.Streams.Stream_Element (Character'Pos ('a'));
      Data (Central + 51) := Ada.Streams.Stream_Element (Character'Pos ('d'));
      Put_U16_At (Data, Central + 28, 6);
      Write_All (Corrupt, Data);
      declare
         Config : constant Backup.CLI.Configuration := Parsed
           (Args ("--extract", Corrupt, "--output-dir", Root & "/bad"));
         Status : constant Backup.Workflow.Execution_Status :=
           Backup.Workflow.Execute (Config, Diagnostic);
      begin
         Check (Status = Backup.Workflow.Execution_Restore_Failed,
                "path traversal archive is rejected during extraction");
      end;
   end;

   declare
      Config : Backup.CLI.Configuration;
      OK : constant Boolean := Backup.CLI.Parse
        (Args ("--extract", Stored_Zip), Config, Diagnostic);
   begin
      Check (not OK, "extract requires output directory");
      Check (Index (Diagnostic, "--output-dir") /= 0,
             "missing output directory diagnostic names option");
   end;


   Check (Backup.Restore_Syntax.Path_Matches_Filter ("dir", "dir/a.txt"),
          "SPARK restore filter matches child path");
   Check (Backup.Restore_Syntax.Path_Matches_Filter ("dir/", "dir/a.txt"),
          "SPARK restore slash filter matches child path");
   Check (not Backup.Restore_Syntax.Path_Matches_Filter ("dir", "directory/a.txt"),
          "SPARK restore filter rejects prefix-only match");
   Check (not Backup.Restore_Syntax.Path_Matches_Filter ("", "dir/a.txt"),
          "SPARK restore filter rejects empty filter");
   Check (Backup.Restore_Syntax.Symlink_Target_Is_Safe ("dir/target"),
          "SPARK restore symlink target accepts relative path");
   Check (not Backup.Restore_Syntax.Symlink_Target_Is_Safe ("../target"),
          "SPARK restore symlink target rejects parent traversal");
   Check (not Backup.Restore_Syntax.Symlink_Target_Is_Safe ("dir//target"),
          "SPARK restore symlink target rejects empty segment");
   Check (not Backup.Restore_Syntax.Symlink_Target_Is_Safe ("dir\\target"),
          "SPARK restore symlink target rejects backslash");

   if Ada.Directories.Exists (Root & "/symlink-parent/dir") then
      Ada.Directories.Delete_File (Root & "/symlink-parent/dir");
   end if;
   if Ada.Directories.Exists (Root & "/output-link") then
      Ada.Directories.Delete_File (Root & "/output-link");
   end if;
   if GNAT.OS_Lib.Is_Symbolic_Link (Root & "/links-store/safe-link") then
      Ada.Directories.Delete_File (Root & "/links-store/safe-link");
   end if;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup restore tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup restore test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Restore_Tests;
