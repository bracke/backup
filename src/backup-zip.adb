with Ada.Containers;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with CryptoLib.Checksums;
with Hostkit.Fs;
with GNAT.OS_Lib;
with Zlib;

with Backup.Platform;

package body Backup.Zip is

   use Ada.Streams;
   use Ada.Streams.Stream_IO;
   use Interfaces;
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Ada.Directories.File_Size;
   use type Backup.Paths.Validation_Status;
   use type Zlib.Status_Code;

   Zip32_Max : constant Unsigned_64 := 16#FFFF_FFFF#;
   Chunk_Size : constant Stream_Element_Count := 16#4000#;
   Metadata_Extra_Id : constant Unsigned_16 := 16#BACE#;

   Dos_Time_Normalized : constant Unsigned_16 := 0;
   Dos_Date_Normalized : constant Unsigned_16 := 33;

   type Central_Record is record
      Archive_Path        : Backup.Paths.Archive_Path;
      Method              : Compression_Method := Stored;
      Crc32               : Unsigned_32 := 0;
      Compressed_Size     : Unsigned_64 := 0;
      Uncompressed_Size   : Unsigned_64 := 0;
      Local_Header_Offset : Unsigned_64 := 0;
      Kind                : Source_Kind := Source_File;
      Dos_Time            : Unsigned_16 := Dos_Time_Normalized;
      Dos_Date            : Unsigned_16 := Dos_Date_Normalized;
      External_Attrs      : Unsigned_32 := 0;
      Internal_Attrs      : Unsigned_16 := 0;
      Has_Owner           : Boolean := False;
      Owner_UID           : Unsigned_32 := 0;
      Owner_GID           : Unsigned_32 := 0;
      Xattr_Blob          : Unbounded_String := Null_Unbounded_String;
   end record;

   package Central_Record_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Central_Record);

   function Low_Byte (Value : Unsigned_32) return Stream_Element is
   begin
      return Stream_Element (Value and 16#FF#);
   end Low_Byte;

   function Method_Number (Method : Compression_Method) return Unsigned_16 is
   begin
      case Method is
         when Stored =>
            return 0;
         when Deflated =>
            return 8;
         when BZip2 =>
            return 12;
         when LZMA =>
            return 14;
         when Zstd =>
            return 93;
      end case;
   end Method_Number;

   function General_Purpose_Flags
     (Method              : Compression_Method;
      Use_Data_Descriptor : Boolean) return Unsigned_16
   is
      Flags : Unsigned_16 := 0;
   begin
      if Method = LZMA then
         --  ZIP LZMA payloads produced by 7z use bit 1 to advertise the EOS
         --  marker.  Preserve that method-level contract when rewrapping the
         --  compressed member payload into backup's archive writer.
         Flags := Flags or 2;
      end if;

      if Use_Data_Descriptor then
         Flags := Flags or 8;
      end if;

      return Flags;
   end General_Purpose_Flags;


   procedure Dos_Time_And_Date
     (Path     : Backup.Paths.File_System_Path;
      Kind     : Source_Kind;
      Dos_Time : out Unsigned_16;
      Dos_Date : out Unsigned_16)
   is
      Stamp : GNAT.OS_Lib.OS_Time;
      Year  : GNAT.OS_Lib.Year_Type;
      Month : GNAT.OS_Lib.Month_Type;
      Day   : GNAT.OS_Lib.Day_Type;
      Hour  : GNAT.OS_Lib.Hour_Type;
      Min   : GNAT.OS_Lib.Minute_Type;
      Sec   : GNAT.OS_Lib.Second_Type;
   begin
      Dos_Time := Dos_Time_Normalized;
      Dos_Date := Dos_Date_Normalized;
      if Kind /= Source_File then
         return;
      end if;

      Stamp := GNAT.OS_Lib.File_Time_Stamp (Backup.Paths.To_String (Path));
      GNAT.OS_Lib.GM_Split (Stamp, Year, Month, Day, Hour, Min, Sec);
      Dos_Time :=
        Shift_Left (Unsigned_16 (Hour), 11)
        or Shift_Left (Unsigned_16 (Min), 5)
        or Unsigned_16 (Sec / 2);
      Dos_Date :=
        Shift_Left (Unsigned_16 (Year - 1980), 9)
        or Shift_Left (Unsigned_16 (Month), 5)
        or Unsigned_16 (Day);
   exception
      when others =>
         Dos_Time := Dos_Time_Normalized;
         Dos_Date := Dos_Date_Normalized;
   end Dos_Time_And_Date;

   function External_Attributes
     (Path : Backup.Paths.File_System_Path;
      Kind : Source_Kind)
      return Unsigned_32
   is
      Unix_Mode : Unsigned_32;
   begin
      case Kind is
         when Source_Symlink =>
            Unix_Mode := 16#A1FF#;
         when Source_File =>
            Unix_Mode :=
              (if Hostkit.Fs.Is_Executable (Backup.Paths.To_String (Path)) then
                  16#81ED#
               else
                  16#81A4#);
         when Source_Generated =>
            Unix_Mode := 16#81A4#;
      end case;
      return Shift_Left (Unix_Mode, 16);
   exception
      when others =>
         return 0;
   end External_Attributes;

   function Byte_Is_Text (Value : Stream_Element) return Boolean is
   begin
      return Value = 9
        or else Value = 10
        or else Value = 13
        or else (Value >= 32 and then Value < 127);
   end Byte_Is_Text;

   function Text_Internal_Attributes (Is_Text : Boolean) return Unsigned_16 is
   begin
      return (if Is_Text then 1 else 0);
   end Text_Internal_Attributes;

   function Content_Internal_Attributes (Content : Unbounded_String)
      return Unsigned_16
   is
      Text : constant String := To_String (Content);
   begin
      for Ch of Text loop
         if not Byte_Is_Text (Stream_Element (Character'Pos (Ch))) then
            return Text_Internal_Attributes (False);
         end if;
      end loop;
      return Text_Internal_Attributes (True);
   end Content_Internal_Attributes;

   function Source_Internal_Attributes
     (Path : Backup.Paths.File_System_Path;
      Kind : Source_Kind)
      return Unsigned_16
   is
      Input  : File_Type;
      Buffer : Stream_Element_Array (1 .. Chunk_Size);
      Last   : Stream_Element_Offset;
      Opened : Boolean := False;
   begin
      if Kind /= Source_File then
         return 0;
      end if;

      Open (Input, In_File, Backup.Paths.To_String (Path));
      Opened := True;
      while not End_Of_File (Input) loop
         Read (Input, Buffer, Last);
         if Last >= Buffer'First then
            for I in Buffer'First .. Last loop
               if not Byte_Is_Text (Buffer (I)) then
                  Close (Input);
                  return Text_Internal_Attributes (False);
               end if;
            end loop;
         end if;
      end loop;
      Close (Input);
      return Text_Internal_Attributes (True);
   exception
      when others =>
         if Opened then
            begin
               Close (Input);
            exception
               when others =>
                  null;
            end;
         end if;
         return 0;
   end Source_Internal_Attributes;

   procedure Write_U16
     (File  : in out File_Type;
      Value : Unsigned_16)
   is
      Bytes : Stream_Element_Array (1 .. 2);
   begin
      Bytes (1) := Low_Byte (Unsigned_32 (Value));
      Bytes (2) := Low_Byte (Shift_Right (Unsigned_32 (Value), 8));
      Write (File, Bytes);
   end Write_U16;

   procedure Write_U32
     (File  : in out File_Type;
      Value : Unsigned_32)
   is
      Bytes : Stream_Element_Array (1 .. 4);
   begin
      Bytes (1) := Low_Byte (Value);
      Bytes (2) := Low_Byte (Shift_Right (Value, 8));
      Bytes (3) := Low_Byte (Shift_Right (Value, 16));
      Bytes (4) := Low_Byte (Shift_Right (Value, 24));
      Write (File, Bytes);
   end Write_U32;

   procedure Write_U64
     (File  : in out File_Type;
      Value : Unsigned_64)
   is
   begin
      Write_U32 (File, Unsigned_32 (Value and 16#FFFF_FFFF#));
      Write_U32 (File, Unsigned_32 (Shift_Right (Value, 32)));
   end Write_U64;

   function Zip32_Size_Field (Value : Unsigned_64) return Unsigned_32 is
   begin
      if Value > Zip32_Max then
         return 16#FFFF_FFFF#;
      else
         return Unsigned_32 (Value);
      end if;
   end Zip32_Size_Field;

   function Zip32_Count_Field
     (Value : Ada.Containers.Count_Type) return Unsigned_16
   is
   begin
      if Value > Ada.Containers.Count_Type (Unsigned_16'Last) then
         return 16#FFFF#;
      else
         return Unsigned_16 (Value);
      end if;
   end Zip32_Count_Field;

   procedure Write_Name
     (File : in out File_Type;
      Name : String)
   is
      Bytes : Stream_Element_Array (1 .. Stream_Element_Offset (Name'Length));
      Pos   : Stream_Element_Offset := Bytes'First;
   begin
      for Ch of Name loop
         Bytes (Pos) := Stream_Element (Character'Pos (Ch));
         Pos := Pos + 1;
      end loop;
      Write (File, Bytes);
   end Write_Name;

   function Current_Offset (File : File_Type) return Unsigned_64 is
   begin
      return Unsigned_64 (Index (File) - 1);
   end Current_Offset;

   function Analyze_Source
     (Path : Backup.Paths.File_System_Path;
      Crc  : out Unsigned_32;
      Size : out Unsigned_64)
      return Write_Result
   is
      Input  : File_Type;
      Buffer : Stream_Element_Array (1 .. Chunk_Size);
      Last   : Stream_Element_Offset;
      Opened : Boolean := False;
      Crc_State : CryptoLib.Checksums.CRC32_State;
   begin
      Crc := 0;
      Size := 0;

      if not GNAT.OS_Lib.Is_Readable_File (Backup.Paths.To_String (Path)) then
         return Write_Unreadable_Source;
      end if;

      CryptoLib.Checksums.CRC32_Reset (Crc_State);
      Open (Input, In_File, Backup.Paths.To_String (Path));
      Opened := True;
      while not End_Of_File (Input) loop
         Read (Input, Buffer, Last);
         if Last >= Buffer'First then
            CryptoLib.Checksums.CRC32_Update (Crc_State, Buffer (Buffer'First .. Last));
            Size := Size + Unsigned_64 (Last - Buffer'First + 1);
         end if;
      end loop;
      Close (Input);

      Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
      return Write_Ok;
   exception
      when others =>
         if Opened then
            begin
               Close (Input);
            exception
               when others =>
                  null;
            end;
         end if;
         return Write_Unreadable_Source;
   end Analyze_Source;


   function Analyze_Content
     (Content : Unbounded_String;
      Crc     : out Unsigned_32;
      Size    : out Unsigned_64)
      return Write_Result
   is
      Text      : constant String := To_String (Content);
      Crc_State : CryptoLib.Checksums.CRC32_State;
   begin
      Crc := 0;
      Size := Unsigned_64 (Text'Length);
      if Text'Length = 0 then
         Crc := 0;
         return Write_Ok;
      end if;

      declare
         Buffer : Stream_Element_Array
           (1 .. Stream_Element_Offset (Text'Length));
         Pos    : Stream_Element_Offset := Buffer'First;
      begin
         for Ch of Text loop
            Buffer (Pos) := Stream_Element (Character'Pos (Ch));
            Pos := Pos + 1;
         end loop;
         CryptoLib.Checksums.CRC32_Reset (Crc_State);
         CryptoLib.Checksums.CRC32_Update (Crc_State, Buffer);
      end;
      Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
      return Write_Ok;
   end Analyze_Content;

   function Analyze_File
     (Path : Backup.Paths.File_System_Path;
      Crc  : out Unsigned_32;
      Size : out Unsigned_64)
      return Write_Result
   is
   begin
      return Analyze_Source (Path, Crc, Size);
   end Analyze_File;

   function Crc32_Of_File
     (Path : Backup.Paths.File_System_Path)
      return Unsigned_32
   is
      Crc    : Unsigned_32;
      Size   : Unsigned_64;
      Status : constant Write_Result := Analyze_File (Path, Crc, Size);
      pragma Unreferenced (Size);
   begin
      if Status = Write_Ok then
         return Crc;
      else
         return 0;
      end if;
   end Crc32_Of_File;

   function Crc32_Of_Text
     (Text : Unbounded_String)
      return Unsigned_32
   is
      Source : constant String := To_String (Text);
   begin
      if Source'Length = 0 then
         return 0;
      end if;

      declare
         Bytes : Stream_Element_Array
           (1 .. Stream_Element_Offset (Source'Length));
         State : CryptoLib.Checksums.CRC32_State;
      begin
         for I in Bytes'Range loop
            Bytes (I) :=
              Stream_Element
                (Character'Pos (Source (Source'First + Natural (I) - 1)));
         end loop;
         CryptoLib.Checksums.CRC32_Reset (State);
         CryptoLib.Checksums.CRC32_Update (State, Bytes);
         return CryptoLib.Checksums.CRC32_Value (State);
      end;
   end Crc32_Of_Text;

   function Copy_Content
     (Content : Unbounded_String;
      Output  : in out File_Type)
      return Write_Result
   is
      Text : constant String := To_String (Content);
   begin
      if Text'Length = 0 then
         return Write_Ok;
      end if;

      declare
         Bytes : Stream_Element_Array
           (1 .. Stream_Element_Offset (Text'Length));
         Pos   : Stream_Element_Offset := Bytes'First;
      begin
         for Ch of Text loop
            Bytes (Pos) := Stream_Element (Character'Pos (Ch));
            Pos := Pos + 1;
         end loop;
         Write (Output, Bytes);
      end;
      return Write_Ok;
   exception
      when others =>
         return Write_Output_Error;
   end Copy_Content;

   function Copy_Source
     (Path   : Backup.Paths.File_System_Path;
      Output : in out File_Type)
      return Write_Result
   is
      Input   : File_Type;
      Buffer  : Stream_Element_Array (1 .. Chunk_Size);
      Last    : Stream_Element_Offset;
      Opened  : Boolean := False;
      Writing : Boolean := False;
   begin
      Open (Input, In_File, Backup.Paths.To_String (Path));
      Opened := True;
      while not End_Of_File (Input) loop
         Read (Input, Buffer, Last);
         if Last >= Buffer'First then
            Writing := True;
            Write (Output, Buffer (Buffer'First .. Last));
            Writing := False;
         end if;
      end loop;
      Close (Input);
      return Write_Ok;
   exception
      when others =>
         if Opened then
            begin
               Close (Input);
            exception
               when others =>
                  null;
            end;
         end if;

         if Writing then
            return Write_Output_Error;
         else
            return Write_Unreadable_Source;
         end if;
   end Copy_Source;

   function Copy_Source_Deflated
     (Path            : Backup.Paths.File_System_Path;
      Output          : in out File_Type;
      Compressed_Size : out Unsigned_64)
      return Write_Result
   is
      Status : Zlib.Status_Code := Zlib.Ok;
   begin
      Zlib.Deflate_Raw_File_To_Stream
        (Input_Path      => Backup.Paths.To_String (Path),
         Output          => Output,
         Mode            => Zlib.Auto,
         Compressed_Size => Compressed_Size,
         Status          => Status);

      case Status is
         when Zlib.Ok =>
            return Write_Ok;
         when Zlib.Input_File_Error =>
            return Write_Unreadable_Source;
         when Zlib.Output_File_Error =>
            return Write_Compression_Failed;
         when others =>
            return Write_Compression_Failed;
      end case;
   end Copy_Source_Deflated;

   function Copy_Prepared_Deflated
     (Payload_Path    : String;
      Output          : in out File_Type;
      Compressed_Size : Unsigned_64)
      return Write_Result
   is
      Payload : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (Payload_Path);
      Status  : constant Write_Result := Copy_Source (Payload, Output);
   begin
      if Status /= Write_Ok then
         return Status;
      end if;

      if Ada.Directories.Size (Payload_Path) /=
        Ada.Directories.File_Size (Compressed_Size)
      then
         return Write_Compression_Failed;
      end if;

      return Write_Ok;
   exception
      when others =>
         return Write_Compression_Failed;
   end Copy_Prepared_Deflated;

   function Write_Zlib_Bytes
     (Data   : Zlib.Byte_Array;
      Output : in out File_Type) return Write_Result
   is
   begin
      if Data'Length = 0 then
         return Write_Ok;
      end if;

      declare
         Buffer : Stream_Element_Array
           (1 .. Stream_Element_Offset (Data'Length));
      begin
         for I in Data'Range loop
            Buffer (Stream_Element_Offset (I - Data'First + 1)) :=
              Stream_Element (Data (I));
         end loop;
         Write (Output, Buffer);
      end;
      return Write_Ok;
   exception
      when others =>
         return Write_Output_Error;
   end Write_Zlib_Bytes;

   function Copy_Source_External
     (Path              : Backup.Paths.File_System_Path;
      Method_Kind       : Compression_Method;
      Output            : in out File_Type;
      Crc               : out Unsigned_32;
      Uncompressed_Size : out Unsigned_64;
      Compressed_Size   : out Unsigned_64)
      return Write_Result
   is
      Status : Zlib.Status_Code := Zlib.Ok;
      Method : Unsigned_16 := 0;
      Requested_Method : constant Unsigned_16 := Method_Number (Method_Kind);
      Method_Name : constant String :=
        Zlib.ZIP_External_Method_Name (Requested_Method);
      Payload : constant Zlib.Byte_Array :=
        Zlib.Compress_ZIP_External_File
          (Input_Path        => Backup.Paths.To_String (Path),
           Method_Name       => Method_Name,
           Method            => Method,
           Crc32             => Crc,
           Uncompressed_Size => Uncompressed_Size,
           Status            => Status);
   begin
      if not Zlib.Is_ZIP_External_Method (Requested_Method)
        or else Status /= Zlib.Ok
        or else Method_Name = ""
        or else Method /= Requested_Method
      then
         Compressed_Size := 0;
         return
           (if Status = Zlib.Input_File_Error then
               Write_Unreadable_Source
            else
               Write_Compression_Failed);
      end if;

      Compressed_Size := Unsigned_64 (Payload'Length);
      return Write_Zlib_Bytes (Payload, Output);
   end Copy_Source_External;

   function Name_Is_Valid (Name : String) return Boolean is
      Status : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Validate_Archive_Fragment (Name);
   begin
      return Status = Backup.Paths.Valid;
   end Name_Is_Valid;

   function Name_Length_U16 (Name : String) return Unsigned_16 is
   begin
      pragma Assert
        (Name'Length <= Natural (Unsigned_16'Last),
         "ZIP filename length fits in 16 bits");
      return Unsigned_16 (Name'Length);
   end Name_Length_U16;

   function Needs_Zip64_Size
     (Compressed_Size   : Unsigned_64;
      Uncompressed_Size : Unsigned_64)
      return Boolean
   is
   begin
      return Compressed_Size > Zip32_Max
        or else Uncompressed_Size > Zip32_Max;
   end Needs_Zip64_Size;

   function Needs_Zip64_Central (Item : Central_Record) return Boolean is
   begin
      return Needs_Zip64_Size (Item.Compressed_Size, Item.Uncompressed_Size)
        or else Item.Local_Header_Offset > Zip32_Max;
   end Needs_Zip64_Central;

   procedure Write_Local_Zip64_Extra
     (Output            : in out File_Type;
      Compressed_Size   : Unsigned_64;
      Uncompressed_Size : Unsigned_64)
   is
   begin
      Write_U16 (Output, 16#0001#);
      Write_U16 (Output, 16);
      Write_U64 (Output, Uncompressed_Size);
      Write_U64 (Output, Compressed_Size);
   end Write_Local_Zip64_Extra;

   procedure Write_Central_Zip64_Extra
     (Output : in out File_Type;
      Item   : Central_Record)
   is
      Payload_Length : Unsigned_16 := 0;
   begin
      if Item.Uncompressed_Size > Zip32_Max then
         Payload_Length := Payload_Length + 8;
      end if;
      if Item.Compressed_Size > Zip32_Max then
         Payload_Length := Payload_Length + 8;
      end if;
      if Item.Local_Header_Offset > Zip32_Max then
         Payload_Length := Payload_Length + 8;
      end if;

      pragma Assert
        (Payload_Length > 0,
         "ZIP64 central extra field is only written when needed");

      Write_U16 (Output, 16#0001#);
      Write_U16 (Output, Payload_Length);
      if Item.Uncompressed_Size > Zip32_Max then
         Write_U64 (Output, Item.Uncompressed_Size);
      end if;
      if Item.Compressed_Size > Zip32_Max then
         Write_U64 (Output, Item.Compressed_Size);
      end if;
      if Item.Local_Header_Offset > Zip32_Max then
         Write_U64 (Output, Item.Local_Header_Offset);
      end if;
   end Write_Central_Zip64_Extra;


   procedure Append_U16
     (Text  : in out Unbounded_String;
      Value : Unsigned_16)
   is
   begin
      Append (Text, Character'Val (Integer (Value and 16#00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 8))));
   end Append_U16;

   procedure Append_U32
     (Text  : in out Unbounded_String;
      Value : Unsigned_32)
   is
   begin
      Append (Text, Character'Val (Integer (Value and 16#0000_00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 8) and 16#0000_00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 16) and 16#0000_00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 24) and 16#0000_00FF#)));
   end Append_U32;

   function Metadata_Blob (Item : Central_Record) return Unbounded_String is
      Result : Unbounded_String;
      Flags  : Unsigned_16 := 0;
      Xattrs : constant String := To_String (Item.Xattr_Blob);
   begin
      if Item.Has_Owner then
         Flags := Flags or 1;
      end if;
      if Xattrs'Length > 0 then
         Flags := Flags or 2;
      end if;
      if Flags = 0 then
         return Null_Unbounded_String;
      end if;

      Append_U32 (Result, 16#444D_4B42#);
      Append_U16 (Result, 1);
      Append_U16 (Result, Flags);
      Append_U32 (Result, Item.Owner_UID);
      Append_U32 (Result, Item.Owner_GID);
      if Xattrs'Length > 0 then
         Append (Result, Xattrs);
      end if;
      return Result;
   end Metadata_Blob;

   function Metadata_Extra_Length (Item : Central_Record) return Unsigned_16 is
      Data_Length : constant Natural := Length (Metadata_Blob (Item));
   begin
      if Data_Length = 0 or else Data_Length > Natural (Unsigned_16'Last - 4) then
         return 0;
      end if;
      return Unsigned_16 (Data_Length + 4);
   end Metadata_Extra_Length;

   procedure Write_Metadata_Extra
     (Output : in out File_Type;
      Item   : Central_Record)
   is
      Data : constant String := To_String (Metadata_Blob (Item));
      Bytes : Stream_Element_Array (1 .. Stream_Element_Offset (Data'Length));
      Pos : Stream_Element_Offset := Bytes'First;
   begin
      if Data'Length = 0 or else Data'Length > Natural (Unsigned_16'Last - 4) then
         return;
      end if;

      Write_U16 (Output, Metadata_Extra_Id);
      Write_U16 (Output, Unsigned_16 (Data'Length));
      for Ch of Data loop
         Bytes (Pos) := Stream_Element (Character'Pos (Ch));
         Pos := Pos + 1;
      end loop;
      Write (Output, Bytes);
   end Write_Metadata_Extra;

   procedure Write_Local_Header
     (Output              : in out File_Type;
      Name                : String;
      Crc                 : Unsigned_32;
      Method              : Compression_Method;
      Compressed_Size     : Unsigned_64;
      Uncompressed_Size   : Unsigned_64;
      Dos_Time            : Unsigned_16;
      Dos_Date            : Unsigned_16;
      Use_Data_Descriptor : Boolean)
   is
      Use_Zip64 : constant Boolean :=
        Needs_Zip64_Size (Compressed_Size, Uncompressed_Size);
      Extra_Length : constant Unsigned_16 :=
        (if Use_Zip64 then
           20
         else
           0);
   begin
      Write_U32 (Output, 16#0403_4B50#);
      Write_U16 (Output, (if Use_Zip64 then
                            45
                         else
                            20));
      Write_U16 (Output, General_Purpose_Flags (Method, Use_Data_Descriptor));
      Write_U16 (Output, Method_Number (Method));
      Write_U16 (Output, Dos_Time);
      Write_U16 (Output, Dos_Date);
      Write_U32 (Output, (if Use_Data_Descriptor then 0 else Crc));
      Write_U32
        (Output,
         (if Use_Data_Descriptor then
            0
          elsif Use_Zip64 then
            16#FFFF_FFFF#
          else
            Zip32_Size_Field (Compressed_Size)));
      Write_U32
        (Output,
         (if Use_Data_Descriptor then
            0
          elsif Use_Zip64 then
            16#FFFF_FFFF#
          else
            Zip32_Size_Field (Uncompressed_Size)));
      Write_U16 (Output, Name_Length_U16 (Name));
      Write_U16 (Output, Extra_Length);
      Write_Name (Output, Name);
      if Use_Zip64 and then not Use_Data_Descriptor then
         Write_Local_Zip64_Extra
           (Output, Compressed_Size, Uncompressed_Size);
      end if;
   end Write_Local_Header;

   procedure Write_Data_Descriptor
     (Output            : in out File_Type;
      Crc               : Unsigned_32;
      Compressed_Size   : Unsigned_64;
      Uncompressed_Size : Unsigned_64)
   is
      Use_Zip64 : constant Boolean :=
        Needs_Zip64_Size (Compressed_Size, Uncompressed_Size);
   begin
      Write_U32 (Output, 16#0807_4B50#);
      Write_U32 (Output, Crc);
      if Use_Zip64 then
         Write_U64 (Output, Compressed_Size);
         Write_U64 (Output, Uncompressed_Size);
      else
         Write_U32 (Output, Zip32_Size_Field (Compressed_Size));
         Write_U32 (Output, Zip32_Size_Field (Uncompressed_Size));
      end if;
   end Write_Data_Descriptor;

   procedure Write_Central_Header
     (Output : in out File_Type;
      Item   : Central_Record)
   is
      Name      : constant String := Backup.Paths.To_String (Item.Archive_Path);
      Use_Zip64 : constant Boolean := Needs_Zip64_Central (Item);
      Extra_Length : Unsigned_16 := Metadata_Extra_Length (Item);
      Version_Made_By : constant Unsigned_16 :=
        (if Item.Kind = Source_Symlink then
           16#031E#
         else
           20);
   begin
      if Use_Zip64 then
         Extra_Length := Extra_Length + 4;
         if Item.Uncompressed_Size > Zip32_Max then
            Extra_Length := Extra_Length + 8;
         end if;
         if Item.Compressed_Size > Zip32_Max then
            Extra_Length := Extra_Length + 8;
         end if;
         if Item.Local_Header_Offset > Zip32_Max then
            Extra_Length := Extra_Length + 8;
         end if;
      end if;

      Write_U32 (Output, 16#0201_4B50#);
      Write_U16 (Output, Version_Made_By);
      Write_U16 (Output, (if Use_Zip64 then
                            45
                         else
                            20));
      Write_U16
        (Output, General_Purpose_Flags (Item.Method, Item.Method /= Stored));
      Write_U16 (Output, Method_Number (Item.Method));
      Write_U16 (Output, Item.Dos_Time);
      Write_U16 (Output, Item.Dos_Date);
      Write_U32 (Output, Item.Crc32);
      Write_U32 (Output, Zip32_Size_Field (Item.Compressed_Size));
      Write_U32 (Output, Zip32_Size_Field (Item.Uncompressed_Size));
      Write_U16 (Output, Name_Length_U16 (Name));
      Write_U16 (Output, Extra_Length);
      Write_U16 (Output, 0);
      Write_U16 (Output, 0);
      Write_U16 (Output, Item.Internal_Attrs);
      Write_U32 (Output, Item.External_Attrs);
      Write_U32 (Output, Zip32_Size_Field (Item.Local_Header_Offset));
      Write_Name (Output, Name);
      if Use_Zip64 then
         Write_Central_Zip64_Extra (Output, Item);
      end if;
      Write_Metadata_Extra (Output, Item);
   end Write_Central_Header;

   procedure Write_Zip64_End_Record
     (Output               : in out File_Type;
      Entry_Count          : Unsigned_64;
      Central_Size         : Unsigned_64;
      Central_Start_Offset : Unsigned_64)
   is
   begin
      Write_U32 (Output, 16#0606_4B50#);
      Write_U64 (Output, 44);
      Write_U16 (Output, 45);
      Write_U16 (Output, 45);
      Write_U32 (Output, 0);
      Write_U32 (Output, 0);
      Write_U64 (Output, Entry_Count);
      Write_U64 (Output, Entry_Count);
      Write_U64 (Output, Central_Size);
      Write_U64 (Output, Central_Start_Offset);
   end Write_Zip64_End_Record;

   procedure Write_Zip64_Locator
     (Output                  : in out File_Type;
      Zip64_End_Record_Offset : Unsigned_64)
   is
   begin
      Write_U32 (Output, 16#0706_4B50#);
      Write_U32 (Output, 0);
      Write_U64 (Output, Zip64_End_Record_Offset);
      Write_U32 (Output, 1);
   end Write_Zip64_Locator;

   procedure Write_End_Record
     (Output               : in out File_Type;
      Entry_Count          : Ada.Containers.Count_Type;
      Central_Size         : Unsigned_64;
      Central_Start_Offset : Unsigned_64;
      Has_Zip64_Entry      : Boolean)
   is
      Use_Zip64 : constant Boolean :=
        Has_Zip64_Entry
        or else Entry_Count > Ada.Containers.Count_Type (Unsigned_16'Last)
        or else Central_Size > Zip32_Max
        or else Central_Start_Offset > Zip32_Max;
      Zip64_End_Offset : Unsigned_64;
   begin
      if Use_Zip64 then
         Zip64_End_Offset := Current_Offset (Output);
         Write_Zip64_End_Record
           (Output,
            Unsigned_64 (Entry_Count),
            Central_Size,
            Central_Start_Offset);
         Write_Zip64_Locator (Output, Zip64_End_Offset);
      end if;

      Write_U32 (Output, 16#0605_4B50#);
      Write_U16 (Output, 0);
      Write_U16 (Output, 0);
      Write_U16 (Output, Zip32_Count_Field (Entry_Count));
      Write_U16 (Output, Zip32_Count_Field (Entry_Count));
      Write_U32 (Output, Zip32_Size_Field (Central_Size));
      Write_U32 (Output, Zip32_Size_Field (Central_Start_Offset));
      Write_U16 (Output, 0);
   end Write_End_Record;

   function Create_Archive
     (Output_Path : String;
      Entries     : Source_Entry_Vectors.Vector)
      return Write_Result
   is
      Output          : File_Type;
      Output_Open     : Boolean := False;
      Seen            : Backup.Paths.Archive_Path_Sets.Set;
      Central         : Central_Record_Vectors.Vector;
      Central_Start   : Unsigned_64;
      Central_Size    : Unsigned_64;
      Status          : Write_Result;
      Has_Zip64_Entry : Boolean := False;
   begin
      for Item of Entries loop
         declare
            Name : constant String :=
              Backup.Paths.To_String (Item.Archive_Path);
         begin
            if not Name_Is_Valid (Name) then
               return Write_Invalid_Archive_Path;
            end if;

            if Name'Length > Natural (Unsigned_16'Last) then
               return Write_Archive_Name_Too_Long;
            end if;

            if Item.Kind = Source_Symlink and then Item.Method /= Stored then
               return Write_Unsupported_Entry;
            end if;

            if not Backup.Paths.Insert_Archive_Path
              (Seen, Item.Archive_Path)
            then
               return Write_Duplicate_Archive_Path;
            end if;
         end;
      end loop;

      Create (Output, Out_File, Output_Path);
      Output_Open := True;

      for Item of Entries loop
         declare
            Crc         : Unsigned_32;
            Size_64            : Unsigned_64;
            Offset_64          : constant Unsigned_64 :=
              Current_Offset (Output);
            Name               : constant String :=
              Backup.Paths.To_String (Item.Archive_Path);
            Compressed_Size_64 : Unsigned_64;
            Entry_Dos_Time     : Unsigned_16;
            Entry_Dos_Date     : Unsigned_16;
            Entry_External     : Unsigned_32;
            Entry_Has_Owner    : Boolean;
            Entry_UID          : Unsigned_32;
            Entry_GID          : Unsigned_32;
            Entry_Internal     : Unsigned_16;
            Entry_Xattrs       : Unbounded_String;
         begin
            if Item.Generated or else Item.Kind /= Source_File then
               Status := Analyze_Content (Item.Content, Crc, Size_64);
            else
               Status := Analyze_Source (Item.Source_Path, Crc, Size_64);
            end if;
            if Status /= Write_Ok then
               Close (Output);
               return Status;
            end if;

            if Item.Method = Stored then
               Compressed_Size_64 := Size_64;
            elsif Item.Has_Prepared_Payload then
               Compressed_Size_64 := Item.Prepared_Compressed_Size;
            else
               Compressed_Size_64 := 0;
            end if;

            Dos_Time_And_Date
              (Item.Source_Path, Item.Kind, Entry_Dos_Time, Entry_Dos_Date);
            Entry_External := External_Attributes (Item.Source_Path, Item.Kind);
            if Item.Generated or else Item.Kind /= Source_File then
               Entry_Internal := Content_Internal_Attributes (Item.Content);
            else
               Entry_Internal :=
                 Source_Internal_Attributes (Item.Source_Path, Item.Kind);
            end if;
            if Item.Kind = Source_File then
               Backup.Platform.Owner_Ids
                 (Backup.Paths.To_String (Item.Source_Path),
                  Entry_Has_Owner, Entry_UID, Entry_GID);
               Entry_Xattrs := Backup.Platform.Xattr_Blob
                 (Backup.Paths.To_String (Item.Source_Path));
            else
               Entry_Has_Owner := False;
               Entry_UID := 0;
               Entry_GID := 0;
               Entry_Xattrs := Null_Unbounded_String;
            end if;

            Write_Local_Header
              (Output, Name, Crc, Item.Method,
               Compressed_Size_64, Size_64,
               Entry_Dos_Time, Entry_Dos_Date,
               Use_Data_Descriptor => Item.Method /= Stored);
            if Item.Method = Stored then
               if Item.Generated or else Item.Kind /= Source_File then
                  Status := Copy_Content (Item.Content, Output);
               else
                  Status := Copy_Source (Item.Source_Path, Output);
               end if;
            else
               if Item.Generated then
                  Close (Output);
                  return Write_Unsupported_Entry;
               end if;

               case Item.Method is
                  when Stored =>
                     Status := Write_Ok;
                  when Deflated =>
                     if Item.Has_Prepared_Payload then
                        Status := Copy_Prepared_Deflated
                          (To_String (Item.Prepared_Payload_Path), Output,
                           Compressed_Size_64);
                     else
                        Status := Copy_Source_Deflated
                          (Item.Source_Path, Output, Compressed_Size_64);
                     end if;
                  when BZip2 | LZMA | Zstd =>
                     if Item.Has_Prepared_Payload then
                        Close (Output);
                        return Write_Unsupported_Entry;
                     end if;
                     Status := Copy_Source_External
                       (Item.Source_Path, Item.Method, Output, Crc,
                        Size_64, Compressed_Size_64);
               end case;

               if Status = Write_Ok then
                  Write_Data_Descriptor
                    (Output, Crc, Compressed_Size_64, Size_64);
               end if;
            end if;
            if Status /= Write_Ok then
               Close (Output);
               return Status;
            end if;

            if Needs_Zip64_Size (Compressed_Size_64, Size_64)
              or else Offset_64 > Zip32_Max
            then
               Has_Zip64_Entry := True;
            end if;

            Central.Append
              (Central_Record'(Archive_Path        => Item.Archive_Path,
                Method              => Item.Method,
                Crc32               => Crc,
                Compressed_Size     => Compressed_Size_64,
                Uncompressed_Size   => Size_64,
                Local_Header_Offset => Offset_64,
                Kind                => Item.Kind,
                Dos_Time            => Entry_Dos_Time,
                Dos_Date            => Entry_Dos_Date,
                External_Attrs      => Entry_External,
                Internal_Attrs      => Entry_Internal,
                Has_Owner           => Entry_Has_Owner,
                Owner_UID           => Entry_UID,
                Owner_GID           => Entry_GID,
                Xattr_Blob          => Entry_Xattrs));
         end;
      end loop;

      Central_Start := Current_Offset (Output);
      for Item of Central loop
         Write_Central_Header (Output, Item);
      end loop;

      Central_Size := Current_Offset (Output) - Central_Start;
      Write_End_Record
        (Output,
         Entries.Length,
         Central_Size,
         Central_Start,
         Has_Zip64_Entry);
      Close (Output);
      return Write_Ok;
   exception
      when others =>
         if Output_Open then
            begin
               Close (Output);
            exception
               when others =>
                  null;
            end;
         end if;
         return Write_Output_Error;
   end Create_Archive;

   function Create_Archive
     (Output_Path : String)
      return Write_Result
   is
      Entries : Source_Entry_Vectors.Vector;
   begin
      return Create_Archive (Output_Path, Entries);
   end Create_Archive;

end Backup.Zip;
