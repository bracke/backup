with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with GNAT.OS_Lib;

with Project_Tools.Files;

with Backup.Manifest;
with Backup.Paths;
with Backup.Scanner;
with Backup.Zip;
with Backup.Zip_Syntax;
with Zlib;

procedure Backup_Zip_Tests is
   use Ada.Streams;
   use Interfaces;
   use type Backup.Paths.Validation_Status;
   use type Backup.Manifest.Build_Result;
   use type Backup.Zip.Write_Result;
   use type Zlib.Status_Code;
   use type GNAT.OS_Lib.String_Access;

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

   function Work_Root return String is
   begin
      return Ada.Directories.Compose
        ("/tmp",
         "backup_zip_tests");
   end Work_Root;

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Directory;

   function Seven_Zip_Available return Boolean is
      Path : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Locate_Exec_On_Path ("7z");
   begin
      if Path = null then
         return False;
      end if;

      GNAT.OS_Lib.Free (Path);
      return True;
   end Seven_Zip_Available;

   function Decimal_Natural (Value : Natural) return String is
   begin
      return Ada.Strings.Fixed.Trim
        (Natural'Image (Value), Ada.Strings.Left);
   end Decimal_Natural;

   function Decimal_U64 (Value : Unsigned_64) return String is
   begin
      return Ada.Strings.Fixed.Trim
        (Unsigned_64'Image (Value), Ada.Strings.Left);
   end Decimal_U64;

   function Make_Source_Entry
     (Source_Path  : String;
      Archive_Path : String;
      Byte_Size    : Unsigned_64 := 0;
      Method       : Backup.Zip.Compression_Method := Backup.Zip.Stored)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      Status := Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
      pragma Assert
        (Status = Backup.Paths.Valid,
         "test archive path is valid");
      return
        (Source_Path  => Backup.Paths.Normalize_File_System_Path (Source_Path),
         Archive_Path => Archive,
         Byte_Size    => Byte_Size,
         Method       => Method,
         Kind         => Backup.Zip.Source_File,
         Generated    => False,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Content      => Ada.Strings.Unbounded.Null_Unbounded_String);
   end Make_Source_Entry;

   function Make_Scanner_Entry
     (Source_Path  : String;
      Archive_Path : String;
      Byte_Size    : Unsigned_64;
      Method       : Backup.Zip.Compression_Method)
      return Backup.Scanner.Discovered_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      Status := Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
      pragma Assert
        (Status = Backup.Paths.Valid,
         "test archive path is valid");
      return
        (Source_Path           =>
            Backup.Paths.Normalize_File_System_Path (Source_Path),
         Archive_Path          => Archive,
         Kind                  => Backup.Scanner.Entry_File,
         Byte_Size             => Byte_Size,
         Has_Modification_Time => False,
         Modification_Time     => Ada.Calendar.Time_Of (1901, 1, 1),
         Compression_Method    => Method,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Link_Target           =>
            Ada.Strings.Unbounded.Null_Unbounded_String);
   end Make_Scanner_Entry;

   function Make_Generated_Entry
     (Archive_Path : String;
      Content      : String := "")
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      Status := Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
      pragma Assert
        (Status = Backup.Paths.Valid,
         "test generated archive path is valid");
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
         Content      => Ada.Strings.Unbounded.To_Unbounded_String (Content));
   end Make_Generated_Entry;

   function Make_Symlink_Entry
     (Archive_Path : String;
      Target_Text  : String;
      Method       : Backup.Zip.Compression_Method := Backup.Zip.Stored)
      return Backup.Zip.Source_Entry
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      Status := Backup.Paths.Make_Archive_Path (Archive_Path, Archive);
      pragma Assert
        (Status = Backup.Paths.Valid,
         "test symlink archive path is valid");
      return
        (Source_Path  => Backup.Paths.Normalize_File_System_Path ("."),
         Archive_Path => Archive,
         Byte_Size    => Unsigned_64 (Target_Text'Length),
         Method       => Method,
         Kind         => Backup.Zip.Source_Symlink,
         Generated    => False,
         Has_Prepared_Payload  => False,
         Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
         Prepared_Compressed_Size => 0,
         Content      =>
           Ada.Strings.Unbounded.To_Unbounded_String (Target_Text));
   end Make_Symlink_Entry;

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

   function U64_At
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return Unsigned_64
   is
   begin
      return Unsigned_64 (U32_At (Data, Pos))
        or Shift_Left (Unsigned_64 (U32_At (Data, Pos + 4)), 32);
   end U64_At;

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

   function Count_Signature
     (Data      : Stream_Element_Array;
      Signature : Unsigned_32)
      return Natural
   is
      Count : Natural := 0;
   begin
      for Pos in Data'First .. Data'Last - 3 loop
         if U32_At (Data, Pos) = Signature then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_Signature;

   function Nth_Signature
     (Data      : Stream_Element_Array;
      Signature : Unsigned_32;
      Number    : Positive)
      return Stream_Element_Offset
   is
      Seen : Natural := 0;
   begin
      for Pos in Data'First .. Data'Last - 3 loop
         if U32_At (Data, Pos) = Signature then
            Seen := Seen + 1;
            if Seen = Number then
               return Pos;
            end if;
         end if;
      end loop;
      return 0;
   end Nth_Signature;

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

   Root : constant String := Work_Root;
   Src  : constant String := Root & "/src";

   procedure Check_External_Method_Creation
     (Method      : Backup.Zip.Compression_Method;
      Method_Name : String;
      Method_Id   : Unsigned_16;
      Flags       : Unsigned_16 := 8;
      Central_Method_Message : String := "")
   is
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/" & Method_Name & "-created.zip";
   begin
      Entries.Append
        (Make_Source_Entry
           (Src & "/large.txt", "large.txt",
            Byte_Size => 17_000,
            Method => Method));
      declare
         Status : constant Backup.Zip.Write_Result :=
           Backup.Zip.Create_Archive (Output, Entries);
      begin
         if Status = Backup.Zip.Write_Compression_Failed then
            return;
         end if;

         Check
           (Status = Backup.Zip.Write_Ok,
            "single " & Method_Name & " file archive creation succeeds");
         if Status = Backup.Zip.Write_Ok then
            declare
               Zip_Data : constant Stream_Element_Array := Read_All (Output);
               Central  : constant Stream_Element_Offset :=
                 Find_Signature (Zip_Data, 16#0201_4B50#);
               CSize    : constant Unsigned_32 := U32_At (Zip_Data, Central + 20);
               Local    : constant Stream_Element_Offset :=
                 Find_Signature (Zip_Data, 16#0403_4B50#);
               Name_Len : constant Unsigned_16 := U16_At (Zip_Data, Local + 26);
               Extra_Len : constant Unsigned_16 := U16_At (Zip_Data, Local + 28);
               Payload  : constant Stream_Element_Offset :=
                 Local + 30 + Stream_Element_Offset (Name_Len) +
                 Stream_Element_Offset (Extra_Len);
               Descriptor : constant Stream_Element_Offset :=
                 Payload + Stream_Element_Offset (CSize);
            begin
               Check (U16_At (Zip_Data, Local + 6) = Flags,
                      Method_Name & " local header uses expected flags");
               Check (U16_At (Zip_Data, Local + 8) = Method_Id,
                      Method_Name & " local header uses method " &
                      Decimal_Natural (Natural (Method_Id)));
               Check (U16_At (Zip_Data, Central + 8) = Flags,
                      Method_Name & " central header records expected flags");
               Check (U16_At (Zip_Data, Central + 10) = Method_Id,
                      (if Central_Method_Message'Length > 0 then
                         Central_Method_Message
                       else
                         Method_Name & " central header uses method " &
                         Decimal_Natural (Natural (Method_Id))));
               Check (U32_At (Zip_Data, Central + 24) = 17_000,
                      Method_Name & " central uncompressed size is original size");
               Check (U32_At (Zip_Data, Descriptor) = 16#0807_4B50#,
                      Method_Name & " descriptor signature is present");
               Check (U32_At (Zip_Data, Descriptor + 8) = CSize,
                      Method_Name & " descriptor compressed size matches central");
               Check (U32_At (Zip_Data, Descriptor + 12) = 17_000,
                      Method_Name & " descriptor uncompressed size matches central");
            end;
         end if;
      end;
   end Check_External_Method_Creation;

   procedure Check_Method_Number
     (Method    : Backup.Zip.Compression_Method;
      Expected  : Unsigned_16;
      Test_Name : String)
   is
   begin
      Check
        (Backup.Zip.Method_Number (Method) = Expected,
         Test_Name);
   end Check_Method_Number;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;
   Ensure_Directory (Src & "/nested");

   Write_Text (Src & "/one.txt", "hello" & Character'Val (10));
   Write_Text (Src & "/two.txt", "world" & Character'Val (10));
   Write_Text
     (Src & "/nested/three.adb",
      "procedure Three is begin null; end Three;");
   Write_Text (Src & "/empty.txt", "");
   Write_Text (Src & "/large.txt", [1 .. 17_000 => 'A']);

   Check
     (Backup.Zip_Syntax.Is_Supported_Zip_Version (63),
      "ZIP syntax accepts ZIP version 6.3");
   Check
     (not Backup.Zip_Syntax.Is_Supported_Zip_Version (64),
      "ZIP syntax rejects unsupported version 6.4");
   Check
     (Backup.Zip_Syntax.Is_Supported_General_Flags (16#0004#, 8),
      "ZIP syntax allows deflate option bit on deflated entries");
   Check
     (not Backup.Zip_Syntax.Is_Supported_General_Flags (16#0004#, 0),
      "ZIP syntax rejects deflate option bit on stored entries");
   Check
     (not Backup.Zip_Syntax.Is_Supported_General_Flags (16#2000#, 8),
      "ZIP syntax rejects unknown general-purpose bit flags");

   Check_Method_Number
     (Backup.Zip.Stored, 0, "stored compression uses ZIP method 0");
   Check_Method_Number
     (Backup.Zip.Deflated, 8, "deflated compression uses ZIP method 8");
   Check_Method_Number
     (Backup.Zip.BZip2, 12, "bzip2 compression uses ZIP method 12");
   Check_Method_Number
     (Backup.Zip.LZMA, 14, "lzma compression uses ZIP method 14");
   Check_Method_Number
     (Backup.Zip.PPMd, 98, "ppmd compression uses ZIP method 98");
   Check_Method_Number
     (Backup.Zip.Zstd, 93, "zstd compression uses ZIP method 93");

   declare
      Output : constant String := Root & "/empty.zip";
   begin
      Check
        (Backup.Zip.Create_Archive (Output) = Backup.Zip.Write_Ok,
         "empty ZIP archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
      begin
         Check (Zip_Data'Length = 22, "empty ZIP contains only EOCD");
         Check (U32_At (Zip_Data, 1) = 16#0605_4B50#, "empty ZIP EOCD");
         Check (U16_At (Zip_Data, 9) = 0, "empty ZIP entry count zero");
         Check (U32_At (Zip_Data, 13) = 0, "empty ZIP central size zero");
         Check (U32_At (Zip_Data, 17) = 0, "empty ZIP central offset zero");
         Check
           (Find_Signature (Zip_Data, 16#0606_4B50#) = 0,
            "empty small ZIP does not emit ZIP64 EOCD");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/single.zip";
   begin
      Entries.Append (Make_Source_Entry (Src & "/one.txt", "one.txt"));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "single stored file archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         Central  : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0201_4B50#);
         Eocd     : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0605_4B50#);
      begin
         Check
           (U32_At (Zip_Data, 1) = 16#0403_4B50#,
            "local header signature");
         Check (U16_At (Zip_Data, 9) = 0, "local header uses stored method");
         Check (U16_At (Zip_Data, 13) >= 33, "local header has valid DOS date");
         Check (U32_At (Zip_Data, 15) = 16#363A_3020#, "CRC32 for one.txt");
         Check (U32_At (Zip_Data, 19) = 6, "compressed size is payload size");
         Check
           (U32_At (Zip_Data, 23) = 6,
            "uncompressed size is payload size");
         Check
           (U32_At (Zip_Data, Central) = 16#0201_4B50#,
            "central directory signature");
         Check
           (U16_At (Zip_Data, Central + 10) = 0,
            "central method stored");
         Check
           (U16_At (Zip_Data, Central + 12) = U16_At (Zip_Data, 11),
            "central DOS time matches local header");
         Check
           (U16_At (Zip_Data, Central + 14) = U16_At (Zip_Data, 13),
            "central DOS date matches local header");
         Check
           (U32_At (Zip_Data, Central + 20)
            = U32_At (Zip_Data, Central + 24),
            "central compressed size equals uncompressed size");
         Check
           (U16_At (Zip_Data, Central + 36) = 1,
            "central internal attributes mark text payload");
         Check
           ((U32_At (Zip_Data, Central + 38) and 16#F000_0000#) = 16#8000_0000#,
            "central external attributes record regular file type");
         Check
           (Find_Signature (Zip_Data, 16#0606_4B50#) = 0,
            "small stored archive remains ZIP32-compatible");
         Check
           (U32_At (Zip_Data, Central + 42) = 0,
            "first local header offset is zero");
         Check (U16_At (Zip_Data, Eocd + 10) = 1, "EOCD entry count is one");
         Check
           (U32_At (Zip_Data, Eocd + 12)
            = Unsigned_32 (Eocd - Central),
            "EOCD central directory size is exact");
         Check
           (U32_At (Zip_Data, Eocd + 16)
            = Unsigned_32 (Central - Zip_Data'First),
            "EOCD central directory offset is exact");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/binary.zip";
      Binary  : constant String := Src & "/binary.dat";
      File    : Ada.Streams.Stream_IO.File_Type;
      Data    : constant Stream_Element_Array (1 .. 3) := [0, 16#FF#, 10];
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Binary);
      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);
      Entries.Append (Make_Source_Entry (Binary, "binary.dat"));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "binary stored file archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         Central  : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0201_4B50#);
      begin
         Check
           (U16_At (Zip_Data, Central + 36) = 0,
            "central internal attributes leave binary payload unmarked");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/deflated.zip";
   begin
      Entries.Append
        (Make_Source_Entry
           (Src & "/one.txt",
            "one.txt",
            Method => Backup.Zip.Deflated));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "single deflated file archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         Central  : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0201_4B50#);
         Payload  : constant Stream_Element_Offset := 31 + 7;
         CSize    : constant Unsigned_32 := U32_At (Zip_Data, Central + 20);
         Descriptor : constant Stream_Element_Offset :=
           Payload + Stream_Element_Offset (CSize);
         Expected_Size : Unsigned_64 := 0;
         Size_Status   : Zlib.Status_Code := Zlib.Ok;
         Manifest_Entries : Backup.Scanner.Entry_Vectors.Vector;
         Manifest_Text    : Ada.Strings.Unbounded.Unbounded_String;
         Manifest_Status  : Backup.Manifest.Build_Result;
      begin
         Check (U16_At (Zip_Data, 7) = 8, "local header uses data descriptor");
         Check (U16_At (Zip_Data, 9) = 8, "local header uses deflate");
         Check (U32_At (Zip_Data, 15) = 0, "deflated local CRC is deferred");
         Check (U32_At (Zip_Data, 19) = 0, "deflated local compressed size is deferred");
         Check (U32_At (Zip_Data, 23) = 0, "deflated local uncompressed size is deferred");
         Check (U16_At (Zip_Data, Central + 8) = 8, "central header records data descriptor flag");
         Check (U16_At (Zip_Data, Central + 10) = 8, "central header uses deflate");
         Check (CSize < 11, "deflated payload is actually compressed");
         Zlib.Deflate_Raw_File_Size
           (Input_Path      => Src & "/one.txt",
            Mode            => Zlib.Auto,
            Compressed_Size => Expected_Size,
            Status          => Size_Status);
         Check (Size_Status = Zlib.Ok, "zlib size-only pass succeeds for ZIP payload");
         Check
           (Unsigned_64 (CSize) = Expected_Size,
            "central compressed size matches zlib size-only pass");
         Manifest_Entries.Append
           (Make_Scanner_Entry
              (Src & "/one.txt", "one.txt", 6, Backup.Zip.Deflated));
         Manifest_Status := Backup.Manifest.Build
           (Manifest_Entries, Manifest_Text);
         Check
           (Manifest_Status = Backup.Manifest.Build_Ok,
            "manifest build succeeds for deflated ZIP entry");
         Check
           (Ada.Strings.Fixed.Index
              (Ada.Strings.Unbounded.To_String (Manifest_Text),
               """compressed_size"": " & Decimal_U64 (Expected_Size)) /= 0,
            "manifest compressed size matches central directory");
         Check (U32_At (Zip_Data, Central + 24) = 6, "central uncompressed size tracks original payload");
         Check (U32_At (Zip_Data, Descriptor) = 16#0807_4B50#, "data descriptor signature is present");
         Check (U32_At (Zip_Data, Descriptor + 4) = 16#363A_3020#, "data descriptor CRC32 is original bytes");
         Check (U32_At (Zip_Data, Descriptor + 8) = CSize, "data descriptor compressed size matches central");
         Check (U32_At (Zip_Data, Descriptor + 12) = 6, "data descriptor uncompressed size matches central");
      end;
   end;

   Check_External_Method_Creation
     (Backup.Zip.BZip2, "BZip2", 12,
      Central_Method_Message => "BZip2 central header uses method 12");
   Check_External_Method_Creation
     (Backup.Zip.Zstd, "Zstd", 93,
      Central_Method_Message => "Zstd central header uses method 93");
   Check_External_Method_Creation
     (Backup.Zip.LZMA, "LZMA", 14, 10,
      Central_Method_Message => "LZMA central header uses method 14");

   if Seven_Zip_Available then
      Check_External_Method_Creation
        (Backup.Zip.PPMd, "PPMd", 98,
         Central_Method_Message => "PPMd central header uses method 98");
   end if;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/deflated-empty.zip";
   begin
      Entries.Append
        (Make_Source_Entry
           (Src & "/empty.txt",
            "empty.txt",
            Method => Backup.Zip.Deflated));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "empty deflated file archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         Central  : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0201_4B50#);
         Payload  : constant Stream_Element_Offset := 31 + 9;
         CSize    : constant Unsigned_32 := U32_At (Zip_Data, Central + 20);
         Descriptor : constant Stream_Element_Offset :=
           Payload + Stream_Element_Offset (CSize);
      begin
         Check (U16_At (Zip_Data, 7) = 8, "empty deflated local header uses descriptor");
         Check (U16_At (Zip_Data, 9) = 8, "empty deflated local header uses deflate");
         Check (U32_At (Zip_Data, 19) = 0, "empty deflated local compressed size is deferred");
         Check (U32_At (Zip_Data, 23) = 0, "empty deflated local uncompressed size is deferred");
         Check (CSize > 0, "empty deflated central compressed size tracks payload");
         Check (U32_At (Zip_Data, Central + 24) = 0, "empty deflated central uncompressed size is zero");
         Check (U32_At (Zip_Data, Descriptor) = 16#0807_4B50#, "empty deflated descriptor signature is present");
         Check (U32_At (Zip_Data, Descriptor + 8) = CSize, "empty deflated descriptor compressed size matches central");
         Check (U32_At (Zip_Data, Descriptor + 12) = 0, "empty deflated descriptor uncompressed size matches central");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/deflated-large.zip";
   begin
      Entries.Append
        (Make_Source_Entry
           (Src & "/large.txt",
            "large.txt",
            Method => Backup.Zip.Deflated));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "large deflated file archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         Central  : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0201_4B50#);
         Payload  : constant Stream_Element_Offset := 31 + 9;
         CSize    : constant Unsigned_32 := U32_At (Zip_Data, Central + 20);
         Descriptor : constant Stream_Element_Offset :=
           Payload + Stream_Element_Offset (CSize);
      begin
         Check (U16_At (Zip_Data, 7) = 8, "large deflated local header uses descriptor");
         Check (U32_At (Zip_Data, 19) = 0, "large deflated local compressed size is deferred");
         Check (U32_At (Zip_Data, 23) = 0, "large deflated local uncompressed size is deferred");
         Check (CSize < 17_000, "large deflated payload is smaller than source");
         Check (U32_At (Zip_Data, Central + 24) = 17_000, "large deflated uncompressed size is original size");
         Check (U32_At (Zip_Data, Descriptor) = 16#0807_4B50#, "large deflated descriptor signature is present");
         Check (U32_At (Zip_Data, Descriptor + 8) = CSize, "large deflated descriptor compressed size matches central");
         Check (U32_At (Zip_Data, Descriptor + 12) = 17_000, "large deflated descriptor uncompressed size matches central");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/mixed.zip";
   begin
      Entries.Append
        (Make_Source_Entry
           (Src & "/one.txt",
            "one.txt",
            Method => Backup.Zip.Stored));
      Entries.Append
        (Make_Source_Entry
           (Src & "/nested/three.adb",
            "nested/three.adb",
            Method => Backup.Zip.Deflated));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "mixed stored and deflated archive creation succeeds");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         First_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 1);
         Second_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 2);
         Second_Local : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0403_4B50#, 2);
      begin
         Check
           (U16_At (Zip_Data, First_Central + 10) = 0,
            "mixed first central entry remains stored");
         Check
           (U16_At (Zip_Data, Second_Central + 10) = 8,
            "mixed second central entry is deflated");
         Check
           (U32_At (Zip_Data, Second_Central + 42)
            = Unsigned_32 (Second_Local - Zip_Data'First),
            "mixed central offset follows compressed payload sizes");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/multi.zip";
   begin
      Entries.Append (Make_Source_Entry (Src & "/one.txt", "dir/one.txt"));
      Entries.Append (Make_Source_Entry (Src & "/two.txt", "dir/two.txt"));
      Entries.Append
        (Make_Source_Entry
           (Src & "/nested/three.adb", "dir/nested/three.adb"));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "multiple stored entries and nested archive paths succeed");
      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         First_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 1);
         Second_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 2);
         Third_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 3);
         Eocd     : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0605_4B50#);
      begin
         Check
           (Count_Signature (Zip_Data, 16#0403_4B50#) = 3,
            "three local file headers are present");
         Check
           (Count_Signature (Zip_Data, 16#0201_4B50#) = 3,
            "three central directory headers are present");
         Check (U16_At (Zip_Data, Eocd + 10) = 3, "EOCD entry count is three");
         Check
           (U32_At (Zip_Data, Eocd + 16)
            = Unsigned_32 (First_Central - Zip_Data'First),
            "EOCD central directory offset points at first central header");
         Check
           (U32_At (Zip_Data, First_Central + 42) = 0,
            "first central offset points to first local header");
         Check
           (U32_At (Zip_Data, Second_Central + 42)
            = Unsigned_32 (Nth_Signature (Zip_Data, 16#0403_4B50#, 2)
                           - Zip_Data'First),
            "second central offset points to second local header");
         Check
           (U32_At (Zip_Data, Third_Central + 42)
            = Unsigned_32 (Nth_Signature (Zip_Data, 16#0403_4B50#, 3)
                           - Zip_Data'First),
            "third central offset points to third local header");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      First   : constant String := Root & "/deterministic-a.zip";
      Second  : constant String := Root & "/deterministic-b.zip";
   begin
      Entries.Append
        (Make_Source_Entry
           (Src & "/one.txt",
            "one.txt",
            Method => Backup.Zip.Deflated));
      Entries.Append
        (Make_Source_Entry
           (Src & "/nested/three.adb",
            "nested/three.adb",
            Method => Backup.Zip.Deflated));
      Check
        (Backup.Zip.Create_Archive (First, Entries) = Backup.Zip.Write_Ok,
         "first deterministic write succeeds");
      Check
        (Backup.Zip.Create_Archive (Second, Entries) = Backup.Zip.Write_Ok,
         "second deterministic write succeeds");
      Check
        (Equal_File (First, Second),
         "repeated output is deterministic for identical input");

      declare
         Zip_Data      : constant Stream_Element_Array := Read_All (First);
         First_Local   : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0403_4B50#, 1);
         Second_Local  : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0403_4B50#, 2);
         First_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 1);
         Second_Central : constant Stream_Element_Offset :=
           Nth_Signature (Zip_Data, 16#0201_4B50#, 2);
      begin
         Check
           (U16_At (Zip_Data, First_Local + 12) >= 33,
            "first local header has valid DOS date");
         Check
           (U16_At (Zip_Data, Second_Local + 12) >= 33,
            "second local header has valid DOS date");
         Check
           (U16_At (Zip_Data, First_Central + 12) =
            U16_At (Zip_Data, First_Local + 10),
            "first central DOS time matches local header");
         Check
           (U16_At (Zip_Data, First_Central + 14) =
            U16_At (Zip_Data, First_Local + 12),
            "first central DOS date matches local header");
         Check
           (U16_At (Zip_Data, Second_Central + 12) =
            U16_At (Zip_Data, Second_Local + 10),
            "second central DOS time matches local header");
         Check
           (U16_At (Zip_Data, Second_Central + 14) =
            U16_At (Zip_Data, Second_Local + 12),
            "second central DOS date matches local header");
         Check
           (U16_At (Zip_Data, First_Central + 36) = 1,
            "first central header marks text internal attributes");
         Check
           (U16_At (Zip_Data, Second_Central + 36) = 1,
            "second central header marks text internal attributes");
         Check
           ((U32_At (Zip_Data, First_Central + 38) and 16#F000_0000#) = 16#8000_0000#,
            "first central header records regular file type");
         Check
           ((U32_At (Zip_Data, Second_Central + 38) and 16#F000_0000#) = 16#8000_0000#,
            "second central header records regular file type");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/symlink.zip";
   begin
      Entries.Append (Make_Symlink_Entry ("links/current", "../target"));
      Check
        (Backup.Zip.Create_Archive (Output, Entries) = Backup.Zip.Write_Ok,
         "stored symlink ZIP entry creation succeeds");

      declare
         Zip_Data : constant Stream_Element_Array := Read_All (Output);
         Local    : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0403_4B50#);
         Central  : constant Stream_Element_Offset :=
           Find_Signature (Zip_Data, 16#0201_4B50#);
         Name_Len : constant Unsigned_16 := U16_At (Zip_Data, Local + 26);
         Extra_Len : constant Unsigned_16 := U16_At (Zip_Data, Local + 28);
         Payload  : constant Stream_Element_Offset :=
           Local + 30 + Stream_Element_Offset (Name_Len) +
           Stream_Element_Offset (Extra_Len);
      begin
         Check (U16_At (Zip_Data, Local + 8) = 0,
                "symlink ZIP entry uses stored method");
         Check (Central > 0, "symlink ZIP entry has central header");
         Check (U32_At (Zip_Data, Central + 38) = 16#A1FF_0000#,
                "symlink ZIP entry records Unix symlink attributes");
         Check
           (Zip_Data (Payload) = Stream_Element (Character'Pos ('.'))
            and then Zip_Data (Payload + 1) =
              Stream_Element (Character'Pos ('.')),
            "symlink ZIP payload stores target text");
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/symlink-deflate.zip";
   begin
      Entries.Append
        (Make_Symlink_Entry
           ("links/current", "../target", Backup.Zip.Deflated));
      Check
        (Backup.Zip.Create_Archive (Output, Entries)
         = Backup.Zip.Write_Unsupported_Entry,
         "deflated symlink ZIP entries are rejected explicitly");
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/duplicate.zip";
   begin
      Entries.Append (Make_Source_Entry (Src & "/one.txt", "same.txt"));
      Entries.Append (Make_Source_Entry (Src & "/two.txt", "same.txt"));
      Check
        (Backup.Zip.Create_Archive (Output, Entries)
         = Backup.Zip.Write_Duplicate_Archive_Path,
         "duplicate archive paths are rejected");
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Bad     : Backup.Zip.Source_Entry;
      Output  : constant String := Root & "/invalid.zip";
   begin
      Bad.Source_Path := Backup.Paths.Normalize_File_System_Path
        (Src & "/one.txt");
      Bad.Method := Backup.Zip.Stored;
      Entries.Append (Bad);
      Check
        (Backup.Zip.Create_Archive (Output, Entries)
         = Backup.Zip.Write_Invalid_Archive_Path,
         "invalid archive paths are rejected");
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/unreadable.zip";
   begin
      Entries.Append (Make_Source_Entry (Src & "/missing.txt", "missing.txt"));
      Check
        (Backup.Zip.Create_Archive (Output, Entries)
         = Backup.Zip.Write_Unreadable_Source,
         "unreadable source files are rejected explicitly");
   end;

   declare
      Entries   : Backup.Zip.Source_Entry_Vectors.Vector;
      Long_Name : constant String (1 .. Natural (Unsigned_16'Last) + 1) :=
        [others => 'a'];
      Output    : constant String := Root & "/name-too-long.zip";
   begin
      Entries.Append (Make_Generated_Entry (Long_Name));
      Check
        (Backup.Zip.Create_Archive (Output, Entries)
         = Backup.Zip.Write_Archive_Name_Too_Long,
         "archive path names longer than the ZIP 16-bit name field are rejected");
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Output  : constant String := Root & "/zip64-entry-count.zip";
   begin
      for Index in 1 .. Natural (Unsigned_16'Last) + 1 loop
         Entries.Append
           (Make_Generated_Entry
              ("many/" & Decimal_Natural (Index) & ".txt"));
      end loop;

      declare
         Status : constant Backup.Zip.Write_Result :=
           Backup.Zip.Create_Archive (Output, Entries);
      begin
         Check
           (Status = Backup.Zip.Write_Ok,
            "ZIP64 entry count archive creation succeeds");

         if Status = Backup.Zip.Write_Ok then
            declare
               Zip_Data : constant Stream_Element_Array := Read_All (Output);
               Zip64    : constant Stream_Element_Offset :=
                 Find_Signature (Zip_Data, 16#0606_4B50#);
               Locator  : constant Stream_Element_Offset :=
                 Find_Signature (Zip_Data, 16#0706_4B50#);
               Eocd     : constant Stream_Element_Offset :=
                 Find_Signature (Zip_Data, 16#0605_4B50#);
            begin
               Check (Zip64 > 0, "ZIP64 EOCD is emitted for large entry count");
               Check (Locator > 0, "ZIP64 EOCD locator is emitted");
               Check
                 (U64_At (Zip_Data, Zip64 + 24)
                  = Unsigned_64 (Unsigned_16'Last) + 1,
                  "ZIP64 total entry count is 64-bit");
               Check
                 (U16_At (Zip_Data, Eocd + 10) = 16#FFFF#,
                  "classic EOCD entry count uses ZIP64 sentinel");
               Check
                 (U64_At (Zip_Data, Locator + 8)
                  = Unsigned_64 (Zip64 - Zip_Data'First),
                  "ZIP64 locator points at ZIP64 EOCD");
            end;
         end if;
      end;
   end;

   declare
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      First   : constant String := Root & "/zip64-repeat-a.zip";
      Second  : constant String := Root & "/zip64-repeat-b.zip";
   begin
      for Index in 1 .. Natural (Unsigned_16'Last) + 1 loop
         Entries.Append
           (Make_Generated_Entry
              ("repeat/" & Decimal_Natural (Index) & ".txt"));
      end loop;

      declare
         First_Status  : constant Backup.Zip.Write_Result :=
           Backup.Zip.Create_Archive (First, Entries);
         Second_Status : constant Backup.Zip.Write_Result :=
           Backup.Zip.Create_Archive (Second, Entries);
      begin
         Check
           (First_Status = Backup.Zip.Write_Ok,
            "first deterministic ZIP64 archive generation succeeds");
         Check
           (Second_Status = Backup.Zip.Write_Ok,
            "second deterministic ZIP64 archive generation succeeds");
         if First_Status = Backup.Zip.Write_Ok
           and then Second_Status = Backup.Zip.Write_Ok
         then
            Check
              (Equal_File (First, Second),
               "repeated ZIP64 archive generation is byte-for-byte deterministic");
         end if;
      end;
   end;

   declare
      First_Source  : constant String := Src & "/zlib-zip-files-first.txt";
      Second_Source : constant String := Src & "/zlib-zip-files-second.txt";
      Output        : constant String := Root & "/zlib-zip-files.zip";
      Input_Paths   : constant Zlib.Text_Array :=
        [1 => Ada.Strings.Unbounded.To_Unbounded_String (First_Source),
         2 => Ada.Strings.Unbounded.To_Unbounded_String (Second_Source)];
      Entry_Names   : constant Zlib.Text_Array :=
        [1 => Ada.Strings.Unbounded.To_Unbounded_String ("first.txt"),
         2 => Ada.Strings.Unbounded.To_Unbounded_String ("nested/second.txt")];
      Status        : Zlib.Status_Code := Zlib.Ok;
   begin
      Write_Text (First_Source, "first through zlib ZIP_Files");
      Write_Text (Second_Source, "second through zlib ZIP_Files");

      Zlib.ZIP_Files
        (Input_Paths, Output, Entry_Names, Zlib.Stored, True, Status);
      Check (Status = Zlib.Ok, "backup can consume zlib ZIP_Files");

      if Status = Zlib.Ok then
         declare
            Zip_Data : constant Stream_Element_Array := Read_All (Output);
            Local    : constant Stream_Element_Offset :=
              Find_Signature (Zip_Data, 16#0403_4B50#);
            Zip64    : constant Stream_Element_Offset :=
              Find_Signature (Zip_Data, 16#0606_4B50#);
            Eocd     : constant Stream_Element_Offset :=
              Find_Signature (Zip_Data, 16#0605_4B50#);
         begin
            Check (Local > 0, "zlib ZIP_Files emits local header");
            Check
              (U16_At (Zip_Data, Local + 8) = 0,
               "zlib ZIP_Files stored method is visible to backup");
            Check (Zip64 > 0, "zlib ZIP_Files forced ZIP64 is visible");
            Check
              (U64_At (Zip_Data, Zip64 + 24) = 2,
               "zlib ZIP_Files ZIP64 entry count is visible");
            Check
              (U16_At (Zip_Data, Eocd + 10) = 16#FFFF#,
               "zlib ZIP_Files fallback EOCD uses ZIP64 sentinel");
         end;
      end if;
   end;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup ZIP tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup ZIP test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Zip_Tests;
