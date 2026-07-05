with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces;
with Backup.Platform;
with CryptoLib.BCrypt_PBKDF;
with CryptoLib.Ciphers;
with CryptoLib.Errors;
with CryptoLib.Random;

package body Backup.Encryption is
   use Ada.Streams;
   use Ada.Streams.Stream_IO;
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type CryptoLib.Errors.Status;

   Magic : constant String := "BACKUP-ENC-19";
   Envelope_KDF : constant String := "bcrypt-pbkdf";
   Envelope_KDF_Rounds : constant Unsigned_32 := 512;
   AES_GCM_Algorithm : constant String := "aes256-gcm@openssh.com";
   Salt_Length : constant Stream_Element_Offset := 16;
   Nonce_Length : constant Stream_Element_Offset := 12;

   function Cipher_Name (Cipher : Cipher_Kind) return String is
   begin
      case Cipher is
         when Cipher_AES256_GCM => return "aes256-gcm";
      end case;
   end Cipher_Name;

   function Parse_Cipher
     (Value      : String;
      Cipher     : out Cipher_Kind;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Value = "aes256-gcm" then
         Cipher := Cipher_AES256_GCM;
         return True;
      end if;

      Diagnostic := To_Unbounded_String
        ("invalid --cipher value '" & Value & "'; expected aes256-gcm");
      return False;
   end Parse_Cipher;

   function Status_Text (Status : Envelope_Status) return String is
   begin
      case Status is
         when Envelope_Ok => return "ok";
         when Envelope_Not_Encrypted => return "archive is not encrypted";
         when Envelope_Open_Failed => return "encrypted archive could not be opened";
         when Envelope_Read_Failed => return "encrypted archive could not be read";
         when Envelope_Write_Failed => return "encrypted archive could not be written";
         when Envelope_Missing_Password => return "encrypted archive requires a password source";
         when Envelope_Unsupported_Cipher => return "encrypted archive uses an unsupported cipher";
         when Envelope_Malformed => return "encrypted archive envelope is malformed";
         when Envelope_Authentication_Failed => return "encrypted archive authentication failed";
      end case;
   end Status_Text;

   function Trim_Trailing_Line_End (Value : String) return String is
      Last : Natural := Value'Last;
   begin
      while Last >= Value'First
        and then (Value (Last) = ASCII.LF or else Value (Last) = ASCII.CR)
      loop
         Last := Last - 1;
      end loop;

      if Last < Value'First then
         return "";
      end if;

      return Value (Value'First .. Last);
   end Trim_Trailing_Line_End;

   function Prompt_Password return String renames Backup.Platform.Prompt_Password;

   function Resolve_Password
     (Source     : Password_Source;
      Password   : out Unbounded_String;
      Diagnostic : out Unbounded_String)
      return Envelope_Status
   is
      Text_File : Ada.Text_IO.File_Type;
   begin
      Password := Null_Unbounded_String;
      Diagnostic := Null_Unbounded_String;

      case Source.Kind is
         when Password_None =>
            Diagnostic := To_Unbounded_String
              ("encrypted archive requires --password-file, --password-env, or --password-prompt");
            return Envelope_Missing_Password;

         when Password_File =>
            begin
               Ada.Text_IO.Open
                 (Text_File, Ada.Text_IO.In_File, To_String (Source.Value));
               if Ada.Text_IO.End_Of_File (Text_File) then
                  Ada.Text_IO.Close (Text_File);
                  Diagnostic := To_Unbounded_String
                    ("password file is empty: " & To_String (Source.Value));
                  return Envelope_Missing_Password;
               end if;
               Password := To_Unbounded_String
                 (Trim_Trailing_Line_End (Ada.Text_IO.Get_Line (Text_File)));
               Ada.Text_IO.Close (Text_File);
            exception
               when others =>
                  if Ada.Text_IO.Is_Open (Text_File) then
                     Ada.Text_IO.Close (Text_File);
                  end if;
                  Diagnostic := To_Unbounded_String
                    ("could not read password file: " & To_String (Source.Value));
                  return Envelope_Open_Failed;
            end;

         when Password_Env =>
            if not Ada.Environment_Variables.Exists (To_String (Source.Value)) then
               Diagnostic := To_Unbounded_String
                 ("password environment variable is not set: " &
                  To_String (Source.Value));
               return Envelope_Missing_Password;
            end if;
            Password := To_Unbounded_String
              (Ada.Environment_Variables.Value (To_String (Source.Value)));

         when Password_Prompt =>
            Password := To_Unbounded_String (Prompt_Password);
      end case;

      if Length (Password) = 0 then
         Diagnostic := To_Unbounded_String
           ("password source produced an empty password");
         return Envelope_Missing_Password;
      end if;

      return Envelope_Ok;
   end Resolve_Password;

   function Read_File
     (Path       : String;
      Data       : out Stream_Element_Array;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      File : File_Type;
      Last : Stream_Element_Offset;
   begin
      Open (File, In_File, Path);
      if Data'Length > 0 then
         Read (File, Data, Last);
         if Last /= Data'Last then
            Close (File);
            Diagnostic := To_Unbounded_String
              ("could not read complete file: " & Path);
            return False;
         end if;
      end if;
      Close (File);
      return True;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Diagnostic := To_Unbounded_String ("could not read file: " & Path);
         return False;
   end Read_File;

   function File_Length (Path : String; Size_Out : out Stream_Element_Offset)
      return Boolean
   is
      File : File_Type;
   begin
      Open (File, In_File, Path);
      Size_Out := Stream_Element_Offset (Size (File));
      Close (File);
      return True;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Size_Out := 0;
         return False;
   end File_Length;

   function Write_File
     (Path       : String;
      Data       : Stream_Element_Array;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      File : File_Type;
   begin
      Create (File, Out_File, Path);
      if Data'Length > 0 then
         Write (File, Data);
      end if;
      Close (File);
      return True;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Diagnostic := To_Unbounded_String ("could not write file: " & Path);
         return False;
   end Write_File;

   procedure Delete_If_Exists (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Delete_If_Exists;

   function To_Text (Data : Stream_Element_Array) return String is
      Result : String (1 .. Natural (Data'Length));
      Pos    : Natural := Result'First;
   begin
      for Item of Data loop
         Result (Pos) := Character'Val (Integer (Item));
         Pos := Pos + 1;
      end loop;
      return Result;
   end To_Text;

   function Byte_Of (Ch : Character) return Stream_Element is
   begin
      return Stream_Element (Character'Pos (Ch));
   end Byte_Of;

   function Hex_Bytes (Data : Stream_Element_Array) return String is
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. Natural (Data'Length) * 2);
      Pos    : Natural := Result'First;
      Value  : Unsigned_8;
   begin
      for Item of Data loop
         Value := Unsigned_8 (Item);
         Result (Pos) :=
           Hex (Natural (Shift_Right (Value, 4) and 16#0F#) + 1);
         Result (Pos + 1) := Hex (Natural (Value and 16#0F#) + 1);
         Pos := Pos + 2;
      end loop;
      return Result;
   end Hex_Bytes;

   function Hex_Value (Ch : Character; Value : out Stream_Element)
      return Boolean
   is
   begin
      if Ch in '0' .. '9' then
         Value := Stream_Element (Character'Pos (Ch) - Character'Pos ('0'));
         return True;
      elsif Ch in 'a' .. 'f' then
         Value := Stream_Element
           (10 + Character'Pos (Ch) - Character'Pos ('a'));
         return True;
      elsif Ch in 'A' .. 'F' then
         Value := Stream_Element
           (10 + Character'Pos (Ch) - Character'Pos ('A'));
         return True;
      end if;

      Value := 0;
      return False;
   end Hex_Value;

   function Decode_Hex
     (Text   : String;
      Output : out Stream_Element_Array)
      return Boolean
   is
      Text_Index : Natural := Text'First;
      High       : Stream_Element;
      Low        : Stream_Element;
   begin
      if Text'Length /= Natural (Output'Length) * 2 then
         Output := [others => 0];
         return False;
      end if;

      for Index in Output'Range loop
         if not Hex_Value (Text (Text_Index), High)
           or else not Hex_Value (Text (Text_Index + 1), Low)
         then
            Output := [others => 0];
            return False;
         end if;
         Output (Index) :=
           Stream_Element
             (Shift_Left (Unsigned_8 (High), 4) or Unsigned_8 (Low));
         Text_Index := Text_Index + 2;
      end loop;

      return True;
   end Decode_Hex;

   function Generate_Random
     (Buffer     : out Stream_Element_Array;
      Label      : String;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Source       : CryptoLib.Random.Random_Source;
      Random_State : CryptoLib.Errors.Status;
   begin
      CryptoLib.Random.Initialize_Production (Source);
      Random_State := CryptoLib.Random.Fill (Source, Buffer);
      if Random_State /= CryptoLib.Errors.Ok then
         Buffer := [others => 0];
         Diagnostic := To_Unbounded_String
           ("could not generate encryption " & Label);
         return False;
      end if;
      return True;
   end Generate_Random;

   function Derive_AES256_Key
     (Password   : String;
      Salt       : Stream_Element_Array;
      Rounds     : Unsigned_32;
      Key        : out Stream_Element_Array;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Status : CryptoLib.Errors.Status;
   begin
      Status := CryptoLib.BCrypt_PBKDF.Derive (Password, Salt, Rounds, Key);
      if Status /= CryptoLib.Errors.Ok then
         Key := [others => 0];
         Diagnostic := To_Unbounded_String
           ("could not derive encrypted archive key");
         return False;
      end if;
      return True;
   end Derive_AES256_Key;

   function Decimal (Value : Unsigned_64) return String is
      Image : constant String := Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Parse_Decimal_64
     (Text  : String;
      Value : out Unsigned_64)
      return Boolean
   is
      Accumulated : Unsigned_64 := 0;
   begin
      if Text'Length = 0 then
         Value := 0;
         return False;
      end if;

      for Ch of Text loop
         if Ch not in '0' .. '9' then
            Value := 0;
            return False;
         end if;

         declare
            Digit : constant Unsigned_64 :=
              Unsigned_64 (Character'Pos (Ch) - Character'Pos ('0'));
         begin
            if Accumulated > (Unsigned_64'Last - Digit) / 10 then
               Value := 0;
               return False;
            end if;
            Accumulated := Accumulated * 10 + Digit;
         end;
      end loop;

      Value := Accumulated;
      return True;
   end Parse_Decimal_64;

   function Is_Hex_String
     (Text            : String;
      Expected_Length : Natural)
      return Boolean
   is
   begin
      if Text'Length /= Expected_Length then
         return False;
      end if;

      for Ch of Text loop
         if not (Ch in '0' .. '9' or else Ch in 'a' .. 'f'
                 or else Ch in 'A' .. 'F')
         then
            return False;
         end if;
      end loop;

      return True;
   end Is_Hex_String;

   function Header_Field (Header : String; Name : String) return String is
      Prefix     : constant String := Name & ":";
      Line_First : Natural := Header'First;
      Line_Last  : Natural;
   begin
      while Line_First <= Header'Last loop
         Line_Last := Line_First;
         while Line_Last <= Header'Last
           and then Header (Line_Last) /= ASCII.LF
         loop
            Line_Last := Line_Last + 1;
         end loop;

         if Line_Last - Line_First >= Prefix'Length
           and then Header
             (Line_First .. Line_First + Prefix'Length - 1) = Prefix
         then
            declare
               Value_First : constant Natural := Line_First + Prefix'Length;
            begin
               if Value_First >= Line_Last then
                  return "";
               end if;
               return Header (Value_First .. Line_Last - 1);
            end;
         end if;

         Line_First := Line_Last + 1;
      end loop;

      return "";
   end Header_Field;

   function Is_Encrypted (Path : String) return Boolean is
      Size_Value : Stream_Element_Offset;
      Prefix_Length : constant Stream_Element_Offset :=
        Stream_Element_Offset (Magic'Length + 1);
   begin
      if not File_Length (Path, Size_Value)
        or else Size_Value < Prefix_Length
      then
         return False;
      end if;
      declare
         Data : Stream_Element_Array (1 .. Prefix_Length);
         Diag : Unbounded_String;
      begin
         if not Read_File (Path, Data, Diag) then
            return False;
         end if;
         return To_Text (Data) = Magic & ASCII.LF;
      end;
   end Is_Encrypted;

   function Encrypt_File
     (Plaintext_Path : String;
      Encrypted_Path : String;
      Source         : Password_Source;
      Cipher         : Cipher_Kind;
      Diagnostic     : out Unbounded_String)
      return Envelope_Status
   is
      Password : Unbounded_String;
      Status   : Envelope_Status;
      Size_Value : Stream_Element_Offset;
   begin
      Status := Resolve_Password (Source, Password, Diagnostic);
      if Status /= Envelope_Ok then
         return Status;
      end if;

      if not File_Length (Plaintext_Path, Size_Value) then
         Diagnostic := To_Unbounded_String
           ("could not open plaintext archive for encryption: " & Plaintext_Path);
         return Envelope_Open_Failed;
      end if;

      declare
         Plain : Stream_Element_Array (1 .. Size_Value);
      begin
         if not Read_File (Plaintext_Path, Plain, Diagnostic) then
            return Envelope_Read_Failed;
         end if;

         declare
            Cipher_Text_Name : constant String := Cipher_Name (Cipher);
            Salt_Data  : Stream_Element_Array (1 .. Salt_Length);
            Nonce_Data : Stream_Element_Array (1 .. Nonce_Length);
            Key_Data   : Stream_Element_Array
              (1 ..
                 Stream_Element_Offset
                   (CryptoLib.Ciphers.AES_GCM_Key_Length
                      (AES_GCM_Algorithm)));
            Plain_Size_Text : constant String :=
              Decimal (Unsigned_64 (Plain'Length));
         begin
            if not Generate_Random (Salt_Data, "salt", Diagnostic)
              or else not Generate_Random (Nonce_Data, "nonce", Diagnostic)
              or else not Derive_AES256_Key
                (To_String (Password),
                 Salt_Data,
                 Envelope_KDF_Rounds,
                 Key_Data,
                 Diagnostic)
            then
               return Envelope_Write_Failed;
            end if;

            declare
               Wire : Stream_Element_Array
                 (1 ..
                    Stream_Element_Offset
                      (Plain'Length
                       + CryptoLib.Ciphers.AES_GCM_Tag_Length));
               Crypto_Status : CryptoLib.Errors.Status;
            begin
               Crypto_Status := CryptoLib.Ciphers.Seal_GCM
                 (AES_GCM_Algorithm, Key_Data, Nonce_Data, 0, Plain, Wire);
               if Crypto_Status /= CryptoLib.Errors.Ok then
                  Diagnostic := To_Unbounded_String
                    ("could not seal encrypted archive payload");
                  return Envelope_Write_Failed;
               end if;

               declare
                  Tag_First : constant Stream_Element_Offset :=
                    Wire'Last
                    - Stream_Element_Offset
                        (CryptoLib.Ciphers.AES_GCM_Tag_Length)
                    + 1;
                  Tag       : constant String :=
                    Hex_Bytes (Wire (Tag_First .. Wire'Last));
                  Header    : constant String :=
                    Magic & ASCII.LF &
                    "cipher:" & Cipher_Text_Name & ASCII.LF &
                    "kdf:" & Envelope_KDF & ASCII.LF &
                    "rounds:" & Decimal (Unsigned_64 (Envelope_KDF_Rounds)) &
                    ASCII.LF &
                    "salt:" & Hex_Bytes (Salt_Data) & ASCII.LF &
                    "nonce:" & Hex_Bytes (Nonce_Data) & ASCII.LF &
                    "plain-size:" & Plain_Size_Text & ASCII.LF &
                    "tag:" & Tag & ASCII.LF & ASCII.LF;
                  Output    : Stream_Element_Array
                    (1 .. Stream_Element_Offset (Header'Length + Wire'Length));
                  Pos       : Stream_Element_Offset := Output'First;
               begin
                  for Ch of Header loop
                     Output (Pos) := Byte_Of (Ch);
                     Pos := Pos + 1;
                  end loop;
                  for Item of Wire loop
                     Output (Pos) := Item;
                     Pos := Pos + 1;
                  end loop;
                  if not Write_File (Encrypted_Path, Output, Diagnostic) then
                     return Envelope_Write_Failed;
                  end if;
               end;
            end;
         end;
      end;

      return Envelope_Ok;
   end Encrypt_File;

   function Decrypt_File
     (Encrypted_Path : String;
      Plaintext_Path : String;
      Source         : Password_Source;
      Diagnostic     : out Unbounded_String)
      return Envelope_Status
   is
      Password   : Unbounded_String;
      Status     : Envelope_Status;
      Size_Value : Stream_Element_Offset;
   begin
      Diagnostic := Null_Unbounded_String;

      if not File_Length (Encrypted_Path, Size_Value) then
         Diagnostic := To_Unbounded_String
           ("could not open encrypted archive: " & Encrypted_Path);
         return Envelope_Open_Failed;
      end if;

      declare
         Data : Stream_Element_Array (1 .. Size_Value);
      begin
         if not Read_File (Encrypted_Path, Data, Diagnostic) then
            return Envelope_Read_Failed;
         end if;

         declare
            Text       : constant String := To_Text (Data);
            Header_End : constant Natural := Ada.Strings.Fixed.Index
              (Text, ASCII.LF & ASCII.LF);
         begin
            if Text'Length < Magic'Length + 1
              or else Text (Text'First .. Text'First + Magic'Length - 1) /= Magic
              or else Text (Text'First + Magic'Length) /= ASCII.LF
            then
               Diagnostic := To_Unbounded_String
                 ("archive is not encrypted with the phase 19 envelope");
               return Envelope_Not_Encrypted;
            end if;

            Delete_If_Exists (Plaintext_Path);

            if Header_End = 0 then
               Diagnostic := To_Unbounded_String
                 ("encrypted archive envelope header is malformed");
               return Envelope_Malformed;
            end if;

            Status := Resolve_Password (Source, Password, Diagnostic);
            if Status /= Envelope_Ok then
               return Status;
            end if;

            declare
               Header : constant String := Text (Text'First .. Header_End);
               Cipher : constant String := Header_Field (Header, "cipher");
               KDF    : constant String := Header_Field (Header, "kdf");
               Rounds_Field : constant String :=
                 Header_Field (Header, "rounds");
               Salt   : constant String := Header_Field (Header, "salt");
               Nonce  : constant String := Header_Field (Header, "nonce");
               Plain_Size_Field : constant String :=
                 Header_Field (Header, "plain-size");
               Tag    : constant String := Header_Field (Header, "tag");
               Cipher_First : constant Stream_Element_Offset :=
                 Stream_Element_Offset (Header_End + 2);
               Expected_Plain_Size : Unsigned_64;
               Rounds_Value : Unsigned_64;
            begin
               if Cipher /= "aes256-gcm" then
                  Diagnostic := To_Unbounded_String
                    ("unsupported encrypted archive cipher: " & Cipher);
                  return Envelope_Unsupported_Cipher;
               end if;

               if KDF /= Envelope_KDF
                 or else Rounds_Field'Length = 0
                 or else Salt'Length = 0 or else Nonce'Length = 0
                 or else Plain_Size_Field'Length = 0 or else Tag'Length = 0
                 or else Cipher_First > Data'Last + 1
               then
                  Diagnostic := To_Unbounded_String
                    ("encrypted archive envelope metadata is incomplete");
                  return Envelope_Malformed;
               end if;

               if not Is_Hex_String (Salt, Natural (Salt_Length) * 2)
                 or else not Is_Hex_String (Nonce, Natural (Nonce_Length) * 2)
                 or else not Is_Hex_String
                   (Tag, CryptoLib.Ciphers.AES_GCM_Tag_Length * 2)
                 or else not Parse_Decimal_64
                   (Plain_Size_Field, Expected_Plain_Size)
                 or else not Parse_Decimal_64 (Rounds_Field, Rounds_Value)
                 or else Rounds_Value = 0
                 or else Rounds_Value >
                   Unsigned_64 (CryptoLib.BCrypt_PBKDF.Max_Rounds)
               then
                  Diagnostic := To_Unbounded_String
                    ("encrypted archive envelope metadata is malformed");
                  return Envelope_Malformed;
               end if;

               declare
                  Expected_Header : constant String :=
                    Magic & ASCII.LF &
                    "cipher:" & Cipher & ASCII.LF &
                    "kdf:" & KDF & ASCII.LF &
                    "rounds:" & Rounds_Field & ASCII.LF &
                    "salt:" & Salt & ASCII.LF &
                    "nonce:" & Nonce & ASCII.LF &
                    "plain-size:" & Plain_Size_Field & ASCII.LF &
                    "tag:" & Tag & ASCII.LF;
               begin
                  if Header /= Expected_Header then
                     Diagnostic := To_Unbounded_String
                       ("encrypted archive envelope header has unexpected metadata");
                     return Envelope_Malformed;
                  end if;
               end;

               declare
                  Wire : constant Stream_Element_Array :=
                    Data (Cipher_First .. Data'Last);
                  Salt_Data  : Stream_Element_Array (1 .. Salt_Length);
                  Nonce_Data : Stream_Element_Array (1 .. Nonce_Length);
                  Key_Data   : Stream_Element_Array
                    (1 ..
                       Stream_Element_Offset
                         (CryptoLib.Ciphers.AES_GCM_Key_Length
                            (AES_GCM_Algorithm)));
               begin
                  if Unsigned_64 (Wire'Length)
                    /= Expected_Plain_Size
                       + Unsigned_64 (CryptoLib.Ciphers.AES_GCM_Tag_Length)
                  then
                     Diagnostic := To_Unbounded_String
                       ("encrypted archive envelope payload size is malformed");
                     return Envelope_Malformed;
                  end if;

                  if not Decode_Hex (Salt, Salt_Data)
                    or else not Decode_Hex (Nonce, Nonce_Data)
                  then
                     Diagnostic := To_Unbounded_String
                       ("encrypted archive envelope metadata is malformed");
                     return Envelope_Malformed;
                  end if;

                  declare
                     Tag_First : constant Stream_Element_Offset :=
                       Wire'Last
                       - Stream_Element_Offset
                           (CryptoLib.Ciphers.AES_GCM_Tag_Length)
                       + 1;
                  begin
                     if Hex_Bytes (Wire (Tag_First .. Wire'Last)) /= Tag then
                        Diagnostic := To_Unbounded_String
                          ("encrypted archive authentication failed");
                        return Envelope_Authentication_Failed;
                     end if;
                  end;

                  if not Derive_AES256_Key
                    (To_String (Password),
                     Salt_Data,
                     Unsigned_32 (Rounds_Value),
                     Key_Data,
                     Diagnostic)
                  then
                     return Envelope_Authentication_Failed;
                  end if;

                  declare
                     Plain_Last : constant Stream_Element_Offset :=
                       Wire'First
                       + Stream_Element_Offset (Expected_Plain_Size)
                       - 1;
                     Plain : Stream_Element_Array (Wire'First .. Plain_Last);
                     Crypto_Status : CryptoLib.Errors.Status;
                  begin
                     Crypto_Status := CryptoLib.Ciphers.Open_GCM
                       (AES_GCM_Algorithm, Key_Data, Nonce_Data, 0, Wire, Plain);
                     if Crypto_Status /= CryptoLib.Errors.Ok then
                        Diagnostic := To_Unbounded_String
                          ("encrypted archive authentication failed");
                        return Envelope_Authentication_Failed;
                     end if;

                     if not Write_File (Plaintext_Path, Plain, Diagnostic) then
                        Delete_If_Exists (Plaintext_Path);
                        return Envelope_Write_Failed;
                     end if;
                  end;
               end;
            end;
         end;
      end;

      return Envelope_Ok;
   end Decrypt_File;
end Backup.Encryption;
