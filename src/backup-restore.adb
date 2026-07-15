with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with CryptoLib.Ciphers;
with CryptoLib.Errors;
with CryptoLib.Macs;
with Interfaces;
with CryptoLib.Checksums;
with Zlib;


with Backup.Encryption;
with Backup.Platform;
with Backup.Restore_Syntax;
with Backup.Zip_Images;
with GNAT.OS_Lib;

package body Backup.Restore is
   use Ada.Streams;

   Restore_Chunk_Size : constant Stream_Element_Count := 16#4000#;
   use Ada.Streams.Stream_IO;
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Backup.CLI.Symlink_Mode;
   use type Backup.CLI.Restore_Conflict_Mode;
   use type Backup.Verify.Verify_Status;
   use type Backup.Verify.Entry_Kind;
   use type Backup.Encryption.Envelope_Status;
   use type Backup.Encryption.Password_Source_Kind;
   use type Ada.Directories.File_Kind;
   use type CryptoLib.Errors.Status;
   use type Zlib.Status_Code;

   function Status_Text (Status : Restore_Status) return String is
   begin
      return Backup.Restore_Syntax.Status_Text (Status);
   end Status_Text;

   function Decimal (Value : Unsigned_64) return String is
      Image : constant String := Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

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
            when '"' => Append_Escape (Result, '"');
            when '\' => Append_Escape (Result, '\');
            when ASCII.BS => Append_Escape (Result, 'b');
            when ASCII.HT => Append_Escape (Result, 't');
            when ASCII.LF => Append_Escape (Result, 'n');
            when ASCII.FF => Append_Escape (Result, 'f');
            when ASCII.CR => Append_Escape (Result, 'r');
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


   function U16_At
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return Unsigned_16
   is
   begin
      return Unsigned_16 (Data (Pos))
        or Shift_Left (Unsigned_16 (Data (Pos + 1)), 8);
   end U16_At;

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

   function Local_Payload_First
     (Data : Stream_Element_Array;
      Item : Backup.Verify.Verified_Entry;
      Pos  : out Stream_Element_Offset)
      return Boolean
   is
      Local : constant Stream_Element_Offset :=
        Stream_Element_Offset (Item.Local_Offset);
      Name_Len  : Unsigned_16;
      Extra_Len : Unsigned_16;
   begin
      if not Fits (Data, Item.Local_Offset, 30) then
         return False;
      end if;
      Name_Len := U16_At (Data, Local + 26);
      Extra_Len := U16_At (Data, Local + 28);
      Pos := Local + 30 + Stream_Element_Offset (Name_Len)
        + Stream_Element_Offset (Extra_Len);
      return Fits (Data, Unsigned_64 (Pos), Item.Compressed_Size);
   end Local_Payload_First;

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



   type AES_Extra_Info is record
      Present       : Boolean := False;
      Valid         : Boolean := False;
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
                    (Present       => True,
                     Valid         => AES_Key_Length (Strength) /= 0,
                     Strength      => Strength,
                     Actual_Method => U16_At (Data, Body_Pos + 5));
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

   function Is_Symbolic_Link (Path : String) return Boolean is
   begin
      return GNAT.OS_Lib.Is_Symbolic_Link (Path);
   exception
      when others =>
         return False;
   end Is_Symbolic_Link;

   function Existing_Component_Is_Symlink
     (Path       : String;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Current       : Unbounded_String;
      Segment_Start : Positive := Path'First;
   begin
      Diagnostic := Null_Unbounded_String;

      if Path'Length = 0 then
         return False;
      end if;

      if Path (Path'First) = '/' then
         Current := To_Unbounded_String ("/");
         Segment_Start := Path'First + 1;
      else
         Current := To_Unbounded_String (".");
      end if;

      for Index in Segment_Start .. Path'Last + 1 loop
         if Index = Path'Last + 1 or else Path (Index) = '/' then
            if Index > Segment_Start then
               if To_String (Current) = "/" then
                  Current := To_Unbounded_String
                    ("/" & Path (Segment_Start .. Index - 1));
               else
                  Current := To_Unbounded_String
                    (Ada.Directories.Compose
                       (To_String (Current), Path (Segment_Start .. Index - 1)));
               end if;

               if Ada.Directories.Exists (To_String (Current))
                 and then Is_Symbolic_Link (To_String (Current))
               then
                  Diagnostic := To_Unbounded_String
                    ("target path component is a symbolic link: " & To_String (Current));
                  return True;
               end if;
            end if;
            Segment_Start := Index + 1;
         end if;
      end loop;

      return False;
   end Existing_Component_Is_Symlink;

   function Existing_Ancestor_Is_Symlink
     (Output_Dir   : String;
      Archive_Path : String;
      Diagnostic   : out Unbounded_String)
      return Boolean
   is
      Current       : Unbounded_String := To_Unbounded_String (Output_Dir);
      Segment_Start : Positive := Archive_Path'First;
   begin
      Diagnostic := Null_Unbounded_String;

      if Ada.Directories.Exists (Output_Dir)
        and then Is_Symbolic_Link (Output_Dir)
      then
         Diagnostic := To_Unbounded_String
           ("output directory is a symbolic link: " & Output_Dir);
         return True;
      end if;

      for Index in Archive_Path'Range loop
         if Archive_Path (Index) = '/' then
            Current := To_Unbounded_String
              (Ada.Directories.Compose
                 (To_String (Current), Archive_Path (Segment_Start .. Index - 1)));
            if Ada.Directories.Exists (To_String (Current))
              and then Is_Symbolic_Link (To_String (Current))
            then
               Diagnostic := To_Unbounded_String
                 ("destination parent is a symbolic link: " & To_String (Current));
               return True;
            end if;
            Segment_Start := Index + 1;
         end if;
      end loop;

      return False;
   end Existing_Ancestor_Is_Symlink;

   function Destination_Path
     (Output_Dir   : String;
      Archive_Path : String)
      return String
   is
      Result        : Unbounded_String := To_Unbounded_String (Output_Dir);
      Segment_Start : Positive := Archive_Path'First;
   begin
      for Index in Archive_Path'Range loop
         if Archive_Path (Index) = '/' then
            Result := To_Unbounded_String
              (Ada.Directories.Compose
                 (To_String (Result), Archive_Path (Segment_Start .. Index - 1)));
            Segment_Start := Index + 1;
         end if;
      end loop;
      return Ada.Directories.Compose
        (To_String (Result), Archive_Path (Segment_Start .. Archive_Path'Last));
   end Destination_Path;

   function Parent_Directory (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when others =>
         return ".";
   end Parent_Directory;

   procedure Remove_Partial_File (Path : String) is
   begin
      if Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File
      then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Remove_Partial_File;

   function Inflate_Deflate_Payload
     (Data            : Stream_Element_Array;
      Payload_First   : Stream_Element_Offset;
      Payload_Last    : Stream_Element_Offset;
      Output          : in out File_Type;
      Computed_Crc    : out Unsigned_32;
      Computed_Uncomp : out Unsigned_64)
      return Boolean
   is
      Filter      : Zlib.Filter_Type;
      Next_Input  : Stream_Element_Offset := Payload_First;
      Prior_Input : Stream_Element_Offset := Payload_First - 1;
      In_Last     : Stream_Element_Offset;
      Out_Last    : Stream_Element_Offset;
      Out_Data    : Stream_Element_Array (1 .. Restore_Chunk_Size);
      Crc_State   : CryptoLib.Checksums.CRC32_State;
   begin
      Computed_Crc := 0;
      Computed_Uncomp := 0;
      CryptoLib.Checksums.CRC32_Reset (Crc_State);
      Zlib.Inflate_Init (Filter, Header => Zlib.Raw_Deflate);

      while not Zlib.Stream_End (Filter) loop
         Prior_Input := Next_Input;
         if Next_Input <= Payload_Last then
            Zlib.Translate
              (Filter, Data (Next_Input .. Payload_Last), In_Last,
               Out_Data, Out_Last, Zlib.Finish);
            if In_Last >= Next_Input then
               Next_Input := In_Last + 1;
            end if;
         else
            Zlib.Flush (Filter, Out_Data, Out_Last, Zlib.Finish);
         end if;

         if Out_Last >= Out_Data'First then
            Write (Output, Out_Data (Out_Data'First .. Out_Last));
            CryptoLib.Checksums.CRC32_Update
              (Crc_State, Out_Data (Out_Data'First .. Out_Last));
            Computed_Uncomp :=
              Computed_Uncomp + Unsigned_64 (Out_Last - Out_Data'First + 1);
         elsif Next_Input = Prior_Input and then not Zlib.Stream_End (Filter) then
            Zlib.Close (Filter, Ignore_Error => True);
            return False;
         end if;
      end loop;

      if Next_Input <= Payload_Last then
         Zlib.Close (Filter, Ignore_Error => True);
         return False;
      end if;

      Computed_Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
      Zlib.Close (Filter);
      return True;
   exception
      when others =>
         Zlib.Close (Filter, Ignore_Error => True);
         Computed_Crc := 0;
         Computed_Uncomp := 0;
         return False;
   end Inflate_Deflate_Payload;

   procedure Delete_If_Exists (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Delete_If_Exists;



   function Blob_U16 (Blob : String; Pos : Positive) return Unsigned_16 is
   begin
      return Unsigned_16 (Character'Pos (Blob (Pos)))
        or Shift_Left (Unsigned_16 (Character'Pos (Blob (Pos + 1))), 8);
   end Blob_U16;

   function Blob_U32 (Blob : String; Pos : Positive) return Unsigned_32 is
   begin
      return Unsigned_32 (Character'Pos (Blob (Pos)))
        or Shift_Left (Unsigned_32 (Character'Pos (Blob (Pos + 1))), 8)
        or Shift_Left (Unsigned_32 (Character'Pos (Blob (Pos + 2))), 16)
        or Shift_Left (Unsigned_32 (Character'Pos (Blob (Pos + 3))), 24);
   end Blob_U32;

   procedure Apply_Xattrs
     (Path : String;
      Blob : Unbounded_String)
   is
      Data : constant String := To_String (Blob);
      Pos  : Positive := Data'First + 2;
   begin
      if Data'Length < 2 then
         return;
      end if;

      for I in 1 .. Natural (Blob_U16 (Data, Data'First)) loop
         exit when Pos + 5 > Data'Last;
         declare
            Name_Length  : constant Natural := Natural (Blob_U16 (Data, Pos));
            Value_Length : constant Natural := Natural (Blob_U32 (Data, Pos + 2));
            Name_First   : constant Positive := Pos + 6;
            Name_Last    : constant Natural := Name_First + Name_Length - 1;
            Value_First  : constant Positive := Name_First + Name_Length;
            Value_Last   : constant Natural := Value_First + Value_Length - 1;
         begin
            exit when Name_Length = 0 or else Name_Last > Data'Last;
            exit when Value_Length > 0 and then Value_Last > Data'Last;
            declare
               Name : constant String := Data (Name_First .. Name_Last);
               Ignored : Natural;
               pragma Unreferenced (Ignored);
            begin
               if Value_Length = 0 then
                  Ignored := (if Backup.Platform.Set_Xattr (Path, Name, "") then 0 else 1);
               else
                  declare
                     Value : constant String := Data (Value_First .. Value_Last);
                  begin
                     Ignored := (if Backup.Platform.Set_Xattr (Path, Name, Value) then 0 else 1);
                  end;
               end if;
            exception
               when others =>
                  null;
            end;
            Pos := Value_First + Value_Length;
         end;
      end loop;
   exception
      when others =>
         null;
   end Apply_Xattrs;

   procedure Apply_File_Metadata
     (Path : String;
      Item : Backup.Verify.Verified_Entry)
   is
      Mode_Value : constant Unsigned_32 :=
        Shift_Right (Item.External_Attrs, 16) and 16#0FFF#;
      Year  : constant GNAT.OS_Lib.Year_Type :=
        GNAT.OS_Lib.Year_Type (1980 + Shift_Right (Item.Dos_Date, 9));
      Month : constant GNAT.OS_Lib.Month_Type :=
        GNAT.OS_Lib.Month_Type ((Shift_Right (Item.Dos_Date, 5) and 16#000F#));
      Day   : constant GNAT.OS_Lib.Day_Type :=
        GNAT.OS_Lib.Day_Type (Item.Dos_Date and 16#001F#);
      Hour  : constant GNAT.OS_Lib.Hour_Type :=
        GNAT.OS_Lib.Hour_Type (Shift_Right (Item.Dos_Time, 11));
      Min   : constant GNAT.OS_Lib.Minute_Type :=
        GNAT.OS_Lib.Minute_Type ((Shift_Right (Item.Dos_Time, 5) and 16#003F#));
      Sec   : constant GNAT.OS_Lib.Second_Type :=
        GNAT.OS_Lib.Second_Type ((Item.Dos_Time and 16#001F#) * 2);
   begin
      if Item.Has_Owner then
         Backup.Platform.Apply_Owner (Path, Item.Owner_UID, Item.Owner_GID);
      end if;

      Apply_Xattrs (Path, Item.Xattr_Blob);

      if Mode_Value /= 0 then
         Backup.Platform.Apply_Mode (Path, Mode_Value);
      end if;

      GNAT.OS_Lib.Set_File_Last_Modify_Time_Stamp
        (Path, GNAT.OS_Lib.GM_Time_Of (Year, Month, Day, Hour, Min, Sec));
   exception
      when others =>
         null;
   end Apply_File_Metadata;


   function Counter_Text (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Counter_Text;


   function Unique_Rename_Path (Path : String) return String is
   begin
      for Counter in Natural range 0 .. 10_000 loop
         declare
            Candidate : constant String :=
              Path & ".existing." & Counter_Text (Counter);
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;
      return Path & ".existing.overflow";
   end Unique_Rename_Path;

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



   function Selected_For_Restore
     (Config       : Backup.CLI.Configuration;
      Archive_Path : String)
      return Boolean
   is
      Included : Boolean := Config.Restore_Only.Is_Empty;
   begin
      for Filter of Config.Restore_Only loop
         if Backup.Restore_Syntax.Path_Matches_Filter (Filter, Archive_Path) then
            Included := True;
         end if;
      end loop;

      if not Included then
         return False;
      end if;

      for Filter of Config.Restore_Exclude loop
         if Backup.Restore_Syntax.Path_Matches_Filter (Filter, Archive_Path) then
            return False;
         end if;
      end loop;

      return True;
   end Selected_For_Restore;

   function Extract_Archive
     (Config     : Backup.CLI.Configuration;
      Report     : out Restore_Report;
      Diagnostic : out Unbounded_String)
      return Restore_Status
   is
      Verify_Status : Backup.Verify.Verify_Status;
      Disk_Starts   : Backup.Zip_Images.Disk_Start_Vectors.Vector;
      Read_Ok       : Boolean := False;
      Output_Dir    : constant String := To_String (Config.Output_Dir);
      Archive_Name  : constant String := To_String (Config.Output_Path);
      Work_Archive  : Unbounded_String := To_Unbounded_String (Archive_Name);
      Temporary_Work_Archive : Boolean := False;
      Output_Path_Unsafe : Boolean := False;
      Output_Path_Diag   : Unbounded_String := Null_Unbounded_String;
      Zip_Password       : Unbounded_String := Null_Unbounded_String;

      procedure Cleanup_Temporary is
      begin
         if Temporary_Work_Archive then
            Delete_If_Exists (To_String (Work_Archive));
            Temporary_Work_Archive := False;
         end if;
      end Cleanup_Temporary;
   begin
      Report := (Status       => Restore_Internal_Error,
                 Dry_Run      => Config.Dry_Run,
                 Archive_Path => Config.Output_Path,
                 Output_Dir   => Config.Output_Dir,
                 Items        => Item_Vectors.Empty_Vector,
                 Verify       => (Status       => Backup.Verify.Verify_Malformed_Zip,
                                  Entries      => Backup.Verify.Entry_Vectors.Empty_Vector,
                                  Has_Zip64    => False,
                                  Has_Manifest => False,
                                  Manifest_OK  => False));
      Diagnostic := Null_Unbounded_String;

      if Backup.Encryption.Is_Encrypted (Archive_Name) then
         declare
            Envelope_Status : Backup.Encryption.Envelope_Status;
         begin
            Work_Archive := To_Unbounded_String
              (Unique_Temp_Path (Archive_Name, ".phase19-decrypted.zip"));
            Envelope_Status := Backup.Encryption.Decrypt_File
              (Archive_Name, To_String (Work_Archive),
               Config.Password, Diagnostic);
            if Envelope_Status /= Backup.Encryption.Envelope_Ok then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Encryption.Status_Text (Envelope_Status));
               end if;
               Report.Status := Restore_Verify_Failed;
               Cleanup_Temporary;
               return Restore_Verify_Failed;
            end if;
            Temporary_Work_Archive := True;
         end;
      end if;

      if Config.Password.Kind /= Backup.Encryption.Password_None then
         declare
            Password_Status : constant Backup.Encryption.Envelope_Status :=
              Backup.Encryption.Resolve_Password
                (Config.Password, Zip_Password, Diagnostic);
         begin
            if Password_Status /= Backup.Encryption.Envelope_Ok then
               Report.Status := Restore_Verify_Failed;
               Cleanup_Temporary;
               return Restore_Verify_Failed;
            end if;
         end;
      end if;

      Verify_Status := Backup.Verify.Verify_Archive
        (To_String (Work_Archive), To_String (Zip_Password),
         Report.Verify, Diagnostic);
      if Verify_Status /= Backup.Verify.Verify_Ok then
         if Temporary_Work_Archive then
            Delete_If_Exists (To_String (Work_Archive));
         end if;
         Report.Status := Restore_Verify_Failed;
         Cleanup_Temporary;
         return Restore_Verify_Failed;
      end if;

      Output_Path_Unsafe := Existing_Component_Is_Symlink
        (Output_Dir, Output_Path_Diag);

      if Output_Path_Unsafe and then not Config.Dry_Run then
         Diagnostic := To_Unbounded_String
           ("--output-dir path is unsafe: " & To_String (Output_Path_Diag));
         Report.Status := Restore_Target_Error;
         Cleanup_Temporary;
         return Restore_Target_Error;
      end if;

      if not Config.Dry_Run then
         begin
            if Ada.Directories.Exists (Output_Dir) then
               if Ada.Directories.Kind (Output_Dir) /= Ada.Directories.Directory then
                  Diagnostic := To_Unbounded_String
                    ("--output-dir is not a directory: " & Output_Dir);
                  Report.Status := Restore_Target_Error;
                  Cleanup_Temporary;
                  return Restore_Target_Error;
               end if;
            else
               Ada.Directories.Create_Path (Output_Dir);
            end if;
         exception
            when others =>
               Diagnostic := To_Unbounded_String
                 ("could not create or inspect --output-dir: " & Output_Dir);
               Report.Status := Restore_Target_Error;
               Cleanup_Temporary;
               return Restore_Target_Error;
         end;
      end if;

      declare
         Data : constant Stream_Element_Array :=
           Backup.Zip_Images.Read_Logical_Zip
             (To_String (Work_Archive), Disk_Starts, Diagnostic, Read_Ok);
      begin
         if not Read_Ok then
            if Length (Diagnostic) = 0 then
               Diagnostic := To_Unbounded_String ("archive read failed");
            end if;
            Report.Status := Restore_Read_Error;
            Cleanup_Temporary;
            return Restore_Read_Error;
         end if;

         for Item of Report.Verify.Entries loop
            if Item.Kind /= Backup.Verify.Entry_Manifest
              and then not Selected_For_Restore
                (Config, To_String (Item.Archive_Path))
            then
               Report.Items.Append
                 (Restore_Item'(Archive_Path => Item.Archive_Path,
                   Kind         => Item.Kind,
                   Action       => Backup.Restore_Syntax.Report_Action (Action_Skip, Config.Dry_Run),
                   Destination  => To_Unbounded_String
                     (Destination_Path (Output_Dir, To_String (Item.Archive_Path))),
                   Reason       => To_Unbounded_String
                     ("not selected by restore filters")));
            else

            if Item.Kind = Backup.Verify.Entry_Manifest then
               Report.Items.Append
                 (Restore_Item'(Archive_Path => Item.Archive_Path,
                   Kind         => Item.Kind,
                   Action       => Backup.Restore_Syntax.Report_Action (Action_Skip, Config.Dry_Run),
                   Destination  => Null_Unbounded_String,
                   Reason       => To_Unbounded_String ("manifest metadata is validated but not restored")));
            elsif Item.Kind = Backup.Verify.Entry_Directory then
               declare
                  Dest : constant String := Destination_Path
                    (Output_Dir, To_String (Item.Archive_Path));
               begin
                  if Config.Dry_Run and then Output_Path_Unsafe then
                     Diagnostic := To_Unbounded_String
                       ("--output-dir path is unsafe: " & To_String (Output_Path_Diag));
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Action_Would_Reject,
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Diagnostic));
                  elsif Existing_Ancestor_Is_Symlink
                    (Output_Dir, To_String (Item.Archive_Path), Diagnostic)
                  then
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Diagnostic));
                     if not Config.Dry_Run then
                        Report.Status := Restore_Target_Error;
                        Cleanup_Temporary;
                        return Restore_Target_Error;
                     end if;
                  elsif Ada.Directories.Exists (Dest) then
                     if Ada.Directories.Kind (Dest) = Ada.Directories.Directory
                       and then not Is_Symbolic_Link (Dest)
                     then
                        Report.Items.Append
                          (Restore_Item'(Archive_Path => Item.Archive_Path,
                            Kind         => Item.Kind,
                            Action       => Backup.Restore_Syntax.Report_Action (Action_Skip, Config.Dry_Run),
                            Destination  => To_Unbounded_String (Dest),
                            Reason       => To_Unbounded_String ("directory already exists")));
                     else
                        Diagnostic := To_Unbounded_String
                          ("destination cannot be created as a directory: " & Dest);
                        Report.Items.Append
                          (Restore_Item'(Archive_Path => Item.Archive_Path,
                            Kind         => Item.Kind,
                            Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                            Destination  => To_Unbounded_String (Dest),
                            Reason       => Diagnostic));
                        if not Config.Dry_Run then
                           Report.Status := Restore_Existing_Path;
                           Cleanup_Temporary;
                           return Restore_Existing_Path;
                        end if;
                     end if;
                  else
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Backup.Restore_Syntax.Report_Action (Action_Restore, Config.Dry_Run),
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Null_Unbounded_String));
                     if not Config.Dry_Run then
                        Ada.Directories.Create_Path (Dest);
                     end if;
                  end if;
               end;
            elsif Item.Kind = Backup.Verify.Entry_Symlink then
               declare
                  Dest : constant String := Destination_Path
                    (Output_Dir, To_String (Item.Archive_Path));
                  Target : constant String := To_String (Item.Link_Target);
               begin
                  if Config.Symlinks = Backup.CLI.Symlinks_Skip then
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Backup.Restore_Syntax.Report_Action (Action_Skip, Config.Dry_Run),
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => To_Unbounded_String ("symlink restoration skipped by default")));
                  elsif not Backup.Restore_Syntax.Symlink_Target_Is_Safe (Target) then
                     Diagnostic := To_Unbounded_String
                       ("unsafe symlink target for " & To_String (Item.Archive_Path) & ": " & Target);
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Diagnostic));
                     if not Config.Dry_Run then
                        Report.Status := Restore_Unsafe_Symlink;
                        Cleanup_Temporary;
                        return Restore_Unsafe_Symlink;
                     end if;
                  else
                     declare
                        Parent : constant String := Parent_Directory (Dest);
                        Can_Write : Boolean := True;
                     begin
                        if Existing_Ancestor_Is_Symlink
                          (Output_Dir, To_String (Item.Archive_Path), Diagnostic)
                        then
                           Can_Write := False;
                           Report.Items.Append
                             (Restore_Item'(Archive_Path => Item.Archive_Path,
                               Kind         => Item.Kind,
                               Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                               Destination  => To_Unbounded_String (Dest),
                               Reason       => Diagnostic));
                           if not Config.Dry_Run then
                              Report.Status := Restore_Target_Error;
                              Cleanup_Temporary;
                              return Restore_Target_Error;
                           end if;
                        elsif Ada.Directories.Exists (Dest) then
                           case Config.Restore_Conflict is
                              when Backup.CLI.Conflict_Skip =>
                                 Can_Write := False;
                                 Diagnostic := To_Unbounded_String
                                   ("destination already exists: " & Dest);
                                 Report.Items.Append
                                   (Restore_Item'(Archive_Path => Item.Archive_Path,
                                     Kind         => Item.Kind,
                                     Action       => Backup.Restore_Syntax.Report_Action (Action_Skip, Config.Dry_Run),
                                     Destination  => To_Unbounded_String (Dest),
                                     Reason       => Diagnostic));
                              when Backup.CLI.Conflict_Rename =>
                                 declare
                                    Renamed_To : constant String := Unique_Rename_Path (Dest);
                                 begin
                                    Report.Items.Append
                                      (Restore_Item'(Archive_Path => Item.Archive_Path,
                                        Kind         => Item.Kind,
                                        Action       => Backup.Restore_Syntax.Report_Action (Action_Restore, Config.Dry_Run),
                                        Destination  => To_Unbounded_String (Dest),
                                        Reason       => To_Unbounded_String
                                          ("existing destination renamed to " & Renamed_To)));
                                    if not Config.Dry_Run then
                                       Ada.Directories.Rename (Dest, Renamed_To);
                                    end if;
                                 end;
                              when others =>
                                 Can_Write := False;
                                 Diagnostic := To_Unbounded_String
                                   ("destination already exists: " & Dest);
                                 Report.Items.Append
                                   (Restore_Item'(Archive_Path => Item.Archive_Path,
                                     Kind         => Item.Kind,
                                     Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                                     Destination  => To_Unbounded_String (Dest),
                                     Reason       => Diagnostic));
                                 if not Config.Dry_Run then
                                    Report.Status := Restore_Existing_Path;
                                    Cleanup_Temporary;
                                    return Restore_Existing_Path;
                                 end if;
                           end case;
                        else
                           Report.Items.Append
                             (Restore_Item'(Archive_Path => Item.Archive_Path,
                               Kind         => Item.Kind,
                               Action       => Backup.Restore_Syntax.Report_Action (Action_Restore, Config.Dry_Run),
                               Destination  => To_Unbounded_String (Dest),
                               Reason       => Null_Unbounded_String));
                        end if;

                        if Can_Write and then not Config.Dry_Run then
                           Ada.Directories.Create_Path (Parent);
                           if not Backup.Platform.Create_Symlink (Target, Dest) then
                              Diagnostic := To_Unbounded_String
                                ("symlink restoration failed: " & To_String (Item.Archive_Path));
                              Report.Status := Restore_Unsupported_Symlink;
                              Cleanup_Temporary;
                              return Restore_Unsupported_Symlink;
                           end if;
                        end if;
                     end;
                  end if;
               end;
            else
               declare
                  Dest          : constant String := Destination_Path
                    (Output_Dir, To_String (Item.Archive_Path));
                  Parent        : constant String := Parent_Directory (Dest);
                  Payload_First : Stream_Element_Offset;
                  Payload_Last  : Stream_Element_Offset;
                  Output_File   : File_Type;
                  Computed_Crc  : Unsigned_32 := 0;
                  Computed_Size : Unsigned_64 := 0;
               begin
                  pragma Assert
                    (To_String (Item.Archive_Path)'Length > 0,
                     "restore item has a non-empty archive path");
                  if Config.Dry_Run and then Output_Path_Unsafe then
                     Diagnostic := To_Unbounded_String
                       ("--output-dir path is unsafe: " & To_String (Output_Path_Diag));
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Action_Would_Reject,
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Diagnostic));
                  elsif Existing_Ancestor_Is_Symlink
                    (Output_Dir, To_String (Item.Archive_Path), Diagnostic)
                  then
                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Diagnostic));
                     if not Config.Dry_Run then
                        Report.Status := Restore_Target_Error;
                        Cleanup_Temporary;
                        return Restore_Target_Error;
                     end if;
                  elsif Ada.Directories.Exists (Dest) then
                     case Config.Restore_Conflict is
                        when Backup.CLI.Conflict_Skip =>
                           Diagnostic := To_Unbounded_String
                             ("destination already exists: " & Dest);
                           Report.Items.Append
                             (Restore_Item'(Archive_Path => Item.Archive_Path,
                               Kind         => Item.Kind,
                               Action       => Backup.Restore_Syntax.Report_Action (Action_Skip, Config.Dry_Run),
                               Destination  => To_Unbounded_String (Dest),
                               Reason       => Diagnostic));

                        when Backup.CLI.Conflict_Overwrite =>
                           if Is_Symbolic_Link (Dest)
                             or else Ada.Directories.Kind (Dest)
                               /= Ada.Directories.Ordinary_File
                           then
                              Diagnostic := To_Unbounded_String
                                ("destination cannot be overwritten safely: " & Dest);
                              Report.Items.Append
                                (Restore_Item'(Archive_Path => Item.Archive_Path,
                                  Kind         => Item.Kind,
                                  Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                                  Destination  => To_Unbounded_String (Dest),
                                  Reason       => Diagnostic));
                              if not Config.Dry_Run then
                                 Report.Status := Restore_Existing_Path;
                                 Cleanup_Temporary;
                                 return Restore_Existing_Path;
                              end if;
                           else
                              Report.Items.Append
                                (Restore_Item'(Archive_Path => Item.Archive_Path,
                                  Kind         => Item.Kind,
                                  Action       => Backup.Restore_Syntax.Report_Action (Action_Restore, Config.Dry_Run),
                                  Destination  => To_Unbounded_String (Dest),
                                  Reason       => To_Unbounded_String
                                    ("destination overwritten")));
                              if not Config.Dry_Run then
                                 Ada.Directories.Delete_File (Dest);
                              end if;
                           end if;

                        when Backup.CLI.Conflict_Rename =>
                           if Is_Symbolic_Link (Dest) then
                              Diagnostic := To_Unbounded_String
                                ("destination cannot be renamed safely: " & Dest);
                              Report.Items.Append
                                (Restore_Item'(Archive_Path => Item.Archive_Path,
                                  Kind         => Item.Kind,
                                  Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                                  Destination  => To_Unbounded_String (Dest),
                                  Reason       => Diagnostic));
                              if not Config.Dry_Run then
                                 Report.Status := Restore_Existing_Path;
                                 Cleanup_Temporary;
                                 return Restore_Existing_Path;
                              end if;
                           else
                              declare
                                 Renamed_To : constant String := Unique_Rename_Path (Dest);
                              begin
                                 Report.Items.Append
                                   (Restore_Item'(Archive_Path => Item.Archive_Path,
                                     Kind         => Item.Kind,
                                     Action       => Backup.Restore_Syntax.Report_Action (Action_Restore, Config.Dry_Run),
                                     Destination  => To_Unbounded_String (Dest),
                                     Reason       => To_Unbounded_String
                                       ("existing destination renamed to " & Renamed_To)));
                                 if not Config.Dry_Run then
                                    Ada.Directories.Rename (Dest, Renamed_To);
                                 end if;
                              end;
                           end if;

                        when Backup.CLI.Conflict_Reject =>
                           Diagnostic := To_Unbounded_String
                             ("destination already exists: " & Dest);
                           Report.Items.Append
                             (Restore_Item'(Archive_Path => Item.Archive_Path,
                               Kind         => Item.Kind,
                               Action       => Backup.Restore_Syntax.Report_Action (Action_Reject, Config.Dry_Run),
                               Destination  => To_Unbounded_String (Dest),
                               Reason       => Diagnostic));
                           if not Config.Dry_Run then
                              Report.Status := Restore_Existing_Path;
                              Cleanup_Temporary;
                              return Restore_Existing_Path;
                           end if;
                     end case;
                  else

                     Report.Items.Append
                       (Restore_Item'(Archive_Path => Item.Archive_Path,
                         Kind         => Item.Kind,
                         Action       => Backup.Restore_Syntax.Report_Action (Action_Restore, Config.Dry_Run),
                         Destination  => To_Unbounded_String (Dest),
                         Reason       => Null_Unbounded_String));
                  end if;

                  if not Config.Dry_Run and then not Ada.Directories.Exists (Dest) then
                     Ada.Directories.Create_Path (Parent);
                     if not Local_Payload_First (Data, Item, Payload_First) then
                        Diagnostic := To_Unbounded_String
                          ("local payload could not be located for " & To_String (Item.Archive_Path));
                        Report.Status := Restore_Read_Error;
                        Cleanup_Temporary;
                        return Restore_Read_Error;
                     end if;
                     Create (Output_File, Out_File, Dest);
                     declare
                        Local     : constant Stream_Element_Offset :=
                          Stream_Element_Offset (Item.Local_Offset);
                        Flags     : constant Unsigned_16 := U16_At (Data, Local + 6);
                        Local_Method : constant Unsigned_16 := U16_At (Data, Local + 8);
                        Name_Len  : constant Unsigned_16 := U16_At (Data, Local + 26);
                        Extra_Len : constant Unsigned_16 := U16_At (Data, Local + 28);
                        Extra_First : constant Stream_Element_Offset :=
                          Local + 30 + Stream_Element_Offset (Name_Len);
                        Extra_Last : constant Stream_Element_Offset :=
                          Extra_First + Stream_Element_Offset (Extra_Len) - 1;
                        AES_Info  : constant AES_Extra_Info :=
                          Parse_AES_Extra (Data, Extra_First, Extra_Last);
                        AES_Entry : constant Boolean := Local_Method = 99;
                        Encrypted : constant Boolean := (Flags and 1) /= 0;
                     begin
                        Payload_Last :=
                          Payload_First + Stream_Element_Offset (Item.Compressed_Size) - 1;
                        if Zlib.Is_ZIP_External_Method (Item.Method) then
                           declare
                              Codec_Status : Zlib.Status_Code := Zlib.Ok;
                              Plain_Zlib : constant Zlib.Byte_Array :=
                                Zlib.Extract_ZIP_External_Entry
                                  (Bytes_To_Zlib (Data, Data'First, Data'Last),
                                   To_String (Item.Archive_Path),
                                   To_String (Zip_Password), Codec_Status);
                              Plain : constant Stream_Element_Array :=
                                Zlib_To_Bytes (Plain_Zlib);
                           begin
                              if Codec_Status /= Zlib.Ok then
                                 Close (Output_File);
                                 Remove_Partial_File (Dest);
                                 Diagnostic := To_Unbounded_String
                                   ("external ZIP codec extraction failed for " &
                                    To_String (Item.Archive_Path));
                                 Report.Status := Restore_Deflate_Invalid;
                                 Cleanup_Temporary;
                                 return Restore_Deflate_Invalid;
                              end if;
                              Computed_Size := Unsigned_64 (Plain'Length);
                              if Plain'Length = 0 then
                                 Computed_Crc := 0;
                              else
                                 Write (Output_File, Plain);
                                 declare
                                    Crc_State : CryptoLib.Checksums.CRC32_State;
                                 begin
                                    CryptoLib.Checksums.CRC32_Reset (Crc_State);
                                    CryptoLib.Checksums.CRC32_Update (Crc_State, Plain);
                                    Computed_Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
                                 end;
                              end if;
                           end;
                        elsif AES_Entry then
                           declare
                              Salt_Length : constant Natural :=
                                AES_Salt_Length (AES_Info.Strength);
                              Cipher_Length : constant Unsigned_64 :=
                                Item.Compressed_Size -
                                Unsigned_64 (Salt_Length + 2 + 10);
                              Plain : Stream_Element_Array
                                (1 .. Stream_Element_Offset (Cipher_Length));
                              Valid_AES : Boolean := False;
                           begin
                              if not AES_Info.Valid
                                or else AES_Info.Actual_Method /= Item.Method
                                or else Item.Compressed_Size <
                                  Unsigned_64 (Salt_Length + 2 + 10)
                                or else Length (Zip_Password) = 0
                              then
                                 Close (Output_File);
                                 Remove_Partial_File (Dest);
                                 Diagnostic := To_Unbounded_String
                                   ("AES ZIP payload cannot be extracted for " &
                                    To_String (Item.Archive_Path));
                                 Report.Status := Restore_Read_Error;
                                 Cleanup_Temporary;
                                 return Restore_Read_Error;
                              end if;
                              Decrypt_AES_Payload
                                (Data, Payload_First, Payload_Last,
                                 AES_Info.Strength, To_String (Zip_Password),
                                 Plain, Valid_AES);
                              if not Valid_AES then
                                 Close (Output_File);
                                 Remove_Partial_File (Dest);
                                 Diagnostic := To_Unbounded_String
                                   ("AES ZIP payload authentication failed for " &
                                    To_String (Item.Archive_Path));
                                 Report.Status := Restore_Crc_Mismatch;
                                 Cleanup_Temporary;
                                 return Restore_Crc_Mismatch;
                              end if;
                              if Item.Method = 0 then
                                 Computed_Size := Unsigned_64 (Plain'Length);
                                 if Plain'Length = 0 then
                                    Computed_Crc := 0;
                                 else
                                    Write (Output_File, Plain);
                                    declare
                                       Crc_State : CryptoLib.Checksums.CRC32_State;
                                    begin
                                       CryptoLib.Checksums.CRC32_Reset (Crc_State);
                                       CryptoLib.Checksums.CRC32_Update (Crc_State, Plain);
                                       Computed_Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
                                    end;
                                 end if;
                              elsif Item.Method = 8 then
                                 if not Inflate_Deflate_Payload
                                   (Plain, Plain'First, Plain'Last, Output_File,
                                    Computed_Crc, Computed_Size)
                                 then
                                    Close (Output_File);
                                    Remove_Partial_File (Dest);
                                    Diagnostic := To_Unbounded_String
                                      ("deflate payload extraction failed for " & To_String (Item.Archive_Path));
                                    Report.Status := Restore_Deflate_Invalid;
                                    Cleanup_Temporary;
                                    return Restore_Deflate_Invalid;
                                 end if;
                              end if;
                           end;
                        elsif Encrypted then
                           if Item.Compressed_Size < 12
                             or else Length (Zip_Password) = 0
                           then
                              Close (Output_File);
                              Remove_Partial_File (Dest);
                              Diagnostic := To_Unbounded_String
                                ("encrypted ZIP payload cannot be extracted for " &
                                 To_String (Item.Archive_Path));
                              Report.Status := Restore_Read_Error;
                              Cleanup_Temporary;
                              return Restore_Read_Error;
                           end if;
                           declare
                              Plain : constant Stream_Element_Array :=
                                Zipcrypto_Decrypt_Data
                                  (Data, Payload_First, Payload_Last,
                                   To_String (Zip_Password));
                           begin
                              if Item.Method = 0 then
                                 Computed_Size := Unsigned_64 (Plain'Length);
                                 if Plain'Length = 0 then
                                    Computed_Crc := 0;
                                 else
                                    Write (Output_File, Plain);
                                    declare
                                       Crc_State : CryptoLib.Checksums.CRC32_State;
                                    begin
                                       CryptoLib.Checksums.CRC32_Reset (Crc_State);
                                       CryptoLib.Checksums.CRC32_Update (Crc_State, Plain);
                                       Computed_Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
                                    end;
                                 end if;
                              elsif Item.Method = 8 then
                                 if not Inflate_Deflate_Payload
                                   (Plain, Plain'First, Plain'Last, Output_File,
                                    Computed_Crc, Computed_Size)
                                 then
                                    Close (Output_File);
                                    Remove_Partial_File (Dest);
                                    Diagnostic := To_Unbounded_String
                                      ("deflate payload extraction failed for " & To_String (Item.Archive_Path));
                                    Report.Status := Restore_Deflate_Invalid;
                                    Cleanup_Temporary;
                                    return Restore_Deflate_Invalid;
                                 end if;
                              end if;
                           end;
                        elsif Item.Method = 0 then
                           Computed_Size := Item.Compressed_Size;
                           if Item.Compressed_Size = 0 then
                              Computed_Crc := 0;
                           else
                              Write (Output_File, Data (Payload_First .. Payload_Last));
                              declare
                                 Crc_State : CryptoLib.Checksums.CRC32_State;
                              begin
                                 CryptoLib.Checksums.CRC32_Reset (Crc_State);
                                 CryptoLib.Checksums.CRC32_Update
                                   (Crc_State, Data (Payload_First .. Payload_Last));
                                 Computed_Crc := CryptoLib.Checksums.CRC32_Value (Crc_State);
                              end;
                           end if;
                        elsif Item.Method = 8 then
                           if not Inflate_Deflate_Payload
                             (Data, Payload_First, Payload_Last, Output_File,
                              Computed_Crc, Computed_Size)
                           then
                              Close (Output_File);
                              Remove_Partial_File (Dest);
                              Diagnostic := To_Unbounded_String
                                ("deflate payload extraction failed for " & To_String (Item.Archive_Path));
                              Report.Status := Restore_Deflate_Invalid;
                              Cleanup_Temporary;
                              return Restore_Deflate_Invalid;
                           end if;
                        else
                           Close (Output_File);
                           Remove_Partial_File (Dest);
                           Diagnostic := To_Unbounded_String
                             ("unsupported method reached restore after verification: " & Decimal (Unsigned_64 (Item.Method)));
                           Report.Status := Restore_Internal_Error;
                           Cleanup_Temporary;
                           return Restore_Internal_Error;
                        end if;
                     end;
                     Close (Output_File);

                     if Computed_Size /= Item.Uncompressed_Size
                       or else Computed_Crc /= Item.Crc32
                     then
                        Remove_Partial_File (Dest);
                        Diagnostic := To_Unbounded_String
                          ("restored payload CRC32 or size mismatch for " &
                           To_String (Item.Archive_Path));
                        Report.Status := Restore_Crc_Mismatch;
                        Cleanup_Temporary;
                        return Restore_Crc_Mismatch;
                     end if;

                     Apply_File_Metadata (Dest, Item);
                  end if;
               exception
                  when Error : others =>
                     Remove_Partial_File (Dest);
                     Diagnostic := To_Unbounded_String
                       ("failed to restore " & To_String (Item.Archive_Path) &
                        ": " & Ada.Exceptions.Exception_Message (Error));
                     Report.Status := Restore_Write_Error;
                     Cleanup_Temporary;
                     return Restore_Write_Error;
               end;
            end if;
            end if;
         end loop;
      end;

      Report.Status := Restore_Ok;
      Diagnostic := To_Unbounded_String ("archive extraction ok");
      Cleanup_Temporary;
      return Restore_Ok;
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("archive extraction failed");
         Report.Status := Restore_Internal_Error;
         Cleanup_Temporary;
         return Restore_Internal_Error;
   end Extract_Archive;

   function Kind_Name (Kind : Backup.Verify.Entry_Kind) return String is
   begin
      case Kind is
         when Backup.Verify.Entry_File => return "file";
         when Backup.Verify.Entry_Directory => return "directory";
         when Backup.Verify.Entry_Symlink => return "symlink";
         when Backup.Verify.Entry_Manifest => return "manifest";
      end case;
   end Kind_Name;

   function Action_Name (Action : Restore_Action) return String is
   begin
      return Backup.Restore_Syntax.Action_Name (Action);
   end Action_Name;

   procedure Build_Human_Report
     (Report : Restore_Report;
      Text   : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String ("backup extract" & ASCII.LF);
      Append (Text, "status: ");
      Append (Text, Status_Text (Report.Status));
      Append (Text, ASCII.LF);
      Append (Text, "archive: <configured-archive>" & ASCII.LF);
      Append (Text, "output-dir: <configured-output-dir>" & ASCII.LF);
      Append (Text, "dry-run: ");
      Append (Text, (if Report.Dry_Run then
                        "yes"
                     else
                        "no"));
      Append (Text, ASCII.LF);
      Append (Text, "restore entries:" & ASCII.LF);
      for Item of Report.Items loop
         Append (Text, "  ");
         Append (Text, Action_Name (Item.Action));
         Append (Text, " ");
         Append (Text, To_String (Item.Archive_Path));
         Append (Text, " kind=");
         Append (Text, Kind_Name (Item.Kind));
         if Length (Item.Destination) > 0 then
            Append (Text, " destination=<output-dir>/");
            Append (Text, To_String (Item.Archive_Path));
         end if;
         if Length (Item.Reason) > 0 then
            Append (Text, " reason=");
            Append (Text, To_String (Item.Reason));
         end if;
         Append (Text, ASCII.LF);
      end loop;
   end Build_Human_Report;

   procedure Build_JSON_Report
     (Report : Restore_Report;
      Text   : out Unbounded_String)
   is
      First : Boolean := True;
   begin
      Text := To_Unbounded_String ("{" & ASCII.LF);
      Append (Text, "  " & Q ("format") & ": " & Q ("backup-restore-v1") & "," & ASCII.LF);
      Append (Text, "  " & Q ("status") & ": " & Q (Status_Text (Report.Status)) & "," & ASCII.LF);
      Append (Text, "  " & Q ("dry_run") & ": ");
      Append (Text, (if Report.Dry_Run then
                        "true"
                     else
                        "false"));
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("archive_path") & ": " & Q ("<configured-archive>") & "," & ASCII.LF);
      Append (Text, "  " & Q ("output_dir") & ": " & Q ("<configured-output-dir>") & "," & ASCII.LF);
      Append (Text, "  " & Q ("zip64") & ": ");
      Append (Text, (if Report.Verify.Has_Zip64 then
                        "true"
                     else
                        "false"));
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("manifest") & ": ");
      Append (Text, (if Report.Verify.Has_Manifest then
                        Q ("ok")
                     else
                        Q ("absent")));
      Append (Text, "," & ASCII.LF);
      Append (Text, "  " & Q ("entries") & ": [" & ASCII.LF);
      for Item of Report.Items loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_path") & ": " & Q (To_String (Item.Archive_Path)));
         Append (Text, ", " & Q ("kind") & ": " & Q (Kind_Name (Item.Kind)));
         Append (Text, ", " & Q ("action") & ": " & Q (Action_Name (Item.Action)));
         Append (Text, ", " & Q ("destination") & ": ");
         if Length (Item.Destination) > 0 then
            Append (Text, Q ("<output-dir>/" & To_String (Item.Archive_Path)));
         else
            Append (Text, "null");
         end if;
         Append (Text, ", " & Q ("reason") & ": ");
         if Length (Item.Reason) > 0 then
            Append (Text, Q (To_String (Item.Reason)));
         else
            Append (Text, "null");
         end if;
         Append (Text, "}");
      end loop;
      Append (Text, ASCII.LF & "  ]" & ASCII.LF & "}" & ASCII.LF);
   end Build_JSON_Report;
end Backup.Restore;
