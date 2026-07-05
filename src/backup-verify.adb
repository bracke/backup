with Ada.Streams;
with Ada.Strings.Fixed;
with CryptoLib.Ciphers;
with CryptoLib.Errors;
with CryptoLib.Macs;
with Zlib;

with Backup.Incremental_Syntax;
with Backup.Manifest;
with Backup.Path_Syntax;
with Backup.Paths;
with Backup.Zip_Syntax;
with Backup.Zip_Images;

package body Backup.Verify is
   Metadata_Extra_Id : constant Interfaces.Unsigned_16 := 16#BACE#;
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Zlib.Status_Code;
   use type CryptoLib.Errors.Status;
   use type Backup.Paths.Validation_Status;


   type Central_Entry is record
      Name              : Unbounded_String;
      Method            : Unsigned_16 := 0;
      Actual_Method     : Unsigned_16 := 0;
      Is_AES            : Boolean := False;
      AES_Strength      : Natural := 0;
      Crc32             : Unsigned_32 := 0;
      Compressed_Size   : Unsigned_64 := 0;
      Uncompressed_Size : Unsigned_64 := 0;
      Local_Offset      : Unsigned_64 := 0;
      Dos_Time          : Unsigned_16 := 0;
      Dos_Date          : Unsigned_16 := 33;
      External_Attrs    : Unsigned_32 := 0;
      Has_Owner         : Boolean := False;
      Owner_UID         : Unsigned_32 := 0;
      Owner_GID         : Unsigned_32 := 0;
      Xattr_Blob        : Unbounded_String := Null_Unbounded_String;
      General_Flags     : Unsigned_16 := 0;
      Version_Needed    : Unsigned_16 := 20;
      Uses_Zip64_Sizes : Boolean := False;
      Is_Directory     : Boolean := False;
   end record;

   package Central_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Central_Entry);

   type Offset_Range is record
      First : Unsigned_64 := 0;
      Last  : Unsigned_64 := 0;
   end record;

   package Range_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Offset_Range);


   function Status_Text (Status : Verify_Status) return String is
   begin
      case Status is
         when Verify_Ok => return "ok";
         when Verify_Open_Failed => return "archive could not be opened";
         when Verify_Malformed_Zip => return "malformed ZIP structure";
         when Verify_Invalid_Archive_Path => return "invalid archive path";
         when Verify_Duplicate_Archive_Path => return "duplicate archive path";
         when Verify_Invalid_Offset => return "invalid ZIP offset";
         when Verify_Truncated_Payload => return "truncated ZIP payload";
         when Verify_Metadata_Mismatch => return "local and central ZIP metadata mismatch";
         when Verify_Crc_Mismatch => return "CRC32 mismatch";
         when Verify_Invalid_Zip64 => return "invalid ZIP64 structure";
         when Verify_Unsupported_Method => return "unsupported compression method";
         when Verify_Unsupported_Feature => return "unsupported ZIP feature";
         when Verify_Deflate_Invalid => return "deflate payload validation failed";
         when Verify_Manifest_Mismatch => return "manifest metadata mismatch";
      end case;
   end Status_Text;

   function Decimal (Value : Unsigned_64) return String is
      Image : constant String := Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Method_Name (Method : Unsigned_16) return String is
   begin
      return Backup.Incremental_Syntax.Method_Name (Method);
   end Method_Name;

   function Supported_Zip_Version
     (Version : Unsigned_16) return Boolean is
   begin
      return Backup.Zip_Syntax.Is_Supported_Zip_Version (Version);
   end Supported_Zip_Version;

   function Supported_General_Flags
     (Flags  : Unsigned_16;
      Method : Unsigned_16) return Boolean
   is
   begin
      return Backup.Zip_Syntax.Is_Supported_General_Flags (Flags, Method);
   end Supported_General_Flags;

   function Q (Text : String) return String is
      Result : Unbounded_String;
      Hex    : constant array (Natural range 0 .. 15) of Character :=
        "0123456789abcdef";
      Code   : Natural;
   begin
      Append (Result, '"');
      for Ch of Text loop
         case Ch is
            when '"' =>
               Append (Result, '\');
               Append (Result, '"');
            when '\' => Append (Result, "\\");
            when ASCII.BS => Append (Result, "\b");
            when ASCII.HT => Append (Result, "\t");
            when ASCII.LF => Append (Result, "\n");
            when ASCII.FF => Append (Result, "\f");
            when ASCII.CR => Append (Result, "\r");
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
      Append (Result, '"');
      return To_String (Result);
   end Q;


   function Metadata_Mode (Item : Verified_Entry) return Unsigned_32 is
   begin
      return Shift_Right (Item.External_Attrs, 16) and 16#0FFF#;
   end Metadata_Mode;

   function Xattr_Count (Item : Verified_Entry) return Natural is
      Data : constant String := To_String (Item.Xattr_Blob);
   begin
      if Data'Length < 2 then
         return 0;
      end if;
      return Natural
        (Unsigned_16 (Character'Pos (Data (Data'First)))
         or Shift_Left
           (Unsigned_16 (Character'Pos (Data (Data'First + 1))), 8));
   exception
      when others =>
         return 0;
   end Xattr_Count;

   function Has_ACL_Xattr (Item : Verified_Entry) return Boolean is
      Data : constant String := To_String (Item.Xattr_Blob);
      Pos  : Positive := Data'First + 2;
   begin
      if Data'Length < 2 then
         return False;
      end if;
      for I in 1 .. Xattr_Count (Item) loop
         exit when Pos + 5 > Data'Last;
         declare
            Name_Length : constant Natural :=
              Natural
                (Unsigned_16 (Character'Pos (Data (Pos)))
                 or Shift_Left
                   (Unsigned_16 (Character'Pos (Data (Pos + 1))), 8));
            Value_Length : constant Natural :=
              Natural
                (Unsigned_32 (Character'Pos (Data (Pos + 2)))
                 or Shift_Left
                   (Unsigned_32 (Character'Pos (Data (Pos + 3))), 8)
                 or Shift_Left
                   (Unsigned_32 (Character'Pos (Data (Pos + 4))), 16)
                 or Shift_Left
                   (Unsigned_32 (Character'Pos (Data (Pos + 5))), 24));
            Name_First : constant Positive := Pos + 6;
            Name_Last  : constant Natural := Name_First + Name_Length - 1;
         begin
            exit when Name_Length = 0 or else Name_Last > Data'Last;
            declare
               Name : constant String := Data (Name_First .. Name_Last);
            begin
               if Name = "system.posix_acl_access"
                 or else Name = "system.posix_acl_default"
               then
                  return True;
               end if;
            end;
            Pos := Name_First + Name_Length + Value_Length;
         end;
      end loop;
      return False;
   exception
      when others =>
         return False;
   end Has_ACL_Xattr;

   procedure Append_JSON_Metadata
     (Text : in out Unbounded_String;
      Item : Verified_Entry)
   is
   begin
      Append (Text, ", " & Q ("metadata") & ": {");
      Append (Text, Q ("mode") & ": " & Decimal (Unsigned_64 (Metadata_Mode (Item))));
      Append (Text, ", " & Q ("has_owner") & ": ");
      Append (Text, (if Item.Has_Owner then "true" else "false"));
      if Item.Has_Owner then
         Append (Text, ", " & Q ("uid") & ": " & Decimal (Unsigned_64 (Item.Owner_UID)));
         Append (Text, ", " & Q ("gid") & ": " & Decimal (Unsigned_64 (Item.Owner_GID)));
      end if;
      Append (Text, ", " & Q ("xattr_count") & ": " & Decimal (Unsigned_64 (Xattr_Count (Item))));
      Append (Text, ", " & Q ("has_acl") & ": ");
      Append (Text, (if Has_ACL_Xattr (Item) then "true" else "false"));
      Append (Text, "}");
   end Append_JSON_Metadata;

   procedure Append_Human_Metadata
     (Text : in out Unbounded_String;
      Item : Verified_Entry)
   is
   begin
      Append (Text, " mode=");
      Append (Text, Decimal (Unsigned_64 (Metadata_Mode (Item))));
      if Item.Has_Owner then
         Append (Text, " owner=");
         Append (Text, Decimal (Unsigned_64 (Item.Owner_UID)));
         Append (Text, ":");
         Append (Text, Decimal (Unsigned_64 (Item.Owner_GID)));
      else
         Append (Text, " owner=absent");
      end if;
      Append (Text, " xattrs=");
      Append (Text, Decimal (Unsigned_64 (Xattr_Count (Item))));
      Append (Text, " acl=");
      Append (Text, (if Has_ACL_Xattr (Item) then "yes" else "no"));
   end Append_Human_Metadata;

   function Find_Text
     (Haystack : String;
      Needle   : String;
      From     : Positive := 1)
      return Natural
   is
      Start : Positive := From;
   begin
      if Haystack'Length = 0 or else Needle'Length = 0 then
         return 0;
      end if;
      if Start < Haystack'First then
         Start := Haystack'First;
      elsif Start > Haystack'Last then
         return 0;
      end if;
      return Ada.Strings.Fixed.Index (Haystack, Needle, Start);
   end Find_Text;

   function Contains_Text
     (Haystack : String;
      Needle   : String)
      return Boolean
   is
   begin
      return Find_Text (Haystack, Needle) /= 0;
   end Contains_Text;

   function Count_Text
     (Haystack : String;
      Needle   : String)
      return Natural
   is
      Pos    : Natural := 1;
      Found  : Natural;
      Result : Natural := 0;
   begin
      if Haystack'Length = 0 or else Needle'Length = 0 then
         return 0;
      end if;

      loop
         Found := Find_Text (Haystack, Needle, Pos);
         exit when Found = 0;
         Result := Result + 1;
         if Found > Haystack'Last - Needle'Length then
            exit;
         end if;
         Pos := Found + Needle'Length;
      end loop;
      return Result;
   end Count_Text;

   function Previous_Object_Start
     (Text : String;
      Pos  : Natural)
      return Natural
   is
   begin
      if Pos = 0 then
         return 0;
      end if;
      for Index in reverse Text'First .. Pos loop
         if Text (Index) = '{' then
            return Index;
         end if;
      end loop;
      return 0;
   end Previous_Object_Start;

   function Next_Object_End
     (Text : String;
      Pos  : Natural)
      return Natural
   is
   begin
      if Pos = 0 then
         return 0;
      end if;
      for Index in Pos .. Text'Last loop
         if Text (Index) = '}' then
            return Index;
         end if;
      end loop;
      return 0;
   end Next_Object_End;

   function Manifest_Entry_Matches
     (Text : String;
      Item : Verified_Entry)
      return Boolean
   is
      Name       : constant String := To_String (Item.Archive_Path);
      Name_Field : constant String := Q ("archive_path") & ": " & Q (Name);
      Name_Pos   : constant Natural := Find_Text (Text, Name_Field);
      Start_Pos  : Natural;
      End_Pos    : Natural;
   begin
      if Name_Pos = 0 then
         return False;
      end if;

      Start_Pos := Previous_Object_Start (Text, Name_Pos);
      End_Pos := Next_Object_End (Text, Name_Pos);
      if Start_Pos = 0 or else End_Pos = 0 or else Start_Pos > End_Pos then
         return False;
      end if;

      declare
         Object_Text  : constant String := Text (Start_Pos .. End_Pos);
         Method_Field : constant String :=
           Q ("compression_method") & ": " & Q (Method_Name (Item.Method));
         Crc_Field    : constant String :=
           Q ("crc32") & ": " & Decimal (Unsigned_64 (Item.Crc32));
         Comp_Field   : constant String :=
           Q ("compressed_size") & ": " & Decimal (Item.Compressed_Size);
         Uncomp_Field : constant String :=
           Q ("uncompressed_size") & ": " & Decimal (Item.Uncompressed_Size);
         Kind_OK      : Boolean := False;
      begin
         case Item.Kind is
            when Entry_File =>
               Kind_OK := Contains_Text
                 (Object_Text, Q ("kind") & ": " & Q ("file"));
            when Entry_Directory =>
               Kind_OK := Contains_Text
                 (Object_Text, Q ("kind") & ": " & Q ("directory"));
            when Entry_Symlink =>
               Kind_OK := Contains_Text
                 (Object_Text, Q ("kind") & ": " & Q ("symlink"))
                 and then Contains_Text
                   (Object_Text,
                    Q ("link_target") & ": " &
                    Q (To_String (Item.Link_Target)));
            when Entry_Manifest =>
               Kind_OK := Contains_Text
                 (Object_Text, Q ("kind") & ": " & Q ("manifest"));
         end case;

         return Kind_OK
           and then Contains_Text (Object_Text, Method_Field)
           and then Contains_Text (Object_Text, Crc_Field)
           and then Contains_Text (Object_Text, Comp_Field)
           and then Contains_Text (Object_Text, Uncomp_Field);
      end;
   end Manifest_Entry_Matches;

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

   function Fits
     (Data   : Stream_Element_Array;
      Offset : Unsigned_64;
      Count  : Unsigned_64)
      return Boolean
   is
      Last_Index : constant Unsigned_64 := Unsigned_64 (Data'Last);
   begin
      if Offset = 0 then
         return False;
      end if;
      if Count = 0 then
         return Offset <= Last_Index + 1;
      end if;
      return Offset <= Last_Index and then Count - 1 <= Last_Index - Offset;
   end Fits;

   function Pos_Of (Offset : Unsigned_64) return Stream_Element_Offset is
   begin
      return Stream_Element_Offset (Offset);
   end Pos_Of;

   function Find_EOCD
     (Data : Stream_Element_Array)
      return Stream_Element_Offset
   is
      Start : Stream_Element_Offset;
   begin
      if Data'Length < 22 then
         return 0;
      end if;

      if Data'Last > 65_557 then
         Start := Data'Last - 65_557;
      else
         Start := Data'First;
      end if;

      for Pos in reverse Start .. Data'Last - 3 loop
         if Pos + 21 <= Data'Last
           and then U32_At (Data, Pos) = 16#0605_4B50#
         then
            declare
               Comment_Length : constant Unsigned_16 := U16_At (Data, Pos + 20);
            begin
               if Unsigned_64 (Pos + 22) + Unsigned_64 (Comment_Length)
                 = Unsigned_64 (Data'Last) + 1
               then
                  return Pos;
               end if;
            end;
         end if;
      end loop;
      return 0;
   end Find_EOCD;

   function Contains_Backslash (Text : String) return Boolean is
   begin
      for Ch of Text loop
         if Ch = '\' then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Backslash;


   function Ends_With_Slash (Text : String) return Boolean is
   begin
      return Text'Length > 0
        and then Backup.Path_Syntax.Is_Slash (Text (Text'Last));
   end Ends_With_Slash;

   function Directory_Archive_Name (Text : String) return String is
   begin
      if Ends_With_Slash (Text) then
         if Text'Length = 1 then
            return "";
         end if;
         return Text (Text'First .. Text'Last - 1);
      end if;
      return Text;
   end Directory_Archive_Name;


   procedure Parse_Metadata_Extra
     (Data       : Stream_Element_Array;
      First      : Stream_Element_Offset;
      Last       : Stream_Element_Offset;
      Has_Owner  : out Boolean;
      Owner_UID  : out Unsigned_32;
      Owner_GID  : out Unsigned_32;
      Xattr_Blob : out Unbounded_String)
   is
      Pos : Stream_Element_Offset := First;
   begin
      Has_Owner := False;
      Owner_UID := 0;
      Owner_GID := 0;
      Xattr_Blob := Null_Unbounded_String;
      while Pos + 3 <= Last loop
         declare
            Header : constant Unsigned_16 := U16_At (Data, Pos);
            Size   : constant Unsigned_16 := U16_At (Data, Pos + 2);
            Body_Pos : constant Stream_Element_Offset := Pos + 4;
            Stop   : constant Stream_Element_Offset := Body_Pos + Stream_Element_Offset (Size) - 1;
         begin
            exit when Stop > Last;
            if Header = Metadata_Extra_Id
              and then Size >= 16
              and then U32_At (Data, Body_Pos) = 16#444D_4B42#
              and then U16_At (Data, Body_Pos + 4) = 1
            then
               declare
                  Flags : constant Unsigned_16 := U16_At (Data, Body_Pos + 6);
               begin
                  if (Flags and 1) /= 0 then
                     Has_Owner := True;
                     Owner_UID := U32_At (Data, Body_Pos + 8);
                     Owner_GID := U32_At (Data, Body_Pos + 12);
                  end if;
                  if (Flags and 2) /= 0 and then Size > 16 then
                     for I in Body_Pos + 16 .. Stop loop
                        Append (Xattr_Blob, Character'Val (Integer (Data (I))));
                     end loop;
                  end if;
               end;
            end if;
            Pos := Stop + 1;
         end;
      end loop;
   exception
      when others =>
         Has_Owner := False;
         Owner_UID := 0;
         Owner_GID := 0;
         Xattr_Blob := Null_Unbounded_String;
   end Parse_Metadata_Extra;

   function Bytes_To_String
     (Data  : Stream_Element_Array;
      First : Stream_Element_Offset;
      Last  : Stream_Element_Offset)
      return String
   is
      Result : String (1 .. Natural (Last - First + 1));
      Outpos : Natural := Result'First;
   begin
      for Pos in First .. Last loop
         Result (Outpos) := Character'Val (Data (Pos));
         Outpos := Outpos + 1;
      end loop;
      return Result;
   end Bytes_To_String;

   function Can_Stringify (Count : Unsigned_64) return Boolean is
   begin
      return Count <= Unsigned_64 (Natural'Last);
   end Can_Stringify;

   procedure Parse_Zip64_Size_Extra
     (Data            : Stream_Element_Array;
      Extra_First     : Stream_Element_Offset;
      Extra_Last      : Stream_Element_Offset;
      Need_Uncomp     : Boolean;
      Need_Comp       : Boolean;
      Need_Offset     : Boolean;
      Uncomp          : in out Unsigned_64;
      Comp            : in out Unsigned_64;
      Local_Offset    : in out Unsigned_64;
      Found           : out Boolean;
      Valid           : out Boolean)
   is
      Pos       : Stream_Element_Offset := Extra_First;
      Header_Id : Unsigned_16;
      Size      : Unsigned_16;
      Value_Pos : Stream_Element_Offset;
   begin
      Found := False;
      Valid := True;
      while Pos <= Extra_Last loop
         if Pos + 3 > Extra_Last then
            Valid := False;
            return;
         end if;
         Header_Id := U16_At (Data, Pos);
         Size := U16_At (Data, Pos + 2);
         if Size = 0 then
            if Pos + 3 > Extra_Last then
               Valid := False;
               return;
            end if;
         elsif Unsigned_64 (Pos + 4) + Unsigned_64 (Size) - 1
           > Unsigned_64 (Extra_Last)
         then
            Valid := False;
            return;
         end if;

         if Header_Id = 16#0001# then
            declare
               Required_Size : Unsigned_16 := 0;
            begin
               if Need_Uncomp then
                  Required_Size := Required_Size + 8;
               end if;
               if Need_Comp then
                  Required_Size := Required_Size + 8;
               end if;
               if Need_Offset then
                  Required_Size := Required_Size + 8;
               end if;
               if Size < Required_Size then
                  Valid := False;
                  return;
               end if;
            end;
            Found := True;
            Value_Pos := Pos + 4;
            if Need_Uncomp then
               if Value_Pos + 7 > Extra_Last then
                  Valid := False;
                  return;
               end if;
               Uncomp := U64_At (Data, Value_Pos);
               Value_Pos := Value_Pos + 8;
            end if;
            if Need_Comp then
               if Value_Pos + 7 > Extra_Last then
                  Valid := False;
                  return;
               end if;
               Comp := U64_At (Data, Value_Pos);
               Value_Pos := Value_Pos + 8;
            end if;
            if Need_Offset then
               if Value_Pos + 7 > Extra_Last then
                  Valid := False;
                  return;
               end if;
               declare
                  Raw_Offset : constant Unsigned_64 := U64_At (Data, Value_Pos);
               begin
                  if Raw_Offset = Unsigned_64'Last then
                     Valid := False;
                     return;
                  end if;
                  Local_Offset := Raw_Offset + 1;
               end;
            end if;
            return;
         end if;
         Pos := Pos + 4 + Stream_Element_Offset (Size);
      end loop;
   end Parse_Zip64_Size_Extra;

   function Bytes_To_Zlib
     (Data  : Stream_Element_Array;
      First : Stream_Element_Offset;
      Last  : Stream_Element_Offset) return Zlib.Byte_Array
   is
   begin
      if Last < First then
         return [1 .. 0 => 0];
      end if;

      declare
         Result : Zlib.Byte_Array (1 .. Natural (Last - First + 1));
      begin
         for I in Result'Range loop
            Result (I) := Zlib.Byte (Data (First + Stream_Element_Offset (I - 1)));
         end loop;
         return Result;
      end;
   end Bytes_To_Zlib;

   function Zlib_To_Bytes (Data : Zlib.Byte_Array) return Stream_Element_Array is
   begin
      if Data'Length = 0 then
         return [1 .. 0 => 0];
      end if;
      declare
         Result : Stream_Element_Array (1 .. Stream_Element_Offset (Data'Length));
      begin
         for I in Data'Range loop
            Result (Stream_Element_Offset (I - Data'First + 1)) :=
              Stream_Element (Data (I));
         end loop;
         return Result;
      end;
   end Zlib_To_Bytes;


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

   function Zipcrypto_Check_Byte
     (Crc32    : Unsigned_32;
      Dos_Time : Unsigned_16;
      Flags    : Unsigned_16)
      return Stream_Element
   is
   begin
      if (Flags and 8) /= 0 then
         return Stream_Element (Shift_Right (Dos_Time, 8) and 16#00FF#);
      else
         return Stream_Element (Shift_Right (Crc32, 24) and 16#0000_00FF#);
      end if;
   end Zipcrypto_Check_Byte;

   function Zipcrypto_Password_Matches
     (Data       : Stream_Element_Array;
      First      : Stream_Element_Offset;
      Last       : Stream_Element_Offset;
      Password   : String;
      Check_Byte : Stream_Element)
      return Boolean
   is
      Keys  : Zipcrypto_Keys := Zipcrypto_Initial_Keys (Password);
      Plain : Stream_Element := 0;
   begin
      if Password'Length = 0 or else Last - First + 1 < 12 then
         return False;
      end if;

      for Pos in First .. First + 11 loop
         Plain := Data (Pos) xor Zipcrypto_Key_Byte (Keys);
         Zipcrypto_Update_Keys (Keys, Plain);
      end loop;
      return Plain = Check_Byte;
   exception
      when others =>
         return False;
   end Zipcrypto_Password_Matches;

   function Zipcrypto_Decrypt_Data
     (Data     : Stream_Element_Array;
      First    : Stream_Element_Offset;
      Last     : Stream_Element_Offset;
      Password : String)
      return Stream_Element_Array
   is
      Plain_Len : constant Stream_Element_Offset := Last - First + 1 - 12;
      Keys      : Zipcrypto_Keys := Zipcrypto_Initial_Keys (Password);
      Plain     : Stream_Element;
      Result    : Stream_Element_Array (1 .. Plain_Len);
      Out_Pos   : Stream_Element_Offset := Result'First;
   begin
      for Pos in First .. Last loop
         Plain := Data (Pos) xor Zipcrypto_Key_Byte (Keys);
         Zipcrypto_Update_Keys (Keys, Plain);
         if Pos >= First + 12 then
            Result (Out_Pos) := Plain;
            Out_Pos := Out_Pos + 1;
         end if;
      end loop;
      return Result;
   end Zipcrypto_Decrypt_Data;

   function Validate_Deflate_Payload
     (Data              : Stream_Element_Array;
      Payload_First     : Stream_Element_Offset;
      Payload_Last      : Stream_Element_Offset;
      Expected_Uncomp   : Unsigned_64;
      Computed_Crc      : out Unsigned_32;
      Computed_Uncomp   : out Unsigned_64;
      Content           : out Unbounded_String)
      return Boolean
   is
      Status : Zlib.Status_Code := Zlib.Ok;
   begin
      Computed_Crc := 0;
      Computed_Uncomp := 0;
      Content := Null_Unbounded_String;

      declare
         Payload  : constant Zlib.Byte_Array :=
           Bytes_To_Zlib (Data, Payload_First, Payload_Last);
         Inflated : constant Zlib.Byte_Array := Zlib.Inflate_Raw (Payload, Status);
      begin
         if Status /= Zlib.Ok then
            return False;
         end if;
         Computed_Uncomp := Unsigned_64 (Inflated'Length);
         if Computed_Uncomp /= Expected_Uncomp then
            return False;
         end if;
         Computed_Crc := Zlib.CRC32 (Inflated);
         if Inflated'Length <= 1_000_000 then
            for B of Inflated loop
               Append (Content, Character'Val (Integer (B)));
            end loop;
         end if;
         return True;
      end;
   exception
      when others =>
         Computed_Crc := 0;
         Computed_Uncomp := 0;
         Content := Null_Unbounded_String;
         return False;
   end Validate_Deflate_Payload;



   type AES_Extra_Info is record
      Present       : Boolean := False;
      Valid         : Boolean := False;
      Vendor_Version : Unsigned_16 := 0;
      Strength      : Natural := 0;
      Actual_Method : Unsigned_16 := 0;
   end record;

   function AES_Key_Length (Strength : Natural) return Natural is
   begin
      case Strength is
         when 1 => return 16;
         when 2 => return 24;
         when 3 => return 32;
         when others => return 0;
      end case;
   end AES_Key_Length;

   function AES_Salt_Length (Strength : Natural) return Natural is
   begin
      case Strength is
         when 1 => return 8;
         when 2 => return 12;
         when 3 => return 16;
         when others => return 0;
      end case;
   end AES_Salt_Length;

   function AES_Algorithm_Name (Strength : Natural) return String is
   begin
      case Strength is
         when 1 => return "aes128";
         when 2 => return "aes192";
         when 3 => return "aes256";
         when others => return "";
      end case;
   end AES_Algorithm_Name;

   function Password_Bytes (Password : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Stream_Element_Offset (Password'Length));
   begin
      for I in Password'Range loop
         Result (Stream_Element_Offset (I - Password'First + 1)) :=
           Stream_Element (Character'Pos (Password (I)));
      end loop;
      return Result;
   end Password_Bytes;

   function First_Bytes_Match
     (Left  : Stream_Element_Array;
      Right : Stream_Element_Array;
      Count : Natural) return Boolean
   is
   begin
      if Left'Length < Stream_Element_Offset (Count)
        or else Right'Length < Stream_Element_Offset (Count)
      then
         return False;
      end if;
      for I in 0 .. Count - 1 loop
         if Left (Left'First + Stream_Element_Offset (I)) /=
            Right (Right'First + Stream_Element_Offset (I))
         then
            return False;
         end if;
      end loop;
      return True;
   end First_Bytes_Match;

   function Parse_AES_Extra
     (Data  : Stream_Element_Array;
      First : Stream_Element_Offset;
      Last  : Stream_Element_Offset) return AES_Extra_Info
   is
      Pos : Stream_Element_Offset := First;
   begin
      if Last < First then
         return (Present => False, Valid => False, others => <>);
      end if;
      while Pos + 3 <= Last loop
         declare
            Header_Id : constant Unsigned_16 := U16_At (Data, Pos);
            Size      : constant Unsigned_16 := U16_At (Data, Pos + 2);
            Body_Pos  : constant Stream_Element_Offset := Pos + 4;
            Item_Last : constant Stream_Element_Offset :=
              Body_Pos + Stream_Element_Offset (Size) - 1;
         begin
            if Item_Last > Last then
               return (Present => Header_Id = 16#9901#, Valid => False, others => <>);
            end if;
            if Header_Id = 16#9901# then
               if Size /= 7
                 or else Character'Val (Data (Body_Pos + 2)) /= 'A'
                 or else Character'Val (Data (Body_Pos + 3)) /= 'E'
               then
                  return (Present => True, Valid => False, others => <>);
               end if;
               declare
                  Strength : constant Natural := Natural (Data (Body_Pos + 4));
               begin
                  return
                    (Present        => True,
                     Valid          => AES_Key_Length (Strength) /= 0,
                     Vendor_Version => U16_At (Data, Body_Pos),
                     Strength       => Strength,
                     Actual_Method  => U16_At (Data, Body_Pos + 5));
               end;
            end if;
            Pos := Item_Last + 1;
         end;
      end loop;
      return (Present => False, Valid => False, others => <>);
   exception
      when others =>
         return (Present => False, Valid => False, others => <>);
   end Parse_AES_Extra;

   procedure Decrypt_AES_Payload
     (Data        : Stream_Element_Array;
      First       : Stream_Element_Offset;
      Last        : Stream_Element_Offset;
      Strength    : Natural;
      Password    : String;
      Plaintext   : out Stream_Element_Array;
      Valid       : out Boolean)
   is
      Key_Length       : constant Natural := AES_Key_Length (Strength);
      Salt_Length      : constant Natural := AES_Salt_Length (Strength);
      Salt_First       : constant Stream_Element_Offset := First;
      Salt_Last        : constant Stream_Element_Offset := First + Stream_Element_Offset (Salt_Length) - 1;
      Verifier_First   : constant Stream_Element_Offset := Salt_Last + 1;
      Cipher_First     : constant Stream_Element_Offset := Verifier_First + 2;
      Auth_First       : constant Stream_Element_Offset := Last - 9;
      Cipher_Last      : constant Stream_Element_Offset := Auth_First - 1;
      Derived          : Stream_Element_Array (1 .. Stream_Element_Offset (2 * Key_Length + 2));
      Status_Value     : CryptoLib.Errors.Status;
   begin
      Plaintext := [others => 0];
      Valid := False;
      if Password'Length = 0
        or else Key_Length = 0
        or else Last < First
        or else Last - First + 1 < Stream_Element_Offset (Salt_Length + 2 + 10)
        or else Plaintext'Length /= Cipher_Last - Cipher_First + 1
      then
         return;
      end if;

      Derived := CryptoLib.Macs.PBKDF2_HMAC_SHA1
        (Password_Bytes (Password), Data (Salt_First .. Salt_Last), 1000,
         2 * Key_Length + 2);
      if Derived (Derived'Last - 1) /= Data (Verifier_First)
        or else Derived (Derived'Last) /= Data (Verifier_First + 1)
      then
         return;
      end if;

      declare
         Auth_Key : constant Stream_Element_Array :=
           Derived (Derived'First + Stream_Element_Offset (Key_Length) ..
                    Derived'First + Stream_Element_Offset (2 * Key_Length) - 1);
         Auth : constant CryptoLib.Macs.HMAC_SHA1_Digest :=
           CryptoLib.Macs.HMAC_SHA1 (Auth_Key, Data (Cipher_First .. Cipher_Last));
         Auth_Data : Stream_Element_Array (1 .. 20);
      begin
         for I in Auth'Range loop
            Auth_Data (Stream_Element_Offset (I)) := Auth (I);
         end loop;
         if not First_Bytes_Match (Auth_Data, Data (Auth_First .. Last), 10) then
            return;
         end if;
      end;

      declare
         AES_Key : constant Stream_Element_Array :=
           Derived (Derived'First .. Derived'First + Stream_Element_Offset (Key_Length) - 1);
      begin
         Status_Value := CryptoLib.Ciphers.Apply_ZIP_AES_CTR
           (AES_Algorithm_Name (Strength), AES_Key,
            Data (Cipher_First .. Cipher_Last), Plaintext);
         Valid := Status_Value = CryptoLib.Errors.Ok;
      end;
   exception
      when others =>
         Plaintext := [others => 0];
         Valid := False;
   end Decrypt_AES_Payload;

   function Verify_Archive
     (Archive_Path : String;
      Report       : out Verification_Report;
      Diagnostic   : out Unbounded_String)
      return Verify_Status
   is
   begin
      return Verify_Archive (Archive_Path, "", Report, Diagnostic);
   end Verify_Archive;

   function Verify_Archive
     (Archive_Path  : String;
      Zip_Password  : String;
      Report        : out Verification_Report;
      Diagnostic    : out Unbounded_String)
      return Verify_Status
   is
      Seen        : Backup.Paths.Archive_Path_Sets.Set;
      Disk_Starts : Backup.Zip_Images.Disk_Start_Vectors.Vector;
      Read_Ok     : Boolean := False;
      Central     : Central_Vectors.Vector;
      Local_Ranges : Range_Vectors.Vector;
      Manifest    : Unbounded_String;
   begin
      Report := (Status       => Verify_Malformed_Zip,
                 Entries      => Entry_Vectors.Empty_Vector,
                 Has_Zip64    => False,
                 Has_Manifest => False,
                 Manifest_OK  => False);
      Diagnostic := Null_Unbounded_String;

      declare
         Data : constant Stream_Element_Array :=
           Backup.Zip_Images.Read_Logical_Zip
             (Archive_Path, Disk_Starts, Diagnostic, Read_Ok);
      begin
         if not Read_Ok then
            if Length (Diagnostic) = 0 then
               Diagnostic := To_Unbounded_String ("archive could not be opened: " & Archive_Path);
            end if;
            Report.Status := Verify_Open_Failed;
            return Verify_Open_Failed;
         end if;
         if Data'Length < 22 then
            Diagnostic := To_Unbounded_String ("archive is too small for ZIP EOCD");
            Report.Status := Verify_Malformed_Zip;
            return Verify_Malformed_Zip;
         end if;

         declare
               Eocd : constant Stream_Element_Offset := Find_EOCD (Data);
               Entry_Count_16 : Unsigned_16;
               Central_Size_32 : Unsigned_32;
               Central_Offset_32 : Unsigned_32;
               Entry_Count : Unsigned_64;
               Central_Size : Unsigned_64;
               Central_Offset : Unsigned_64;
               Central_Follow_Offset : Unsigned_64;
               This_Disk : Unsigned_16;
               Central_Disk : Unsigned_16;
               Is_Split : constant Boolean := Natural (Disk_Starts.Length) > 1;

               function Disk_Start_Offset (Disk : Unsigned_16) return Unsigned_64 is
               begin
                  if Natural (Disk) >= Natural (Disk_Starts.Length) then
                     return 0;
                  end if;
                  return Disk_Starts.Element (Natural (Disk));
               end Disk_Start_Offset;
            begin
               if Eocd = 0 or else Eocd + 21 > Data'Last then
                  Diagnostic := To_Unbounded_String ("missing or truncated ZIP EOCD");
                  Report.Status := Verify_Malformed_Zip;
                  return Verify_Malformed_Zip;
               end if;

               declare
                  Comment_Length : constant Unsigned_16 := U16_At (Data, Eocd + 20);
               begin
                  if Unsigned_64 (Eocd + 22) + Unsigned_64 (Comment_Length) - 1 /= Unsigned_64 (Data'Last) then
                     Diagnostic := To_Unbounded_String ("ZIP EOCD comment length does not match archive size");
                     Report.Status := Verify_Malformed_Zip;
                     return Verify_Malformed_Zip;
                  end if;
               end;

               This_Disk := U16_At (Data, Eocd + 4);
               Central_Disk := U16_At (Data, Eocd + 6);
               if not Is_Split then
                  if This_Disk /= 0 or else Central_Disk /= 0 then
                     Diagnostic := To_Unbounded_String
                       ("multi-disk ZIP archive parts are missing");
                     Report.Status := Verify_Malformed_Zip;
                     return Verify_Malformed_Zip;
                  end if;
               elsif Natural (This_Disk) /= Natural (Disk_Starts.Length) - 1
                 or else Disk_Start_Offset (Central_Disk) = 0
               then
                  Diagnostic := To_Unbounded_String
                    ("split ZIP disk metadata does not match available parts");
                  Report.Status := Verify_Malformed_Zip;
                  return Verify_Malformed_Zip;
               end if;

               Entry_Count_16 := U16_At (Data, Eocd + 10);
               if not Is_Split and then U16_At (Data, Eocd + 8) /= Entry_Count_16 then
                  Diagnostic := To_Unbounded_String
                    ("central directory disk entry count mismatch");
                  Report.Status := Verify_Metadata_Mismatch;
                  return Verify_Metadata_Mismatch;
               end if;

               Central_Size_32 := U32_At (Data, Eocd + 12);
               Central_Offset_32 := U32_At (Data, Eocd + 16);
               Entry_Count := Unsigned_64 (Entry_Count_16);
               Central_Size := Unsigned_64 (Central_Size_32);
               Central_Offset := Disk_Start_Offset (Central_Disk) + Unsigned_64 (Central_Offset_32);
               Central_Follow_Offset := Unsigned_64 (Eocd);

               if Entry_Count_16 = 16#FFFF#
                 or else Central_Size_32 = 16#FFFF_FFFF#
                 or else Central_Offset_32 = 16#FFFF_FFFF#
               then
                  if Eocd < 21 then
                     Diagnostic := To_Unbounded_String ("missing ZIP64 locator before EOCD");
                     Report.Status := Verify_Invalid_Zip64;
                     return Verify_Invalid_Zip64;
                  end if;
                  declare
                     Locator : constant Stream_Element_Offset := Eocd - 20;
                     Zip64_Offset : Unsigned_64;
                     Rec : Stream_Element_Offset;
                  begin
                     if U32_At (Data, Locator) /= 16#0706_4B50# then
                        Diagnostic := To_Unbounded_String ("missing ZIP64 locator");
                        Report.Status := Verify_Invalid_Zip64;
                        return Verify_Invalid_Zip64;
                     end if;
                     if (not Is_Split
                         and then (U32_At (Data, Locator + 4) /= 0
                           or else U32_At (Data, Locator + 16) /= 1))
                       or else (Is_Split
                         and then (U32_At (Data, Locator + 16) /= Unsigned_32 (Disk_Starts.Length)
                           or else Natural (U32_At (Data, Locator + 4)) >= Natural (Disk_Starts.Length)))
                     then
                        Diagnostic := To_Unbounded_String
                          ("ZIP64 split disk locator does not match available parts");
                        Report.Status := Verify_Invalid_Zip64;
                        return Verify_Invalid_Zip64;
                     end if;
                     Zip64_Offset :=
                       Disk_Starts.Element (Natural (U32_At (Data, Locator + 4)))
                       + U64_At (Data, Locator + 8);
                     Central_Follow_Offset := Zip64_Offset;
                     if not Fits (Data, Zip64_Offset, 56) then
                        Diagnostic := To_Unbounded_String ("ZIP64 EOCD offset is invalid");
                        Report.Status := Verify_Invalid_Zip64;
                        return Verify_Invalid_Zip64;
                     end if;
                     Rec := Pos_Of (Zip64_Offset);
                     if U32_At (Data, Rec) /= 16#0606_4B50# then
                        Diagnostic := To_Unbounded_String ("ZIP64 EOCD signature is invalid");
                        Report.Status := Verify_Invalid_Zip64;
                        return Verify_Invalid_Zip64;
                     end if;
                     declare
                        Zip64_Record_Size : constant Unsigned_64 := U64_At (Data, Rec + 4);
                        Rec_Offset        : constant Unsigned_64 := Unsigned_64 (Rec);
                     begin
                        if Zip64_Record_Size < 44
                          or else Rec_Offset > Unsigned_64'Last - 12
                          or else Zip64_Record_Size >
                            Unsigned_64'Last - Rec_Offset - 12
                          or else Rec_Offset + 12 + Zip64_Record_Size
                            /= Unsigned_64 (Locator)
                        then
                           Diagnostic := To_Unbounded_String ("ZIP64 EOCD size is invalid");
                           Report.Status := Verify_Invalid_Zip64;
                           return Verify_Invalid_Zip64;
                        end if;
                     end;
                     if (not Is_Split
                         and then (U32_At (Data, Rec + 16) /= 0
                           or else U32_At (Data, Rec + 20) /= 0))
                       or else (Is_Split
                         and then (Natural (U32_At (Data, Rec + 16)) >= Natural (Disk_Starts.Length)
                           or else Natural (U32_At (Data, Rec + 20)) >= Natural (Disk_Starts.Length)))
                     then
                        Diagnostic := To_Unbounded_String
                          ("ZIP64 split disk EOCD does not match available parts");
                        Report.Status := Verify_Invalid_Zip64;
                        return Verify_Invalid_Zip64;
                     end if;
                     Entry_Count := U64_At (Data, Rec + 32);
                     Central_Size := U64_At (Data, Rec + 40);
                     Central_Disk := Unsigned_16 (U32_At (Data, Rec + 20));
                     Central_Offset := Disk_Start_Offset (Central_Disk) + U64_At (Data, Rec + 48);
                     Report.Has_Zip64 := True;
                  end;
               end if;

               if not Fits (Data, Central_Offset, Central_Size)
                 or else Central_Offset > Central_Follow_Offset
                 or else Central_Size > Central_Follow_Offset - Central_Offset
                 or else Central_Offset + Central_Size /= Central_Follow_Offset
               then
                  Diagnostic := To_Unbounded_String ("central directory offset or size is invalid");
                  Report.Status := Verify_Invalid_Offset;
                  return Verify_Invalid_Offset;
               end if;

               declare
                  Pos : Stream_Element_Offset := Pos_Of (Central_Offset);
                  Stop : constant Stream_Element_Offset :=
                    (if Central_Size = 0 then
                       Pos_Of (Central_Offset - 1)
                     else
                       Pos_Of (Central_Offset + Central_Size - 1));
                  Count : Unsigned_64 := 0;
               begin
                  while Central_Size > 0 and then Pos <= Stop loop
                     if Pos + 45 > Stop or else U32_At (Data, Pos) /= 16#0201_4B50# then
                        Diagnostic := To_Unbounded_String ("malformed central directory record");
                        Report.Status := Verify_Malformed_Zip;
                        return Verify_Malformed_Zip;
                     end if;
                     declare
                        Version_Needed : constant Unsigned_16 := U16_At (Data, Pos + 6);
                        Flags : constant Unsigned_16 := U16_At (Data, Pos + 8);
                        Method : constant Unsigned_16 := U16_At (Data, Pos + 10);
                        Mod_Time : constant Unsigned_16 := U16_At (Data, Pos + 12);
                        Mod_Date : constant Unsigned_16 := U16_At (Data, Pos + 14);
                        Crc : constant Unsigned_32 := U32_At (Data, Pos + 16);
                        Comp_32 : constant Unsigned_32 := U32_At (Data, Pos + 20);
                        Uncomp_32 : constant Unsigned_32 := U32_At (Data, Pos + 24);
                        Name_Len : constant Unsigned_16 := U16_At (Data, Pos + 28);
                        Extra_Len : constant Unsigned_16 := U16_At (Data, Pos + 30);
                        Comment_Len : constant Unsigned_16 := U16_At (Data, Pos + 32);
                        Disk_Start : constant Unsigned_16 := U16_At (Data, Pos + 34);
                        External : constant Unsigned_32 := U32_At (Data, Pos + 38);
                        Offset_32 : constant Unsigned_32 := U32_At (Data, Pos + 42);
                        Name_First : constant Stream_Element_Offset := Pos + 46;
                        Name_Last : constant Stream_Element_Offset := Name_First + Stream_Element_Offset (Name_Len) - 1;
                        Extra_First : constant Stream_Element_Offset := Name_Last + 1;
                        Extra_Last : constant Stream_Element_Offset := Extra_First + Stream_Element_Offset (Extra_Len) - 1;
                        Record_Last : constant Stream_Element_Offset := Pos + 45 + Stream_Element_Offset (Name_Len) + Stream_Element_Offset (Extra_Len) + Stream_Element_Offset (Comment_Len);
                        Comp : Unsigned_64 := Unsigned_64 (Comp_32);
                        Uncomp : Unsigned_64 := Unsigned_64 (Uncomp_32);
                        Local_Off : Unsigned_64 := Disk_Start_Offset (Disk_Start) + Unsigned_64 (Offset_32);
                        Found : Boolean;
                        Valid : Boolean;
                        Archive : Backup.Paths.Archive_Path;
                        Meta_Has_Owner : Boolean;
                        Meta_UID       : Unsigned_32;
                        Meta_GID       : Unsigned_32;
                        Meta_Xattrs    : Unbounded_String;
                        AES_Info       : AES_Extra_Info;
                     begin
                        if Record_Last > Stop or else Name_Len = 0 then
                           Diagnostic := To_Unbounded_String ("truncated central directory record");
                           Report.Status := Verify_Malformed_Zip;
                           return Verify_Malformed_Zip;
                        end if;
                        if not Supported_Zip_Version (Version_Needed) then
                           Diagnostic := To_Unbounded_String ("unsupported ZIP version-needed field for central entry");
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        end if;
                        if (not Is_Split and then Disk_Start /= 0)
                          or else Disk_Start_Offset (Disk_Start) = 0
                        then
                           Diagnostic := To_Unbounded_String ("central entry disk start does not match available ZIP parts");
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        end if;
                        if not Supported_General_Flags (Flags, Method) then
                           Diagnostic := To_Unbounded_String ("unsupported ZIP general-purpose flags for central entry");
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        end if;
                        if ((Flags and 1) /= 0 or else Method = 99) and then Zip_Password'Length = 0 then
                           Diagnostic := To_Unbounded_String
                             ("encrypted ZIP entry requires a password source: " &
                              Bytes_To_String (Data, Name_First, Name_Last));
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        end if;
                        if Comp_32 = 16#FFFF_FFFF# or else Uncomp_32 = 16#FFFF_FFFF# or else Offset_32 = 16#FFFF_FFFF# then
                           Parse_Zip64_Size_Extra
                             (Data, Extra_First, Extra_Last,
                              Uncomp_32 = 16#FFFF_FFFF#,
                              Comp_32 = 16#FFFF_FFFF#,
                              Offset_32 = 16#FFFF_FFFF#,
                              Uncomp, Comp, Local_Off, Found, Valid);
                           if not Valid or else not Found or else Version_Needed /= 45 then
                              Diagnostic := To_Unbounded_String ("central directory ZIP64 extra field is invalid");
                              Report.Status := Verify_Invalid_Zip64;
                              return Verify_Invalid_Zip64;
                           end if;
                           if Is_Split and then Offset_32 = 16#FFFF_FFFF# then
                              Local_Off := Local_Off + Disk_Start_Offset (Disk_Start) - 1;
                           end if;
                           Report.Has_Zip64 := True;
                        end if;
                        Parse_Metadata_Extra
                          (Data, Extra_First, Extra_Last, Meta_Has_Owner, Meta_UID, Meta_GID, Meta_Xattrs);
                        AES_Info := Parse_AES_Extra (Data, Extra_First, Extra_Last);
                        if Method = 99 and then (not AES_Info.Present or else not AES_Info.Valid) then
                           Diagnostic := To_Unbounded_String ("AES ZIP extra field is invalid");
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        elsif Method /= 99 and then AES_Info.Present then
                           Diagnostic := To_Unbounded_String ("AES ZIP extra field appears on non-AES entry");
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        end if;
                        declare
                           Name : constant String := Bytes_To_String (Data, Name_First, Name_Last);
                        begin
                           declare
                              Is_Dir : constant Boolean :=
                                Ends_With_Slash (Name)
                                or else (External and 16#F000_0000#) = 16#4000_0000#;
                              Path_Name : constant String :=
                                (if Is_Dir then Directory_Archive_Name (Name) else Name);
                           begin
                              if Contains_Backslash (Name)
                                or else Backup.Paths.Make_Archive_Path (Path_Name, Archive)
                                  /= Backup.Paths.Valid
                              then
                                 Diagnostic := To_Unbounded_String ("invalid archive path: " & Name);
                                 Report.Status := Verify_Invalid_Archive_Path;
                                 return Verify_Invalid_Archive_Path;
                              end if;
                              if Is_Dir and then (Method /= 0 or else Comp /= 0 or else Uncomp /= 0) then
                                 Diagnostic := To_Unbounded_String ("directory entry must be stored and empty: " & Name);
                                 Report.Status := Verify_Metadata_Mismatch;
                                 return Verify_Metadata_Mismatch;
                              end if;
                           end;
                           if not Backup.Paths.Insert_Archive_Path (Seen, Archive) then
                              Diagnostic := To_Unbounded_String ("duplicate archive path: " & Name);
                              Report.Status := Verify_Duplicate_Archive_Path;
                              return Verify_Duplicate_Archive_Path;
                           end if;
                           Central.Append
                             (Central_Entry'(Name              => To_Unbounded_String (Name),
                               Method            => Method,
                               Actual_Method     => (if Method = 99 then AES_Info.Actual_Method else Method),
                               Is_AES            => Method = 99,
                               AES_Strength      => (if Method = 99 then AES_Info.Strength else 0),
                               Crc32             => Crc,
                               Compressed_Size   => Comp,
                               Uncompressed_Size => Uncomp,
                               Local_Offset      => Local_Off,
                               Dos_Time          => Mod_Time,
                               Dos_Date          => Mod_Date,
                               External_Attrs    => External,
                               Has_Owner         => Meta_Has_Owner,
                               Owner_UID         => Meta_UID,
                               Owner_GID         => Meta_GID,
                               Xattr_Blob        => Meta_Xattrs,
                               General_Flags     => Flags,
                               Version_Needed    => Version_Needed,
                               Uses_Zip64_Sizes =>
                                 Comp_32 = 16#FFFF_FFFF#
                                 or else Uncomp_32 = 16#FFFF_FFFF#,
                               Is_Directory =>
                                 Ends_With_Slash (Name)
                                 or else (External and 16#F000_0000#) = 16#4000_0000#));
                        end;
                        Count := Count + 1;
                        Pos := Record_Last + 1;
                     end;
                  end loop;
                  if Count /= Entry_Count then
                     Diagnostic := To_Unbounded_String ("central directory entry count mismatch");
                     Report.Status := Verify_Metadata_Mismatch;
                     return Verify_Metadata_Mismatch;
                  end if;
               end;

               for Central_Item of Central loop
                  if Central_Item.Actual_Method /= 0
                    and then Central_Item.Actual_Method /= 8
                    and then not Zlib.Is_ZIP_External_Method
                      (Central_Item.Actual_Method)
                  then
                     Diagnostic := To_Unbounded_String
                       ("unsupported compression method for " & To_String (Central_Item.Name));
                     Report.Status := Verify_Unsupported_Method;
                     return Verify_Unsupported_Method;
                  end if;
                  if To_String (Central_Item.Name) = Backup.Manifest.Manifest_Path
                    and then Central_Item.Actual_Method /= 0
                  then
                     Diagnostic := To_Unbounded_String
                       ("backup manifest entry must be stored");
                     Report.Status := Verify_Manifest_Mismatch;
                     return Verify_Manifest_Mismatch;
                  end if;
                  if Central_Item.Is_Directory and then Central_Item.Actual_Method /= 0 then
                     Diagnostic := To_Unbounded_String
                       ("directory entry must be stored: " & To_String (Central_Item.Name));
                     Report.Status := Verify_Metadata_Mismatch;
                     return Verify_Metadata_Mismatch;
                  end if;
                  if (Central_Item.External_Attrs and 16#F000_0000#) = 16#A000_0000#
                    and then Central_Item.Actual_Method /= 0
                  then
                     Diagnostic := To_Unbounded_String
                       ("symlink entry must be stored: " & To_String (Central_Item.Name));
                     Report.Status := Verify_Metadata_Mismatch;
                     return Verify_Metadata_Mismatch;
                  end if;
                  if not Fits (Data, Central_Item.Local_Offset, 30) then
                     Diagnostic := To_Unbounded_String ("local header offset is invalid for " & To_String (Central_Item.Name));
                     Report.Status := Verify_Invalid_Offset;
                     return Verify_Invalid_Offset;
                  end if;
                  declare
                     Lpos : constant Stream_Element_Offset := Pos_Of (Central_Item.Local_Offset);
                     Version_Needed : Unsigned_16;
                     Flags : Unsigned_16;
                     Method : Unsigned_16;
                     Crc : Unsigned_32;
                     Comp_32 : Unsigned_32;
                     Uncomp_32 : Unsigned_32;
                     Name_Len : Unsigned_16;
                     Extra_Len : Unsigned_16;
                  begin
                     if U32_At (Data, Lpos) /= 16#0403_4B50# then
                        Diagnostic := To_Unbounded_String ("local header signature is invalid for " & To_String (Central_Item.Name));
                        Report.Status := Verify_Invalid_Offset;
                        return Verify_Invalid_Offset;
                     end if;
                     Version_Needed := U16_At (Data, Lpos + 4);
                     Flags := U16_At (Data, Lpos + 6);
                     Method := U16_At (Data, Lpos + 8);
                     Crc := U32_At (Data, Lpos + 14);
                     Comp_32 := U32_At (Data, Lpos + 18);
                     Uncomp_32 := U32_At (Data, Lpos + 22);
                     Name_Len := U16_At (Data, Lpos + 26);
                     Extra_Len := U16_At (Data, Lpos + 28);
                     declare
                        Name_First : constant Stream_Element_Offset := Lpos + 30;
                        Name_Last : constant Stream_Element_Offset := Name_First + Stream_Element_Offset (Name_Len) - 1;
                        Extra_First : constant Stream_Element_Offset := Name_Last + 1;
                        Extra_Last : constant Stream_Element_Offset := Extra_First + Stream_Element_Offset (Extra_Len) - 1;
                        Payload_First : constant Stream_Element_Offset := Extra_Last + 1;
                        Payload_Last : Stream_Element_Offset := Payload_First - 1;
                        Entry_Last    : Stream_Element_Offset := Payload_First - 1;
                        Comp : Unsigned_64 := Unsigned_64 (Comp_32);
                        Uncomp : Unsigned_64 := Unsigned_64 (Uncomp_32);
                        Local_AES_Info : AES_Extra_Info;
                        Dummy_Offset : Unsigned_64 := 0;
                        Found : Boolean;
                        Valid : Boolean;
                        Computed_Crc : Unsigned_32 := 0;
                        Computed_Size : Unsigned_64 := 0;
                        Entry_Content : Unbounded_String;
                     begin
                        if Name_Len = 0 then
                           Diagnostic := To_Unbounded_String ("local header name is empty for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Metadata_Mismatch;
                           return Verify_Metadata_Mismatch;
                        end if;
                        if not Supported_Zip_Version (Version_Needed) then
                           Diagnostic := To_Unbounded_String ("unsupported ZIP version-needed field for local entry " & To_String (Central_Item.Name));
                           Report.Status := Verify_Unsupported_Feature;
                           return Verify_Unsupported_Feature;
                        end if;
                        if Flags /= Central_Item.General_Flags then
                           Diagnostic := To_Unbounded_String ("local and central flags differ for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Metadata_Mismatch;
                           return Verify_Metadata_Mismatch;
                        end if;
                        if not Fits (Data, Unsigned_64 (Name_First), Unsigned_64 (Name_Len) + Unsigned_64 (Extra_Len)) then
                           Diagnostic := To_Unbounded_String ("local header name or extra field is truncated for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Malformed_Zip;
                           return Verify_Malformed_Zip;
                        end if;
                        Local_AES_Info := Parse_AES_Extra (Data, Extra_First, Extra_Last);
                        if Central_Item.Is_AES then
                           if not Local_AES_Info.Present
                             or else not Local_AES_Info.Valid
                             or else Local_AES_Info.Strength /= Central_Item.AES_Strength
                             or else Local_AES_Info.Actual_Method /= Central_Item.Actual_Method
                           then
                              Diagnostic := To_Unbounded_String ("local AES ZIP extra field differs for " & To_String (Central_Item.Name));
                              Report.Status := Verify_Metadata_Mismatch;
                              return Verify_Metadata_Mismatch;
                           end if;
                        elsif Local_AES_Info.Present then
                           Diagnostic := To_Unbounded_String ("unexpected local AES ZIP extra field for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Metadata_Mismatch;
                           return Verify_Metadata_Mismatch;
                        end if;
                        if Payload_First > Pos_Of (Central_Offset) then
                           Diagnostic := To_Unbounded_String ("local header overlaps central directory for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Truncated_Payload;
                           return Verify_Truncated_Payload;
                        end if;
                        declare
                           Local_Name : constant String := Bytes_To_String (Data, Name_First, Name_Last);
                        begin
                           if (if Central_Item.Is_Directory then
                                  Local_Name /= To_String (Central_Item.Name)
                                  and then Local_Name /= To_String (Central_Item.Name) & "/"
                               else
                                  Local_Name /= To_String (Central_Item.Name))
                             or else Method /= Central_Item.Method
                             or else ((Flags and 8) = 0 and then Crc /= Central_Item.Crc32)
                           then
                              Diagnostic := To_Unbounded_String ("local and central metadata differ for " & To_String (Central_Item.Name));
                              Report.Status := Verify_Metadata_Mismatch;
                              return Verify_Metadata_Mismatch;
                           end if;
                        end;
                        if Comp_32 = 16#FFFF_FFFF# or else Uncomp_32 = 16#FFFF_FFFF# then
                           Parse_Zip64_Size_Extra
                             (Data, Extra_First, Extra_Last,
                              Uncomp_32 = 16#FFFF_FFFF#,
                              Comp_32 = 16#FFFF_FFFF#,
                              False, Uncomp, Comp, Dummy_Offset, Found, Valid);
                           if not Valid or else not Found or else Version_Needed /= 45 then
                              Diagnostic := To_Unbounded_String ("local ZIP64 extra field is invalid for " & To_String (Central_Item.Name));
                              Report.Status := Verify_Invalid_Zip64;
                              return Verify_Invalid_Zip64;
                           end if;
                        end if;
                        if (Flags and 8) = 0
                          and then (Comp /= Central_Item.Compressed_Size
                            or else Uncomp /= Central_Item.Uncompressed_Size)
                        then
                           Diagnostic := To_Unbounded_String ("local and central sizes differ for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Metadata_Mismatch;
                           return Verify_Metadata_Mismatch;
                        end if;
                        if not Fits (Data, Unsigned_64 (Payload_First), Central_Item.Compressed_Size) then
                           Diagnostic := To_Unbounded_String ("payload is truncated for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Truncated_Payload;
                           return Verify_Truncated_Payload;
                        end if;
                        if Central_Item.Compressed_Size > 0 then
                           Payload_Last :=
                             Payload_First + Stream_Element_Offset (Central_Item.Compressed_Size) - 1;
                           if Payload_Last >= Pos_Of (Central_Offset) then
                              Diagnostic := To_Unbounded_String ("payload overlaps central directory for " & To_String (Central_Item.Name));
                              Report.Status := Verify_Truncated_Payload;
                              return Verify_Truncated_Payload;
                           end if;
                        end if;
                        Entry_Last := Payload_Last;

                        if (Flags and 8) /= 0 then
                           declare
                              Descriptor_First : constant Stream_Element_Offset := Payload_Last + 1;
                              Has_Signature    : constant Boolean :=
                                Fits (Data, Unsigned_64 (Descriptor_First), 4)
                                and then U32_At (Data, Descriptor_First) = 16#0807_4B50#;
                              Value_First      : constant Stream_Element_Offset :=
                                Descriptor_First + (if Has_Signature then 4 else 0);
                              Descriptor_Last  : constant Stream_Element_Offset :=
                                Value_First
                                + (if Central_Item.Uses_Zip64_Sizes then 19 else 11);
                              Desc_Comp   : Unsigned_64;
                              Desc_Uncomp : Unsigned_64;
                           begin
                              if not Fits
                                  (Data, Unsigned_64 (Value_First),
                                   Unsigned_64 (Descriptor_Last - Value_First + 1))
                                or else U32_At (Data, Value_First) /= Central_Item.Crc32
                              then
                                 Diagnostic := To_Unbounded_String ("data descriptor is invalid for " & To_String (Central_Item.Name));
                                 Report.Status := Verify_Metadata_Mismatch;
                                 return Verify_Metadata_Mismatch;
                              end if;
                              if Central_Item.Uses_Zip64_Sizes then
                                 Desc_Comp := U64_At (Data, Value_First + 4);
                                 Desc_Uncomp := U64_At (Data, Value_First + 12);
                              else
                                 Desc_Comp := Unsigned_64 (U32_At (Data, Value_First + 4));
                                 Desc_Uncomp := Unsigned_64 (U32_At (Data, Value_First + 8));
                              end if;
                              if Desc_Comp /= Central_Item.Compressed_Size
                                or else Desc_Uncomp /= Central_Item.Uncompressed_Size
                              then
                                 Diagnostic := To_Unbounded_String ("data descriptor sizes differ for " & To_String (Central_Item.Name));
                                 Report.Status := Verify_Metadata_Mismatch;
                                 return Verify_Metadata_Mismatch;
                              end if;
                              Entry_Last := Descriptor_Last;
                           end;
                        end if;

                        declare
                           Current_Range : constant Offset_Range :=
                             (First => Central_Item.Local_Offset,
                              Last  => Unsigned_64 (Entry_Last));
                        begin
                           for Previous of Local_Ranges loop
                              if Current_Range.First <= Previous.Last
                                and then Previous.First <= Current_Range.Last
                              then
                                 Diagnostic := To_Unbounded_String
                                   ("local entry ranges overlap for " &
                                    To_String (Central_Item.Name));
                                 Report.Status := Verify_Invalid_Offset;
                                 return Verify_Invalid_Offset;
                              end if;
                           end loop;
                           Local_Ranges.Append (Current_Range);
                        end;

                        declare
                           Encrypted : constant Boolean :=
                             (Central_Item.General_Flags and 1) /= 0;

                           procedure Validate_Stored
                             (Plain_Data  : Stream_Element_Array;
                              Plain_First : Stream_Element_Offset;
                              Plain_Last  : Stream_Element_Offset)
                           is
                           begin
                              Computed_Size :=
                                (if Plain_Last < Plain_First then 0
                                 else Unsigned_64 (Plain_Last - Plain_First + 1));
                              if Computed_Size /= Central_Item.Uncompressed_Size then
                                 Diagnostic := To_Unbounded_String ("stored sizes differ for " & To_String (Central_Item.Name));
                                 Report.Status := Verify_Metadata_Mismatch;
                                 return;
                              end if;
                              if Computed_Size = 0 then
                                 Computed_Crc := 0;
                                 Entry_Content := Null_Unbounded_String;
                              else
                                 declare
                                    Crc_State : Zlib.CRC32_State;
                                 begin
                                    Zlib.CRC32_Reset (Crc_State);
                                    Zlib.CRC32_Update
                                      (Crc_State, Plain_Data (Plain_First .. Plain_Last));
                                    Computed_Crc := Zlib.CRC32_Value (Crc_State);
                                 end;
                                 if To_String (Central_Item.Name) = Backup.Manifest.Manifest_Path
                                   or else (Central_Item.External_Attrs and 16#F000_0000#) = 16#A000_0000#
                                   or else Computed_Size <= 1_000_000
                                 then
                                    if not Can_Stringify (Computed_Size) then
                                       Diagnostic := To_Unbounded_String ("entry content is too large to validate as text: " & To_String (Central_Item.Name));
                                       Report.Status := Verify_Manifest_Mismatch;
                                       return;
                                    end if;
                                    Entry_Content := To_Unbounded_String
                                      (Bytes_To_String (Plain_Data, Plain_First, Plain_Last));
                                 end if;
                              end if;
                           end Validate_Stored;
                        begin
                           if Zlib.Is_ZIP_External_Method
                             (Central_Item.Actual_Method)
                           then
                              declare
                                 Codec_Status : Zlib.Status_Code := Zlib.Ok;
                                 Plain_Zlib : constant Zlib.Byte_Array :=
                                   Zlib.Extract_ZIP_External_Entry
                                     (Bytes_To_Zlib (Data, Data'First, Data'Last),
                                      Archive_Path, To_String (Central_Item.Name),
                                      Zip_Password, Codec_Status);
                                 Plain : constant Stream_Element_Array :=
                                   Zlib_To_Bytes (Plain_Zlib);
                              begin
                                 if Codec_Status /= Zlib.Ok then
                                    Diagnostic := To_Unbounded_String
                                      ("external ZIP codec validation failed for " &
                                       To_String (Central_Item.Name));
                                    Report.Status := Verify_Deflate_Invalid;
                                    return Verify_Deflate_Invalid;
                                 end if;
                                 Validate_Stored (Plain, Plain'First, Plain'Last);
                                 if Report.Status /= Verify_Malformed_Zip
                                   and then Report.Status /= Verify_Ok
                                 then
                                    return Report.Status;
                                 end if;
                              end;
                           elsif Central_Item.Is_AES then
                              declare
                                 Salt_Length : constant Natural :=
                                   AES_Salt_Length (Central_Item.AES_Strength);
                                 Cipher_Length : constant Unsigned_64 :=
                                   Central_Item.Compressed_Size
                                   - Unsigned_64 (Salt_Length + 2 + 10);
                                 Plain : Stream_Element_Array
                                   (1 .. Stream_Element_Offset (Cipher_Length));
                                 Valid_AES : Boolean := False;
                              begin
                                 if Central_Item.Compressed_Size <
                                   Unsigned_64 (Salt_Length + 2 + 10)
                                 then
                                    Diagnostic := To_Unbounded_String ("AES ZIP payload is too short for " & To_String (Central_Item.Name));
                                    Report.Status := Verify_Metadata_Mismatch;
                                    return Verify_Metadata_Mismatch;
                                 end if;
                                 Decrypt_AES_Payload
                                   (Data, Payload_First, Payload_Last,
                                    Central_Item.AES_Strength, Zip_Password,
                                    Plain, Valid_AES);
                                 if not Valid_AES then
                                    Diagnostic := To_Unbounded_String ("AES ZIP entry authentication failed for " & To_String (Central_Item.Name));
                                    Report.Status := Verify_Crc_Mismatch;
                                    return Verify_Crc_Mismatch;
                                 end if;
                                 if Central_Item.Actual_Method = 0 then
                                    Validate_Stored (Plain, Plain'First, Plain'Last);
                                    if Report.Status /= Verify_Malformed_Zip
                                      and then Report.Status /= Verify_Ok
                                    then
                                       return Report.Status;
                                    end if;
                                 else
                                    if not Validate_Deflate_Payload
                                      (Plain, Plain'First, Plain'Last,
                                       Central_Item.Uncompressed_Size,
                                       Computed_Crc, Computed_Size, Entry_Content)
                                    then
                                       Diagnostic := To_Unbounded_String ("deflate validation failed for " & To_String (Central_Item.Name));
                                       Report.Status := Verify_Deflate_Invalid;
                                       return Verify_Deflate_Invalid;
                                    end if;
                                 end if;
                              end;
                           elsif Encrypted then
                              if Central_Item.Compressed_Size < 12 then
                                 Diagnostic := To_Unbounded_String ("encrypted ZIP payload is too short for " & To_String (Central_Item.Name));
                                 Report.Status := Verify_Metadata_Mismatch;
                                 return Verify_Metadata_Mismatch;
                              end if;
                              if not Zipcrypto_Password_Matches
                                (Data, Payload_First, Payload_Last, Zip_Password,
                                 Zipcrypto_Check_Byte
                                   (Central_Item.Crc32, Central_Item.Dos_Time,
                                    Central_Item.General_Flags))
                              then
                                 Diagnostic := To_Unbounded_String ("encrypted ZIP entry password check failed for " & To_String (Central_Item.Name));
                                 Report.Status := Verify_Crc_Mismatch;
                                 return Verify_Crc_Mismatch;
                              end if;
                              declare
                                 Plain : constant Stream_Element_Array :=
                                   Zipcrypto_Decrypt_Data
                                     (Data, Payload_First, Payload_Last, Zip_Password);
                              begin
                                 if Central_Item.Actual_Method = 0 then
                                    Validate_Stored (Plain, Plain'First, Plain'Last);
                                    if Report.Status /= Verify_Malformed_Zip
                                      and then Report.Status /= Verify_Ok
                                    then
                                       return Report.Status;
                                    end if;
                                 else
                                    if not Validate_Deflate_Payload
                                      (Plain, Plain'First, Plain'Last,
                                       Central_Item.Uncompressed_Size,
                                       Computed_Crc, Computed_Size, Entry_Content)
                                    then
                                       Diagnostic := To_Unbounded_String ("deflate validation failed for " & To_String (Central_Item.Name));
                                       Report.Status := Verify_Deflate_Invalid;
                                       return Verify_Deflate_Invalid;
                                    end if;
                                 end if;
                              end;
                           elsif Central_Item.Actual_Method = 0 then
                              Validate_Stored (Data, Payload_First, Payload_Last);
                              if Report.Status /= Verify_Malformed_Zip
                                and then Report.Status /= Verify_Ok
                              then
                                 return Report.Status;
                              end if;
                           else
                              if not Validate_Deflate_Payload
                                (Data, Payload_First, Payload_Last,
                                 Central_Item.Uncompressed_Size,
                                 Computed_Crc, Computed_Size, Entry_Content)
                              then
                                 Diagnostic := To_Unbounded_String ("deflate validation failed for " & To_String (Central_Item.Name));
                                 Report.Status := Verify_Deflate_Invalid;
                                 return Verify_Deflate_Invalid;
                              end if;
                           end if;
                        end;
                        if Computed_Crc /= Central_Item.Crc32 then
                           Diagnostic := To_Unbounded_String ("CRC32 mismatch for " & To_String (Central_Item.Name));
                           Report.Status := Verify_Crc_Mismatch;
                           return Verify_Crc_Mismatch;
                        end if;
                        if To_String (Central_Item.Name) = Backup.Manifest.Manifest_Path then
                           Report.Has_Manifest := True;
                           Manifest := Entry_Content;
                        end if;
                        declare
                           Published_Name : constant String :=
                             (if Central_Item.Is_Directory then
                                 Directory_Archive_Name (To_String (Central_Item.Name))
                              else
                                 To_String (Central_Item.Name));
                        begin
                           Report.Entries.Append
                             (Verified_Entry'(Archive_Path      =>
                                To_Unbounded_String (Published_Name),
                               Kind              =>
                                 (if Published_Name = Backup.Manifest.Manifest_Path then
                                     Entry_Manifest
                                  elsif Central_Item.Is_Directory then
                                     Entry_Directory
                                  elsif (Central_Item.External_Attrs and 16#F000_0000#) = 16#A000_0000# then
                                     Entry_Symlink
                                  else
                                     Entry_File),
                               Method            => Central_Item.Actual_Method,
                               Crc32             => Central_Item.Crc32,
                               Compressed_Size   => Central_Item.Compressed_Size,
                               Uncompressed_Size => Central_Item.Uncompressed_Size,
                               Local_Offset      => Central_Item.Local_Offset,
                               Dos_Time          => Central_Item.Dos_Time,
                               Dos_Date          => Central_Item.Dos_Date,
                               External_Attrs    => Central_Item.External_Attrs,
                               Has_Owner         => Central_Item.Has_Owner,
                               Owner_UID         => Central_Item.Owner_UID,
                               Owner_GID         => Central_Item.Owner_GID,
                               Xattr_Blob        => Central_Item.Xattr_Blob,
                               Link_Target       =>
                                 (if (Central_Item.External_Attrs and 16#F000_0000#) = 16#A000_0000# then
                                     Entry_Content
                                  else
                                     Null_Unbounded_String)));
                        end;
                     end;
                  end;
               end loop;
            end;
         end;

      if Report.Has_Manifest then
         declare
            Text            : constant String := To_String (Manifest);
            Manifest_Count  : constant Natural :=
              Count_Text
                (Text,
                 Q ("source") & ": " & Q ("<normalized-input>") &
                 ", " & Q ("archive_path") & ": ");
            Expected_Count  : Natural := 0;
         begin
            if not Contains_Text
              (Text, Q ("format") & ": " & Q ("backup-manifest-v1"))
            then
               Diagnostic := To_Unbounded_String
                 ("manifest has unsupported or missing format marker");
               Report.Status := Verify_Manifest_Mismatch;
               return Verify_Manifest_Mismatch;
            end if;

            if not Contains_Text
              (Text, Q ("manifest_path") & ": " & Q (Backup.Manifest.Manifest_Path))
            then
               Diagnostic := To_Unbounded_String
                 ("manifest path marker does not match backup manifest path");
               Report.Status := Verify_Manifest_Mismatch;
               return Verify_Manifest_Mismatch;
            end if;

            if not Contains_Text
              (Text, Q ("manifest_method") & ": " & Q ("stored"))
            then
               Diagnostic := To_Unbounded_String
                 ("manifest method marker does not match stored manifest method");
               Report.Status := Verify_Manifest_Mismatch;
               return Verify_Manifest_Mismatch;
            end if;

            for Item of Report.Entries loop
               if Item.Kind /= Entry_Manifest then
                  Expected_Count := Expected_Count + 1;
                  declare
                     Name : constant String := To_String (Item.Archive_Path);
                  begin
                     if not Manifest_Entry_Matches (Text, Item) then
                        Diagnostic := To_Unbounded_String
                          ("manifest does not match archive entry: " & Name);
                        Report.Status := Verify_Manifest_Mismatch;
                        return Verify_Manifest_Mismatch;
                     end if;
                  end;
               end if;
            end loop;

            if Manifest_Count /= Expected_Count then
               Diagnostic := To_Unbounded_String
                 ("manifest entry count does not match archive entry count");
               Report.Status := Verify_Manifest_Mismatch;
               return Verify_Manifest_Mismatch;
            end if;

            Report.Manifest_OK := True;
         end;
      end if;

      Report.Status := Verify_Ok;
      Diagnostic := To_Unbounded_String ("archive verification ok");
      return Verify_Ok;
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("archive could not be parsed");
         Report.Status := Verify_Malformed_Zip;
         return Verify_Malformed_Zip;
   end Verify_Archive;

   procedure Build_Human_Report
     (Report : Verification_Report;
      Text   : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String ("backup verify" & ASCII.LF);
      Append (Text, "status: ");
      Append (Text, Status_Text (Report.Status));
      Append (Text, ASCII.LF);
      Append (Text, "zip64: ");
      Append (Text, (if Report.Has_Zip64 then
                        "yes"
                     else
                        "no"));
      Append (Text, ASCII.LF);
      Append (Text, "manifest: ");
      if Report.Has_Manifest then
         Append (Text, (if Report.Manifest_OK then
                           "ok"
                        else
                           "present"));
      else
         Append (Text, "absent");
      end if;
      Append (Text, ASCII.LF);
      Append (Text, "verified entries:" & ASCII.LF);
      for Item of Report.Entries loop
         Append (Text, "  verify ");
         Append (Text, To_String (Item.Archive_Path));
         Append (Text, " method=");
         Append (Text, Method_Name (Item.Method));
         Append (Text, " crc32=");
         Append (Text, Decimal (Unsigned_64 (Item.Crc32)));
         Append (Text, " compressed_size=");
         Append (Text, Decimal (Item.Compressed_Size));
         Append (Text, " uncompressed_size=");
         Append (Text, Decimal (Item.Uncompressed_Size));
         Append_Human_Metadata (Text, Item);
         if Item.Kind = Entry_Symlink then
            Append (Text, " link-target=");
            Append (Text, To_String (Item.Link_Target));
         end if;
         Append (Text, ASCII.LF);
      end loop;
   end Build_Human_Report;

   procedure Build_JSON_Report
     (Report : Verification_Report;
      Text   : out Unbounded_String)
   is
      First : Boolean := True;
   begin
      Text := To_Unbounded_String ("{" & ASCII.LF);
      Append (Text, "  " & Q ("format") & ": " & Q ("backup-verify-v1") & "," & ASCII.LF);
      Append (Text, "  " & Q ("status") & ": " & Q (Status_Text (Report.Status)) & "," & ASCII.LF);
      Append (Text, "  " & Q ("ok") & ": ");
      Append (Text, (if Report.Status = Verify_Ok then
                        "true"
                     else
                        "false"));
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("zip64") & ": ");
      Append (Text, (if Report.Has_Zip64 then
                        "true"
                     else
                        "false"));
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("manifest") & ": {");
      Append (Text, Q ("present") & ": ");
      Append (Text, (if Report.Has_Manifest then
                        "true"
                     else
                        "false"));
      Append (Text, ", " & Q ("ok") & ": ");
      Append (Text, (if Report.Manifest_OK then
                        "true"
                     else
                        "false"));
      Append (Text, "}," & ASCII.LF);
      Append (Text, "  " & Q ("entries") & ": [" & ASCII.LF);
      for Item of Report.Entries loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_path") & ": " & Q (To_String (Item.Archive_Path)));
         Append (Text, ", " & Q ("kind") & ": ");
         case Item.Kind is
            when Entry_File => Append (Text, Q ("file"));
            when Entry_Directory => Append (Text, Q ("directory"));
            when Entry_Symlink => Append (Text, Q ("symlink"));
            when Entry_Manifest => Append (Text, Q ("manifest"));
         end case;
         Append (Text, ", " & Q ("compression_method") & ": " & Q (Method_Name (Item.Method)));
         Append (Text, ", " & Q ("crc32") & ": " & Decimal (Unsigned_64 (Item.Crc32)));
         Append (Text, ", " & Q ("compressed_size") & ": " & Decimal (Item.Compressed_Size));
         Append (Text, ", " & Q ("uncompressed_size") & ": " & Decimal (Item.Uncompressed_Size));
         Append_JSON_Metadata (Text, Item);
         if Item.Kind = Entry_Symlink then
            Append (Text, ", " & Q ("link_target") & ": " & Q (To_String (Item.Link_Target)));
         end if;
         Append (Text, "}");
      end loop;
      Append (Text, ASCII.LF & "  ]" & ASCII.LF);
      Append (Text, "}" & ASCII.LF);
   end Build_JSON_Report;

   procedure Build_List_Human_Report
     (Report : Verification_Report;
      Text   : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String ("backup list" & ASCII.LF);
      Append (Text, "status: ");
      Append (Text, Status_Text (Report.Status));
      Append (Text, ASCII.LF);
      Append (Text, "entries:" & ASCII.LF);
      for Item of Report.Entries loop
         Append (Text, "  ");
         case Item.Kind is
            when Entry_File => Append (Text, "file ");
            when Entry_Directory => Append (Text, "directory ");
            when Entry_Symlink => Append (Text, "symlink ");
            when Entry_Manifest => Append (Text, "manifest ");
         end case;
         Append (Text, To_String (Item.Archive_Path));
         Append (Text, " size=");
         Append (Text, Decimal (Item.Uncompressed_Size));
         Append (Text, " compressed_size=");
         Append (Text, Decimal (Item.Compressed_Size));
         Append (Text, " method=");
         Append (Text, Method_Name (Item.Method));
         Append_Human_Metadata (Text, Item);
         if Item.Kind = Entry_Symlink then
            Append (Text, " link-target=");
            Append (Text, To_String (Item.Link_Target));
         end if;
         Append (Text, ASCII.LF);
      end loop;
   end Build_List_Human_Report;

   procedure Build_List_JSON_Report
     (Report : Verification_Report;
      Text   : out Unbounded_String)
   is
      First : Boolean := True;
   begin
      Text := To_Unbounded_String ("{" & ASCII.LF);
      Append (Text, "  " & Q ("format") & ": " & Q ("backup-list-v1") & "," & ASCII.LF);
      Append (Text, "  " & Q ("status") & ": " & Q (Status_Text (Report.Status)) & "," & ASCII.LF);
      Append (Text, "  " & Q ("ok") & ": ");
      Append (Text, (if Report.Status = Verify_Ok then
                        "true"
                     else
                        "false"));
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("entries") & ": [" & ASCII.LF);
      for Item of Report.Entries loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_path") & ": " & Q (To_String (Item.Archive_Path)));
         Append (Text, ", " & Q ("kind") & ": ");
         case Item.Kind is
            when Entry_File => Append (Text, Q ("file"));
            when Entry_Directory => Append (Text, Q ("directory"));
            when Entry_Symlink => Append (Text, Q ("symlink"));
            when Entry_Manifest => Append (Text, Q ("manifest"));
         end case;
         Append (Text, ", " & Q ("compression_method") & ": " & Q (Method_Name (Item.Method)));
         Append (Text, ", " & Q ("compressed_size") & ": " & Decimal (Item.Compressed_Size));
         Append (Text, ", " & Q ("uncompressed_size") & ": " & Decimal (Item.Uncompressed_Size));
         Append_JSON_Metadata (Text, Item);
         if Item.Kind = Entry_Symlink then
            Append (Text, ", " & Q ("link_target") & ": " & Q (To_String (Item.Link_Target)));
         end if;
         Append (Text, "}");
      end loop;
      Append (Text, ASCII.LF & "  ]" & ASCII.LF);
      Append (Text, "}" & ASCII.LF);
   end Build_List_JSON_Report;

end Backup.Verify;
