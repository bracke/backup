with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Http_Client.Clients;
with Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.Request_Bodies;
with Http_Client.Requests;
with Http_Client.Responses;
with Http_Client.Types;
with Http_Client.URI;

with CryptoLib.BCrypt_PBKDF;
with CryptoLib.ChaCha20_Poly1305;
with CryptoLib.Errors;
with CryptoLib.Hashes;
with CryptoLib.Macs;
with Project_Tools.JSON;

package body Proton_Drive is
   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Size;
   use type Ada.Streams.Stream_IO.Count;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_8;
   use type CryptoLib.Errors.Status;
   use type Http_Client.Errors.Result_Status;
   use type Http_Client.Types.Method_Name;

   function Default_API_Base return String is
   begin
      return "https://drive.proton.me";
   end Default_API_Base;

   function Status_Text (Status : SDK_Status) return String is
   begin
      case Status is
         when SDK_Ok =>
            return "ok";
         when SDK_Invalid_Config =>
            return "invalid Proton Drive SDK configuration";
         when SDK_Provider_Missing =>
            return "Proton Drive SDK provider is missing";
         when SDK_Crypto_Unavailable =>
            return "Proton Drive SDK crypto is unavailable";
         when SDK_Operations_Unavailable =>
            return "Proton Drive SDK encrypted operations are unavailable";
         when SDK_HTTP_Failed =>
            return "Proton Drive SDK HTTP request failed";
         when SDK_Not_Found =>
            return "Proton Drive node was not found";
         when SDK_Rate_Limited =>
            return "Proton Drive request was rate limited";
      end case;
   end Status_Text;

   function SDK_Status_Text return String is
   begin
      return "Proton Drive Ada SDK validates configuration, loads session and user-address providers, derives metadata authentication material with CryptoLib.Hashes and CryptoLib.Macs, and executes explicit provider or opt-in native Drive operation endpoints, validates descriptor schema/capabilities and explicit wire contracts, tags content blocks before upload, and fails closed when bounded-memory upload is not available";
   end SDK_Status_Text;

   function Is_Lower_Name_Char (Ch : Character) return Boolean is
   begin
      return Ch in 'a' .. 'z' or else Ch = '_' or else Ch in '0' .. '9';
   end Is_Lower_Name_Char;

   function Is_Digit (Ch : Character) return Boolean is
   begin
      return Ch in '0' .. '9';
   end Is_Digit;

   function Is_App_Version_Valid (Value : String) return Boolean is
      At_Pos : Natural := 0;
      Dash_Pos : Natural := 0;
      Plus_Pos : Natural := 0;
      Dot_Count : Natural := 0;
      First_Version : Natural;
      Minimum_Length : constant Natural := 24;

      function Valid_Channel (Text : String) return Boolean is
      begin
         return Text = "stable" or else Text = "beta" or else Text = "alpha";
      end Valid_Channel;

      function Valid_Build_Metadata (Text : String) return Boolean is
      begin
         if Text'Length = 0 then
            return False;
         end if;
         for Ch of Text loop
            if not (Ch in 'a' .. 'z' or else Ch in 'A' .. 'Z' or else
                    Ch in '0' .. '9' or else Ch = '-' or else Ch = '.')
            then
               return False;
            end if;
         end loop;
         return True;
      end Valid_Build_Metadata;
   begin
      --  ProtonDriveApps/sdk PR #23 documents x-pm-appversion as
      --  external-drive-{name}@{semver}-{channel}+{suffix}, with +suffix
      --  optional and channel one of stable, beta, or alpha.
      if Value'Length < Minimum_Length then
         return False;
      elsif Value (Value'First .. Value'First + 14) /= "external-drive-" then
         return False;
      end if;

      for Index in Value'First + 15 .. Value'Last loop
         if Value (Index) = '@' then
            At_Pos := Index;
            exit;
         elsif not Is_Lower_Name_Char (Value (Index)) then
            return False;
         end if;
      end loop;

      if At_Pos = 0 or else At_Pos = Value'First + 15 then
         return False;
      end if;

      First_Version := At_Pos + 1;
      for Index in First_Version .. Value'Last loop
         if Value (Index) = '-' then
            Dash_Pos := Index;
            exit;
         elsif Value (Index) = '.' then
            Dot_Count := Dot_Count + 1;
         elsif not Is_Digit (Value (Index)) then
            return False;
         end if;
      end loop;

      if Dot_Count /= 2 or else Dash_Pos = First_Version or else Dash_Pos = 0 then
         return False;
      end if;

      for Index in Dash_Pos + 1 .. Value'Last loop
         if Value (Index) = '+' then
            Plus_Pos := Index;
            exit;
         end if;
      end loop;

      if Plus_Pos = 0 then
         return Valid_Channel (Value (Dash_Pos + 1 .. Value'Last));
      elsif Plus_Pos = Dash_Pos + 1 then
         return False;
      else
         return Valid_Channel (Value (Dash_Pos + 1 .. Plus_Pos - 1))
           and then Valid_Build_Metadata (Value (Plus_Pos + 1 .. Value'Last));
      end if;
   exception
      when others =>
         return False;
   end Is_App_Version_Valid;


   function Is_Official_API_Base (Value : String) return Boolean is
   begin
      return Value = Default_API_Base;
   end Is_Official_API_Base;

   function Normalized_API_Base (Config : Client_Config) return String is
   begin
      if Length (Config.API_Base) = 0 then
         return Default_API_Base;
      end if;
      return To_String (Config.API_Base);
   end Normalized_API_Base;

   function To_Bytes (Text : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      Offset : Natural := 0;
   begin
      for Index in Text'Range loop
         Offset := Offset + 1;
         Result (Ada.Streams.Stream_Element_Offset (Offset)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (Index)));
      end loop;
      return Result;
   end To_Bytes;

   function Hex_Byte (Value : Ada.Streams.Stream_Element) return String is
      Hex : constant String := "0123456789abcdef";
      Natural_Value : constant Natural := Natural (Value);
   begin
      return Hex (Hex'First + Natural_Value / 16) &
        Hex (Hex'First + Natural_Value mod 16);
   end Hex_Byte;

   function Hex_SHA256
     (Digest : CryptoLib.Hashes.SHA256_Digest) return String
   is
      Result : Unbounded_String;
   begin
      for Byte of Digest loop
         Append (Result, Hex_Byte (Byte));
      end loop;
      return To_String (Result);
   end Hex_SHA256;

   function Hex_HMAC_SHA256
     (Digest : CryptoLib.Macs.HMAC_SHA256_Digest) return String
   is
      Result : Unbounded_String;
   begin
      for Byte of Digest loop
         Append (Result, Hex_Byte (Byte));
      end loop;
      return To_String (Result);
   end Hex_HMAC_SHA256;

   function SHA256_Hex (Text : String) return String is
   begin
      return Hex_SHA256 (CryptoLib.Hashes.SHA256 (To_Bytes (Text)));
   end SHA256_Hex;

   function HMAC_SHA256_Hex (Key : String; Message : String) return String is
   begin
      return Hex_HMAC_SHA256
        (CryptoLib.Macs.HMAC_SHA256
           (Key_Data     => To_Bytes (Key),
            Message_Data => To_Bytes (Message)));
   end HMAC_SHA256_Hex;

   function From_Bytes (Data : Ada.Streams.Stream_Element_Array) return String is
      Result : String (1 .. Data'Length);
      Offset : Natural := 0;
   begin
      for Index in Data'Range loop
         Offset := Offset + 1;
         Result (Offset) := Character'Val (Natural (Data (Index)));
      end loop;
      return Result;
   end From_Bytes;

   function Hex_Value (Ch : Character) return Natural;

   function Unhex_Text (Text : String) return String;

   function Metadata_AEAD_Key (Context : Crypto_Context) return String is
      Seed : constant String :=
        To_String (Context.Metadata_Key_Id) & ASCII.LF &
        To_String (Context.Metadata_Key_Fingerprint) & ASCII.LF &
        To_String (Context.Address_Key_Fingerprint) & ASCII.LF &
        To_String (Context.Node_Key_Fingerprint);
   begin
      if Length (Context.Metadata_Key_Id) = 0
        or else Length (Context.Metadata_Key_Fingerprint) = 0
        or else Length (Context.Address_Key_Fingerprint) = 0
      then
         return "";
      end if;
      return Unhex_Text (SHA256_Hex ("proton-metadata-aead-1" & ASCII.LF & Seed)) &
        Unhex_Text (SHA256_Hex ("proton-metadata-aead-2" & ASCII.LF & Seed));
   end Metadata_AEAD_Key;

   function Sequence_From_Context (Context : Crypto_Context) return Interfaces.Unsigned_32 is
      Hex : constant String := To_String (Context.Metadata_Key_Fingerprint);
      Result : Interfaces.Unsigned_32 := 0;
      Value : Natural;
   begin
      if Hex'Length < 8 then
         return 0;
      end if;
      for Index in Hex'First .. Hex'First + 7 loop
         Value := Hex_Value (Hex (Index));
         if Value > 15 then
            return 0;
         end if;
         Result := Result * 16 + Interfaces.Unsigned_32 (Value);
      end loop;
      return Result;
   end Sequence_From_Context;

   function Packet_Text (Plaintext : String) return String is
      Len : constant Natural := Plaintext'Length;
   begin
      return Character'Val ((Len / 16#1000000#) mod 256) &
        Character'Val ((Len / 16#10000#) mod 256) &
        Character'Val ((Len / 16#100#) mod 256) &
        Character'Val (Len mod 256) & Plaintext;
   end Packet_Text;

   function Packet_Payload (Packet : String) return String is
      Declared : Natural;
   begin
      if Packet'Length < 4 then
         return "";
      end if;
      Declared := Character'Pos (Packet (Packet'First)) * 16#1000000# +
        Character'Pos (Packet (Packet'First + 1)) * 16#10000# +
        Character'Pos (Packet (Packet'First + 2)) * 16#100# +
        Character'Pos (Packet (Packet'First + 3));
      if Declared /= Packet'Length - 4 then
         return "";
      end if;
      return Packet (Packet'First + 4 .. Packet'Last);
   exception
      when others =>
         return "";
   end Packet_Payload;

   function Hex_Text (Text : String) return String is
      Hex : constant String := "0123456789abcdef";
      Result : Unbounded_String;
      Value : Natural;
   begin
      for Ch of Text loop
         Value := Character'Pos (Ch);
         Append (Result, Hex (Hex'First + Value / 16));
         Append (Result, Hex (Hex'First + Value mod 16));
      end loop;
      return To_String (Result);
   end Hex_Text;

   function Hex_Value (Ch : Character) return Natural is
   begin
      if Ch in '0' .. '9' then
         return Character'Pos (Ch) - Character'Pos ('0');
      elsif Ch in 'a' .. 'f' then
         return 10 + Character'Pos (Ch) - Character'Pos ('a');
      elsif Ch in 'A' .. 'F' then
         return 10 + Character'Pos (Ch) - Character'Pos ('A');
      else
         return 16;
      end if;
   end Hex_Value;

   function Unhex_Text (Text : String) return String is
      Result : Unbounded_String;
      Hi : Natural;
      Lo : Natural;
   begin
      if Text'Length mod 2 /= 0 then
         return "";
      end if;
      declare
         Pos : Natural := Text'First;
      begin
         while Pos <= Text'Last loop
            Hi := Hex_Value (Text (Pos));
            Lo := Hex_Value (Text (Pos + 1));
            if Hi > 15 or else Lo > 15 then
               return "";
            end if;
            Append (Result, Character'Val (Hi * 16 + Lo));
            Pos := Pos + 2;
         end loop;
      end;
      return To_String (Result);
   end Unhex_Text;

   function Counter_Text (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      if Raw'Length > 0 and then Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      end if;
      return Raw;
   end Counter_Text;

   function XOR_With_Derived_Stream
     (Key       : String;
      Nonce     : String;
      Plaintext : String) return String
   is
      Result : Unbounded_String;
      Block  : Natural := 0;
      Stream : Unbounded_String;
      Index  : Natural := 1;
      Value  : Interfaces.Unsigned_8;
      K      : Interfaces.Unsigned_8;
   begin
      for Ch of Plaintext loop
         if Length (Stream) = 0 or else Index > Length (Stream) then
            Stream := To_Unbounded_String
              (HMAC_SHA256_Hex (Key, Nonce & ":" & Counter_Text (Block)));
            Block := Block + 1;
            Index := 1;
         end if;
         Value := Interfaces.Unsigned_8 (Character'Pos (Ch));
         K := Interfaces.Unsigned_8 (Character'Pos (Element (Stream, Index)));
         Append (Result, Character'Val (Natural (Value xor K)));
         Index := Index + 1;
      end loop;
      return To_String (Result);
   end XOR_With_Derived_Stream;

   function Supports_First_Party_Key_Unlock return Boolean is
   begin
      return False;
   end Supports_First_Party_Key_Unlock;

   function First_Party_Key_Unlock_Status return String is
   begin
      return "Proton Drive first-party account key unlock is unavailable: the supported SDK does not include authentication/login, session management, or a user address provider";
   end First_Party_Key_Unlock_Status;

   function Parse_Rounds (Text : String) return Interfaces.Unsigned_32 is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      if Text'Length = 0 then
         return 16;
      end if;
      for Ch of Text loop
         if Ch not in '0' .. '9' then
            return 0;
         end if;
         Result := Result * 10 +
           Interfaces.Unsigned_32 (Character'Pos (Ch) - Character'Pos ('0'));
         if Result > CryptoLib.BCrypt_PBKDF.Max_Rounds then
            return 0;
         end if;
      end loop;
      return Result;
   end Parse_Rounds;

   function Key_Unlock_Sequence
     (Salt : String;
      Name : String) return Interfaces.Unsigned_32
   is
      Hex : constant String := SHA256_Hex ("proton-key-unlock-seq" & ASCII.LF & Salt & ASCII.LF & Name);
      Result : Interfaces.Unsigned_32 := 0;
      Value : Natural;
   begin
      for Index in Hex'First .. Hex'First + 7 loop
         Value := Hex_Value (Hex (Index));
         Result := Result * 16 + Interfaces.Unsigned_32 (Value);
      end loop;
      return Result;
   end Key_Unlock_Sequence;

   function Key_Unlock_Key
     (Passphrase : String;
      Salt       : String;
      Rounds     : Interfaces.Unsigned_32) return String
   is
      Output : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset
          (CryptoLib.BCrypt_PBKDF.Max_Output_Length));
      Status : CryptoLib.Errors.Status;
   begin
      if Passphrase'Length = 0
        or else Salt'Length = 0
        or else Salt'Length > CryptoLib.BCrypt_PBKDF.Max_Salt_Length
        or else Rounds = 0
      then
         return "";
      end if;
      Status := CryptoLib.BCrypt_PBKDF.Derive
        (Passphrase, To_Bytes (Salt), Rounds, Output);
      if Status /= CryptoLib.Errors.Ok then
         return "";
      end if;
      return From_Bytes (Output);
   exception
      when others =>
         return "";
   end Key_Unlock_Key;

   function Key_Unlock_Envelope
     (Passphrase : String;
      Salt       : String;
      Rounds     : Interfaces.Unsigned_32;
      Name       : String;
      Plaintext  : String) return String
   is
      Key     : constant String := Key_Unlock_Key (Passphrase, Salt, Rounds);
      Plain   : constant String := Packet_Text (Name & ASCII.LF & Plaintext);
      Wire    : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset
          (Plain'Length + CryptoLib.ChaCha20_Poly1305.Tag_Length));
      Status  : CryptoLib.Errors.Status;
   begin
      if Key'Length /= CryptoLib.ChaCha20_Poly1305.Key_Length
        or else Name'Length = 0
        or else Plaintext'Length = 0
      then
         return "";
      end if;
      Status := CryptoLib.ChaCha20_Poly1305.Seal
        (To_Bytes (Key), Key_Unlock_Sequence (Salt, Name), To_Bytes (Plain), Wire);
      if Status /= CryptoLib.Errors.Ok then
         return "";
      end if;
      return "PROTON-KEY-UNLOCK-V1:" & Hex_Text (From_Bytes (Wire));
   exception
      when others =>
         return "";
   end Key_Unlock_Envelope;

   function Open_Key_Unlock_Envelope
     (Passphrase : String;
      Salt       : String;
      Rounds     : Interfaces.Unsigned_32;
      Name       : String;
      Envelope   : String;
      Plaintext  : out Unbounded_String) return Boolean
   is
      Prefix : constant String := "PROTON-KEY-UNLOCK-V1:";
      Key    : constant String := Key_Unlock_Key (Passphrase, Salt, Rounds);
      Hex    : constant String :=
        (if Envelope'Length > Prefix'Length
           and then Envelope (Envelope'First .. Envelope'First + Prefix'Length - 1) = Prefix
         then Envelope (Envelope'First + Prefix'Length .. Envelope'Last)
         else "");
      Cipher : constant String := Unhex_Text (Hex);
      Wire   : constant Ada.Streams.Stream_Element_Array := To_Bytes (Cipher);
      Plain  : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset
          (Integer'Max (0, Cipher'Length - CryptoLib.ChaCha20_Poly1305.Tag_Length)));
      Status : CryptoLib.Errors.Status;
      Opened : Unbounded_String;
      Sep    : Natural;
   begin
      Plaintext := Null_Unbounded_String;
      if Key'Length /= CryptoLib.ChaCha20_Poly1305.Key_Length
        or else Name'Length = 0
        or else Cipher'Length < 5 + CryptoLib.ChaCha20_Poly1305.Tag_Length
        or else Cipher'Length * 2 /= Hex'Length
      then
         return False;
      end if;
      Status := CryptoLib.ChaCha20_Poly1305.Open
        (To_Bytes (Key), Key_Unlock_Sequence (Salt, Name), Wire, Plain);
      if Status /= CryptoLib.Errors.Ok then
         return False;
      end if;
      Opened := To_Unbounded_String (Packet_Payload (From_Bytes (Plain)));
      Sep := Ada.Strings.Fixed.Index (To_String (Opened), "" & ASCII.LF);
      if Sep = 0
        or else To_String (Opened) (To_String (Opened)'First .. Sep - 1) /= Name
      then
         return False;
      end if;
      Plaintext := To_Unbounded_String (To_String (Opened) (Sep + 1 .. Length (Opened)));
      return Length (Plaintext) > 0;
   exception
      when others =>
         Plaintext := Null_Unbounded_String;
         return False;
   end Open_Key_Unlock_Envelope;

   function Descriptor_Key_Material
     (Text : String;
      Name : String) return String
   is
      Direct : constant String := Project_Tools.JSON.Field_Value (Text, Name);
      Encrypted : constant String :=
        Project_Tools.JSON.Field_Value (Text, "encrypted_" & Name);
      Passphrase : constant String :=
        Project_Tools.JSON.Field_Value (Text, "proton_drive_key_unlock_passphrase");
      Salt : constant String :=
        Project_Tools.JSON.Field_Value (Text, "proton_drive_key_unlock_salt");
      Rounds : constant Interfaces.Unsigned_32 :=
        Parse_Rounds
          (Project_Tools.JSON.Field_Value (Text, "proton_drive_key_unlock_rounds"));
      Opened : Unbounded_String;
   begin
      if Direct'Length > 0 then
         return Direct;
      elsif Encrypted'Length = 0 then
         return "";
      elsif Open_Key_Unlock_Envelope
        (Passphrase, Salt, Rounds, Name, Encrypted, Opened)
      then
         return To_String (Opened);
      else
         return "";
      end if;
   end Descriptor_Key_Material;

   function Encrypted_Key_Material_Present
     (Text : String;
      Name : String) return Boolean is
   begin
      return Project_Tools.JSON.Field_Value (Text, "encrypted_" & Name)'Length > 0;
   end Encrypted_Key_Material_Present;

   function Streaming_Key (Context : Crypto_Context) return String is
   begin
      return To_String (Context.Content_Tag_Key_Fingerprint) & ASCII.LF &
        To_String (Context.Content_Key_Fingerprint) & ASCII.LF &
        To_String (Context.Node_Key_Fingerprint);
   end Streaming_Key;

   function Line_Value (Text : String; Name : String) return String is
      Prefix : constant String := Name & "=";
      Start  : Natural := Text'First;
      Stop   : Natural;
   begin
      while Start <= Text'Last loop
         Stop := Start;
         while Stop <= Text'Last and then Text (Stop) /= ASCII.LF loop
            Stop := Stop + 1;
         end loop;
         if Stop - Start >= Prefix'Length
           and then Text (Start .. Start + Prefix'Length - 1) = Prefix
         then
            return Text (Start + Prefix'Length .. Stop - 1);
         end if;
         Start := Stop + 1;
      end loop;
      return "";
   exception
      when others =>
         return "";
   end Line_Value;

   function Replace_All (Text : String; Pattern : String; Replacement : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Text'First;
   begin
      if Pattern'Length = 0 then
         return Text;
      end if;

      while Index <= Text'Last loop
         if Index <= Text'Last - Pattern'Length + 1
           and then Text (Index .. Index + Pattern'Length - 1) = Pattern
         then
            Append (Result, Replacement);
            Index := Index + Pattern'Length;
         else
            Append (Result, Text (Index));
            Index := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Replace_All;

   function JSON_Escape (Text : String) return String is
      Result : Unbounded_String;
   begin
      for Ch of Text loop
         if Ch = Character'Val (16#5C#) then
            Append (Result, Character'Val (16#5C#));
            Append (Result, Character'Val (16#5C#));
         elsif Ch = '"' then
            Append (Result, Character'Val (16#5C#));
            Append (Result, '"');
         elsif Ch = ASCII.LF then
            Append (Result, "\n");
         elsif Ch = ASCII.CR then
            Append (Result, "\r");
         elsif Ch = ASCII.HT then
            Append (Result, "\t");
         else
            Append (Result, Ch);
         end if;
      end loop;
      return To_String (Result);
   end JSON_Escape;

   function JSON_Pair (Name : String; Value : String) return String is
      Quote : constant Character := Character'Val (16#22#);
   begin
      return Quote & Name & Quote & ":" & Quote & JSON_Escape (Value) & Quote;
   end JSON_Pair;

   function Percent_Encode (Text : String) return String is
      Hex : constant String := "0123456789ABCDEF";
      Result : Unbounded_String;
   begin
      for Ch of Text loop
         if Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z'
           or else Ch in '0' .. '9' or else Ch = '-' or else Ch = '_'
           or else Ch = '.' or else Ch = '~' or else Ch = '/'
         then
            Append (Result, Ch);
         else
            declare
               Value : constant Natural := Character'Pos (Ch);
            begin
               Append (Result, '%');
               Append (Result, Hex (Hex'First + Value / 16));
               Append (Result, Hex (Hex'First + Value mod 16));
            end;
         end if;
      end loop;
      return To_String (Result);
   end Percent_Encode;

   function Read_Text_File (Path : String) return String;

   function Session_Field (Config : Client_Config; Name : String) return String is
   begin
      return Project_Tools.JSON.Field_Value
        (Read_Text_File (To_String (Config.Session_File)), Name);
   end Session_Field;

   function Descriptor_Boolean
     (Config : Client_Config; Name : String) return Boolean
   is
      Value : constant String := Session_Field (Config, Name);
   begin
      return Value = "true" or else Value = "1" or else Value = "yes";
   exception
      when others =>
         return False;
   end Descriptor_Boolean;

   function Descriptor_Positive
     (Config : Client_Config; Name : String; Default : Positive) return Positive
   is
      Value : constant String := Session_Field (Config, Name);
   begin
      if Value'Length = 0 then
         return Default;
      end if;
      return Positive'Value (Value);
   exception
      when others =>
         return Default;
   end Descriptor_Positive;

   function Natural_Text (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      if Image'Length > 0 and then Image (Image'First) = ' ' then
         return Image (Image'First + 1 .. Image'Last);
      end if;
      return Image;
   end Natural_Text;

   function Native_API_Enabled (Config : Client_Config) return Boolean is
   begin
      return Descriptor_Boolean (Config, "proton_drive_native_api");
   end Native_API_Enabled;

   function Native_Wire_Contract (Config : Client_Config) return String is
   begin
      return Session_Field (Config, "proton_drive_wire_contract");
   exception
      when others =>
         return "";
   end Native_Wire_Contract;

   function Wire_Contract (Config : Client_Config) return String is
   begin
      return Native_Wire_Contract (Config);
   end Wire_Contract;

   function Descriptor_Text
     (Config : Client_Config; Name : String) return String is
   begin
      return Session_Field (Config, Name);
   exception
      when others =>
         return "";
   end Descriptor_Text;

   function Auth_Capability_Present (Config : Client_Config) return Boolean is
   begin
      return Descriptor_Boolean (Config, "proton_drive_auth_provider")
        or else Descriptor_Text (Config, "proton_drive_auth_provider_url")'Length > 0
        or else Length (Config.Session_File) > 0;
   end Auth_Capability_Present;

   function Descriptor_Schema_Valid
     (Config : Client_Config; Diagnostic : out Unbounded_String) return Boolean
   is
      Schema : constant String := Descriptor_Text (Config, "proton_drive_descriptor_version");
      SDK    : constant String := Descriptor_Text (Config, "proton_drive_sdk_generation");
   begin
      if Schema'Length > 0 and then Schema /= "1" then
         Diagnostic := To_Unbounded_String
           ("unsupported Proton Drive descriptor version: " & Schema);
         return False;
      elsif Native_API_Enabled (Config)
        and then SDK'Length > 0
        and then SDK /= "ada-compat-v1"
      then
         Diagnostic := To_Unbounded_String
           ("unsupported Proton Drive SDK compatibility generation: " & SDK);
         return False;
      elsif Native_API_Enabled (Config)
        and then Native_Wire_Contract (Config) /= "proton-drive-sdk-compat-v1"
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive native API mode requires proton_drive_wire_contract=proton-drive-sdk-compat-v1");
         return False;
      end if;
      return True;
   end Descriptor_Schema_Valid;

   function Operation_Template (Config : Client_Config; Name : String) return String is
      Specific : constant String := Session_Field (Config, "proton_drive_" & Name & "_url");
      Base     : constant String := Session_Field (Config, "proton_drive_operation_base_url");
      Native_Base : constant String := Normalized_API_Base (Config) & "/api/drive/v1";
   begin
      if Specific'Length > 0 then
         return Specific;
      elsif Base'Length > 0 then
         if Name = "upload" then
            return Base & "/shares/{share_id}/files/{remote_name}?parent={parent_path}";
         elsif Name = "download" then
            return Base & "/shares/{share_id}/files/{remote_path}";
         elsif Name = "delete" then
            return Base & "/shares/{share_id}/files/{remote_path}";
         elsif Name = "list" then
            return Base & "/shares/{share_id}/children?path={remote_path}";
         elsif Name = "events" then
            return Base & "/shares/{share_id}/events?after={after}";
         elsif Name = "refresh" then
            return Base & "/auth/refresh";
         elsif Name = "login" then
            return Base & "/auth/login";
         elsif Name = "mfa" then
            return Base & "/auth/mfa";
         elsif Name = "session_bootstrap" then
            return Base & "/auth/session";
         elsif Name = "upload_start" then
            return Base & "/shares/{share_id}/uploads?parent={parent_path}&name={remote_name}";
         elsif Name = "upload_chunk" then
            return Base & "/shares/{share_id}/uploads/{upload_id}/parts/{part_number}";
         elsif Name = "upload_finish" then
            return Base & "/shares/{share_id}/uploads/{upload_id}/complete";
         elsif Name = "create_folder" then
            return Base & "/shares/{share_id}/folders?parent={parent_path}&name={remote_name}";
         elsif Name = "conflict" then
            return Base & "/shares/{share_id}/conflicts?path={remote_path}";
         elsif Name = "list_continue" then
            return Base & "/shares/{share_id}/children?path={remote_path}&page_token={after}";
         elsif Name = "events_continue" then
            return Base & "/shares/{share_id}/events?after={after}";
         elsif Name = "resume_upload" then
            return Base & "/shares/{share_id}/uploads/{upload_id}/resume";
         elsif Name = "trash" then
            return Base & "/shares/{share_id}/trash?path={remote_path}";
         elsif Name = "revision" then
            return Base & "/shares/{share_id}/revisions?path={remote_path}";
         else
            return "";
         end if;
      elsif Native_API_Enabled (Config) then
         if Name = "upload" then
            return Native_Base & "/shares/{share_id}/files/{remote_name}?parent={parent_path}";
         elsif Name = "download" then
            return Native_Base & "/shares/{share_id}/files/{remote_path}";
         elsif Name = "delete" then
            return Native_Base & "/shares/{share_id}/files/{remote_path}";
         elsif Name = "list" then
            return Native_Base & "/shares/{share_id}/children?path={remote_path}";
         elsif Name = "events" then
            return Native_Base & "/shares/{share_id}/events?after={after}";
         elsif Name = "refresh" then
            return Native_Base & "/auth/refresh";
         elsif Name = "login" then
            return Native_Base & "/auth/login";
         elsif Name = "mfa" then
            return Native_Base & "/auth/mfa";
         elsif Name = "session_bootstrap" then
            return Native_Base & "/auth/session";
         elsif Name = "upload_start" then
            return Native_Base & "/shares/{share_id}/uploads?parent={parent_path}&name={remote_name}";
         elsif Name = "upload_chunk" then
            return Native_Base & "/shares/{share_id}/uploads/{upload_id}/parts/{part_number}";
         elsif Name = "upload_finish" then
            return Native_Base & "/shares/{share_id}/uploads/{upload_id}/complete";
         elsif Name = "create_folder" then
            return Native_Base & "/shares/{share_id}/folders?parent={parent_path}&name={remote_name}";
         elsif Name = "conflict" then
            return Native_Base & "/shares/{share_id}/conflicts?path={remote_path}";
         elsif Name = "list_continue" then
            return Native_Base & "/shares/{share_id}/children?path={remote_path}&page_token={after}";
         elsif Name = "events_continue" then
            return Native_Base & "/shares/{share_id}/events?after={after}";
         elsif Name = "resume_upload" then
            return Native_Base & "/shares/{share_id}/uploads/{upload_id}/resume";
         elsif Name = "trash" then
            return Native_Base & "/shares/{share_id}/trash?path={remote_path}";
         elsif Name = "revision" then
            return Native_Base & "/shares/{share_id}/revisions?path={remote_path}";
         else
            return "";
         end if;
      else
         return "";
      end if;
   end Operation_Template;

   function Auth_Operation_Template (Config : Client_Config; Name : String) return String is
      Specific : constant String := Session_Field (Config, "proton_drive_" & Name & "_url");
      Base     : constant String := Session_Field (Config, "proton_drive_operation_base_url");
   begin
      if Specific'Length > 0 then
         return Specific;
      elsif Base'Length > 0 then
         if Name = "refresh" then
            return Base & "/auth/refresh";
         elsif Name = "login" then
            return Base & "/auth/login";
         elsif Name = "mfa" then
            return Base & "/auth/mfa";
         elsif Name = "session_bootstrap" then
            return Base & "/auth/session";
         else
            return "";
         end if;
      else
         return "";
      end if;
   end Auth_Operation_Template;

   function Operation_URL
     (Config      : Client_Config;
      Name        : String;
      Parent_Path : String := "";
      Remote_Name : String := "";
      Remote_Path : String := "";
      After       : String := "";
      Upload_Id   : String := "";
      Part_Number : String := "") return String
   is
      URL : Unbounded_String := To_Unbounded_String (Operation_Template (Config, Name));
   begin
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{share_id}", Percent_Encode (To_String (Config.Share_Id))));
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{parent_path}", Percent_Encode (Parent_Path)));
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{remote_name}", Percent_Encode (Remote_Name)));
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{remote_path}", Percent_Encode (Remote_Path)));
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{after}", Percent_Encode (After)));
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{upload_id}", Percent_Encode (Upload_Id)));
      URL := To_Unbounded_String
        (Replace_All (To_String (URL), "{part_number}", Percent_Encode (Part_Number)));
      return To_String (URL);
   end Operation_URL;

   function File_Text (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
      Size : Ada.Streams.Stream_IO.Count;
   begin
      if Path'Length = 0 or else not Ada.Directories.Exists (Path) then
         return "";
      end if;
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Size := Ada.Streams.Stream_IO.Size (File);
      if Size = 0 then
         Ada.Streams.Stream_IO.Close (File);
         return "";
      elsif Size > Ada.Streams.Stream_IO.Count (Natural'Last) then
         Ada.Streams.Stream_IO.Close (File);
         return "";
      end if;
      declare
         Buffer : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Size));
         Last : Ada.Streams.Stream_Element_Offset;
         Result : String (1 .. Natural (Size));
      begin
         Ada.Streams.Stream_IO.Read (File, Buffer, Last);
         Ada.Streams.Stream_IO.Close (File);
         for Index in Result'Range loop
            Result (Index) := Character'Val (Integer (Buffer (Ada.Streams.Stream_Element_Offset (Index))));
         end loop;
         return Result;
      end;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end File_Text;

   function File_Slice_Text
     (Path : String; Offset : Ada.Streams.Stream_IO.Count; Length : Positive)
      return String
   is
      File : Ada.Streams.Stream_IO.File_Type;
      Buffer : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Length));
      Last : Ada.Streams.Stream_Element_Offset;
      Result : String (1 .. Length);
   begin
      if Path'Length = 0 or else not Ada.Directories.Exists (Path) then
         return "";
      end if;
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      Ada.Streams.Stream_IO.Set_Index (File, Offset + 1);
      Ada.Streams.Stream_IO.Read (File, Buffer, Last);
      Ada.Streams.Stream_IO.Close (File);
      if Last < Buffer'Last then
         declare
            Short : String (1 .. Natural (Last));
         begin
            for Index in Short'Range loop
               Short (Index) := Character'Val
                 (Integer (Buffer (Ada.Streams.Stream_Element_Offset (Index))));
            end loop;
            return Short;
         end;
      end if;
      for Index in Result'Range loop
         Result (Index) := Character'Val
           (Integer (Buffer (Ada.Streams.Stream_Element_Offset (Index))));
      end loop;
      return Result;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end File_Slice_Text;

   procedure Write_File_Text (Path : String; Text : String) is
      File : Ada.Streams.Stream_IO.File_Type;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
   begin
      if Path'Length = 0 then
         return;
      end if;
      declare
         Dir : constant String := Ada.Directories.Containing_Directory (Path);
      begin
         if Dir'Length > 0 and then not Ada.Directories.Exists (Dir) then
            Ada.Directories.Create_Path (Dir);
         end if;
      exception
         when others => null;
      end;
      for Index in Text'Range loop
         Buffer (Ada.Streams.Stream_Element_Offset (Index - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (Index)));
      end loop;
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      if Text'Length > 0 then
         Ada.Streams.Stream_IO.Write (File, Buffer);
      end if;
      Ada.Streams.Stream_IO.Close (File);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
   end Write_File_Text;

   function HTTP_Status_OK (Code : Natural; For_Upload : Boolean := False) return Boolean is
   begin
      return Code = 200 or else Code = 202 or else Code = 204 or else (For_Upload and then Code = 201);
   end HTTP_Status_OK;

   function Execute_HTTP
     (Item       : Client;
      Method     : Http_Client.Types.Method_Name;
      URL        : String;
      Payload    : String;
      Content_Type : String;
      Response   : out Unbounded_String;
      Code       : out Natural;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      URI     : Http_Client.URI.URI_Reference;
      Headers : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      Request : Http_Client.Requests.Request;
      Client  : constant Http_Client.Clients.Client := Http_Client.Clients.Create;
      Result  : Http_Client.Responses.Response;
      Status  : Http_Client.Errors.Result_Status;
   begin
      Response := Null_Unbounded_String;
      Code := 0;
      if URL'Length = 0 then
         Diagnostic := To_Unbounded_String ("Proton Drive operation provider URL is missing");
         return SDK_Operations_Unavailable;
      end if;
      Status := Http_Client.URI.Parse (URL, URI);
      if Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("invalid Proton Drive operation URL: " & URL);
         return SDK_Invalid_Config;
      end if;
      Status := Http_Client.Headers.Set (Headers, "Authorization", "Bearer " & To_String (Item.Session.Access_Token));
      if Status = Http_Client.Errors.Ok then
         Status := Http_Client.Headers.Set (Headers, "x-pm-uid", To_String (Item.Session.UID));
      end if;
      if Status = Http_Client.Errors.Ok then
         Status := Http_Client.Headers.Set (Headers, "x-pm-appversion", To_String (Item.Config.App_Version));
      end if;
      if Content_Type'Length > 0 and then Status = Http_Client.Errors.Ok then
         Status := Http_Client.Headers.Set (Headers, "Content-Type", Content_Type);
      end if;
      if Status = Http_Client.Errors.Ok
        and then Length (Item.Crypto.Metadata_Key_Fingerprint) > 0
      then
         Status := Http_Client.Headers.Set
           (Headers, "x-backup-proton-metadata-key",
            To_String (Item.Crypto.Metadata_Key_Fingerprint));
      end if;
      if Status = Http_Client.Errors.Ok
        and then Length (Item.Crypto.Content_Tag_Key_Fingerprint) > 0
      then
         Status := Http_Client.Headers.Set
           (Headers, "x-backup-proton-content-tag-key",
            To_String (Item.Crypto.Content_Tag_Key_Fingerprint));
      end if;
      if Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("could not prepare Proton Drive request headers");
         return SDK_Invalid_Config;
      end if;
      Status := Http_Client.Requests.Create
        (Method => Method, URI => URI, Item => Request, Headers => Headers,
         Payload => Payload);
      if Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("could not create Proton Drive HTTP request");
         return SDK_Invalid_Config;
      end if;
      if Payload'Length > 0 then
         Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String (Payload));
      end if;
      if Status = Http_Client.Errors.Ok then
         Status := Http_Client.Clients.Execute (Client, Request, Result);
      end if;
      if Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("Proton Drive HTTP operation failed: " & Http_Client.Errors.Result_Status'Image (Status));
         return SDK_HTTP_Failed;
      end if;
      Code := Natural (Http_Client.Responses.Status_Code (Result));
      Response := To_Unbounded_String (Http_Client.Responses.Response_Body (Result));
      if Code = 401 or else Code = 403 then
         Diagnostic := To_Unbounded_String ("Proton Drive provider rejected authentication");
         return SDK_Provider_Missing;
      elsif Code = 404 then
         Diagnostic := To_Unbounded_String ("Proton Drive provider object was not found");
         return SDK_Not_Found;
      elsif Code = 429 then
         Diagnostic := To_Unbounded_String ("Proton Drive provider rate limited the request");
         return SDK_Rate_Limited;
      elsif not HTTP_Status_OK (Code, Method = Http_Client.Types.PUT or else Method = Http_Client.Types.POST) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive provider returned status" & Natural'Image (Code));
         return SDK_HTTP_Failed;
      end if;
      Diagnostic := Null_Unbounded_String;
      return SDK_Ok;
   end Execute_HTTP;

   function Read_Text_File (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Text : Unbounded_String;
   begin
      if Path'Length = 0 or else not Ada.Directories.Exists (Path) then
         return "";
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         if Length (Text) > 0 then
            Append (Text, ASCII.LF);
         end if;
         Append (Text, Ada.Text_IO.Get_Line (File));
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Text);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Read_Text_File;

   function Load_Session
     (Path       : String;
      Session    : out Session_Info;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      Text : constant String := Read_Text_File (Path);
   begin
      Session :=
        (UID           => Null_Unbounded_String,
         Access_Token  => Null_Unbounded_String,
         Refresh_Token => Null_Unbounded_String,
         Address_Id    => Null_Unbounded_String);

      if Path'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session provider is required; upstream SDK does not include authentication or session management");
         return SDK_Provider_Missing;
      elsif Text'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file could not be read: " & Path);
         return SDK_Provider_Missing;
      end if;

      Session.UID := To_Unbounded_String (Project_Tools.JSON.Field_Value (Text, "uid"));
      Session.Access_Token :=
        To_Unbounded_String (Project_Tools.JSON.Field_Value (Text, "access_token"));
      Session.Refresh_Token :=
        To_Unbounded_String (Project_Tools.JSON.Field_Value (Text, "refresh_token"));
      Session.Address_Id :=
        To_Unbounded_String (Project_Tools.JSON.Field_Value (Text, "address_id"));

      if Length (Session.UID) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing uid");
         return SDK_Provider_Missing;
      elsif Length (Session.Access_Token) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing access_token");
         return SDK_Provider_Missing;
      end if;

      Diagnostic := Null_Unbounded_String;
      return SDK_Ok;
   end Load_Session;

   function Resolve_User_Address
     (Config     : Client_Config;
      Session    : Session_Info;
      Address    : out User_Address_Info;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      Text : constant String := Read_Text_File (To_String (Config.Session_File));
      Configured_Email : constant String := To_String (Config.User_Address);
      Session_Email : constant String := Project_Tools.JSON.Field_Value (Text, "user_address");
      Key_Id : constant String := Project_Tools.JSON.Field_Value (Text, "address_key_id");
   begin
      Address :=
        (Email      => Null_Unbounded_String,
         Address_Id => Null_Unbounded_String,
         Key_Id     => Null_Unbounded_String);

      if Configured_Email'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive user address provider is required; upstream SDK does not include a user address provider");
         return SDK_Provider_Missing;
      elsif Session_Email'Length > 0 and then Session_Email /= Configured_Email then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session user_address does not match configured proton_drive_user_address");
         return SDK_Provider_Missing;
      elsif Length (Session.Address_Id) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing address_id for configured user address");
         return SDK_Provider_Missing;
      elsif Key_Id'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing address_key_id for configured user address");
         return SDK_Provider_Missing;
      end if;

      Address.Email := To_Unbounded_String (Configured_Email);
      Address.Address_Id := Session.Address_Id;
      Address.Key_Id := To_Unbounded_String (Key_Id);
      Diagnostic := Null_Unbounded_String;
      return SDK_Ok;
   end Resolve_User_Address;

   function Load_Crypto_Context
     (Config     : Client_Config;
      Session    : Session_Info;
      Address    : User_Address_Info;
      Context    : out Crypto_Context;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      Text : constant String := Read_Text_File (To_String (Config.Session_File));
      Address_Key_Material : constant String :=
        Descriptor_Key_Material (Text, "address_key_material");
      Address_Key_Fingerprint : constant String :=
        Project_Tools.JSON.Field_Value (Text, "address_key_fingerprint");
      Metadata_Key_Id : constant String :=
        Project_Tools.JSON.Field_Value (Text, "metadata_key_id");
      Metadata_Key : constant String :=
        Descriptor_Key_Material (Text, "metadata_hmac_key");
      Node_Key_Material : constant String :=
        Descriptor_Key_Material (Text, "node_key_material");
      Content_Key_Material : constant String :=
        Descriptor_Key_Material (Text, "content_key_material");
      Content_HMAC_Key : constant String :=
        Descriptor_Key_Material (Text, "content_hmac_key");
      Bound_Text : constant String :=
        To_String (Session.UID) & ASCII.LF &
        To_String (Address.Address_Id) & ASCII.LF &
        To_String (Address.Key_Id) & ASCII.LF &
        Address_Key_Material;
      Derived_Address_Fingerprint : constant String := SHA256_Hex (Bound_Text);
   begin
      Context :=
        (Address_Key_Fingerprint  => Null_Unbounded_String,
         Metadata_Key_Id          => Null_Unbounded_String,
         Metadata_Key_Fingerprint => Null_Unbounded_String,
         Node_Key_Fingerprint     => Null_Unbounded_String,
         Content_Key_Fingerprint  => Null_Unbounded_String,
         Content_Tag_Key_Fingerprint => Null_Unbounded_String);

      if Address_Key_Material'Length = 0
        and then Encrypted_Key_Material_Present (Text, "address_key_material")
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive could not unlock encrypted address_key_material from the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Metadata_Key'Length = 0
        and then Encrypted_Key_Material_Present (Text, "metadata_hmac_key")
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive could not unlock encrypted metadata_hmac_key from the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Node_Key_Material'Length = 0
        and then Encrypted_Key_Material_Present (Text, "node_key_material")
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive could not unlock encrypted node_key_material from the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Content_Key_Material'Length = 0
        and then Encrypted_Key_Material_Present (Text, "content_key_material")
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive could not unlock encrypted content_key_material from the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Content_HMAC_Key'Length = 0
        and then Encrypted_Key_Material_Present (Text, "content_hmac_key")
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive could not unlock encrypted content_hmac_key from the session descriptor");
         return SDK_Crypto_Unavailable;
      end if;

      if Address_Key_Material'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing address_key_material for CryptoLib-backed crypto binding");
         return SDK_Crypto_Unavailable;
      elsif Metadata_Key_Id'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing metadata_key_id for encrypted metadata");
         return SDK_Crypto_Unavailable;
      elsif Metadata_Key'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session file is missing metadata_hmac_key for encrypted metadata");
         return SDK_Crypto_Unavailable;
      elsif Native_API_Enabled (Config) and then Node_Key_Material'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive native API mode requires node_key_material in the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Native_API_Enabled (Config) and then Content_Key_Material'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive native API mode requires content_key_material in the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Native_API_Enabled (Config) and then Content_HMAC_Key'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive native API mode requires content_hmac_key in the session descriptor");
         return SDK_Crypto_Unavailable;
      elsif Address_Key_Fingerprint'Length > 0
        and then Address_Key_Fingerprint /= Derived_Address_Fingerprint
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive session address_key_fingerprint does not match address key material");
         return SDK_Crypto_Unavailable;
      end if;

      Context.Address_Key_Fingerprint :=
        To_Unbounded_String (Derived_Address_Fingerprint);
      Context.Metadata_Key_Id := To_Unbounded_String (Metadata_Key_Id);
      Context.Metadata_Key_Fingerprint := To_Unbounded_String
        (SHA256_Hex
           (To_String (Session.UID) & ASCII.LF &
            To_String (Address.Address_Id) & ASCII.LF &
            Metadata_Key_Id & ASCII.LF & Metadata_Key));
      if Node_Key_Material'Length > 0 then
         Context.Node_Key_Fingerprint := To_Unbounded_String
           (SHA256_Hex
              (To_String (Session.UID) & ASCII.LF &
               To_String (Address.Address_Id) & ASCII.LF &
               "node" & ASCII.LF & Node_Key_Material));
      end if;
      if Content_Key_Material'Length > 0 then
         Context.Content_Key_Fingerprint := To_Unbounded_String
           (SHA256_Hex
              (To_String (Session.UID) & ASCII.LF &
               To_String (Address.Address_Id) & ASCII.LF &
               "content" & ASCII.LF & Content_Key_Material));
      end if;
      if Content_HMAC_Key'Length > 0 then
         Context.Content_Tag_Key_Fingerprint := To_Unbounded_String
           (SHA256_Hex
              (To_String (Session.UID) & ASCII.LF &
               To_String (Address.Address_Id) & ASCII.LF &
               "content-tag" & ASCII.LF & Content_HMAC_Key));
      end if;
      Diagnostic := Null_Unbounded_String;
      return SDK_Ok;
   end Load_Crypto_Context;

   function Metadata_Canonical_Text
     (Name : String;
      Kind : Node_Kind;
      Size : Interfaces.Unsigned_64) return String
   is
      Kind_Text : constant String :=
        (if Kind = Node_File then "file" else "folder");
   begin
      return "name=" & Name & ASCII.LF &
        "kind=" & Kind_Text & ASCII.LF &
        "size=" & Interfaces.Unsigned_64'Image (Size) & ASCII.LF;
   end Metadata_Canonical_Text;

   function Metadata_Authentication_Tag
     (Context : Crypto_Context;
      Metadata : String) return String
   is
      Key_Text : constant String :=
        To_String (Context.Metadata_Key_Id) & ASCII.LF &
        To_String (Context.Metadata_Key_Fingerprint);
   begin
      if Length (Context.Metadata_Key_Id) = 0
        or else Length (Context.Metadata_Key_Fingerprint) = 0
      then
         return "";
      end if;
      return HMAC_SHA256_Hex (Key_Text, Metadata);
   end Metadata_Authentication_Tag;

   function Content_Block_Tag
     (Context     : Crypto_Context;
      Remote_Path : String;
      Part_Number : Positive;
      Offset      : Interfaces.Unsigned_64;
      Payload     : String) return String
   is
      Key_Text : constant String :=
        To_String (Context.Content_Tag_Key_Fingerprint) & ASCII.LF &
        To_String (Context.Content_Key_Fingerprint);
      Canonical : constant String :=
        "path=" & Remote_Path & ASCII.LF &
        "part=" & Natural_Text (Part_Number) & ASCII.LF &
        "offset=" & Interfaces.Unsigned_64'Image (Offset) & ASCII.LF &
        "payload_sha256=" & SHA256_Hex (Payload) & ASCII.LF;
   begin
      if Length (Context.Content_Tag_Key_Fingerprint) = 0 then
         return "";
      end if;
      return HMAC_SHA256_Hex (Key_Text, Canonical);
   end Content_Block_Tag;

   function Tagged_Content_Block
     (Context     : Crypto_Context;
      Remote_Path : String;
      Part_Number : Positive;
      Offset      : Interfaces.Unsigned_64;
      Payload     : String) return String
   is
      Block_Tag : constant String :=
        Content_Block_Tag (Context, Remote_Path, Part_Number, Offset, Payload);
   begin
      if Block_Tag'Length = 0 then
         return Payload;
      end if;
      return "PROTON-BLOCK-TAG:" & Block_Tag & ASCII.LF & Payload;
   end Tagged_Content_Block;

   function Streaming_Content_Block
     (Context     : Crypto_Context;
      Remote_Path : String;
      Part_Number : Positive;
      Offset      : Interfaces.Unsigned_64;
      Payload     : String) return String
   is
      Key        : constant String := Streaming_Key (Context);
      Nonce      : constant String := HMAC_SHA256_Hex
        (Key, Remote_Path & ASCII.LF & Natural_Text (Part_Number) & ASCII.LF &
         Interfaces.Unsigned_64'Image (Offset));
      Ciphertext : constant String := XOR_With_Derived_Stream (Key, Nonce, Payload);
      Cipher_Hex : constant String := Hex_Text (Ciphertext);
      Header     : constant String :=
        "PROTON-STREAM-BLOCK-V1" & ASCII.LF &
        "path=" & Remote_Path & ASCII.LF &
        "part=" & Natural_Text (Part_Number) & ASCII.LF &
        "offset=" & Interfaces.Unsigned_64'Image (Offset) & ASCII.LF &
        "nonce=" & Nonce & ASCII.LF &
        "ciphertext=" & Cipher_Hex & ASCII.LF;
      Tag        : constant String := HMAC_SHA256_Hex (Key, Header);
   begin
      if Length (Context.Content_Tag_Key_Fingerprint) = 0
        or else Length (Context.Content_Key_Fingerprint) = 0
      then
         return Tagged_Content_Block
           (Context, Remote_Path, Part_Number, Offset, Payload);
      end if;
      return Header & "tag=" & Tag & ASCII.LF;
   end Streaming_Content_Block;

   function Open_Streaming_Content_Block
     (Context     : Crypto_Context;
      Remote_Path : String;
      Body_Text   : String;
      Payload     : out Unbounded_String) return Boolean
   is
      Prefix     : constant String := "PROTON-STREAM-BLOCK-V1";
      Key        : constant String := Streaming_Key (Context);
      Path_Text  : constant String := Line_Value (Body_Text, "path");
      Nonce      : constant String := Line_Value (Body_Text, "nonce");
      Cipher_Hex : constant String := Line_Value (Body_Text, "ciphertext");
      Supplied   : constant String := Line_Value (Body_Text, "tag");
      Header_End : constant Natural := Ada.Strings.Fixed.Index (Body_Text, "tag=");
   begin
      Payload := Null_Unbounded_String;
      if Body_Text'Length < Prefix'Length
        or else Body_Text (Body_Text'First .. Body_Text'First + Prefix'Length - 1) /= Prefix
      then
         return False;
      elsif Path_Text /= Remote_Path or else Nonce'Length = 0
        or else Cipher_Hex'Length = 0 or else Supplied'Length = 0
        or else Header_End = 0
      then
         return False;
      end if;
      declare
         Header     : constant String := Body_Text (Body_Text'First .. Header_End - 1);
         Expected   : constant String := HMAC_SHA256_Hex (Key, Header);
         Ciphertext : constant String := Unhex_Text (Cipher_Hex);
      begin
         if Expected /= Supplied or else Ciphertext'Length * 2 /= Cipher_Hex'Length then
            return False;
         end if;
         Payload := To_Unbounded_String
           (XOR_With_Derived_Stream (Key, Nonce, Ciphertext));
         return True;
      end;
   exception
      when others =>
         Payload := Null_Unbounded_String;
         return False;
   end Open_Streaming_Content_Block;

   function Build_Metadata_Packet
     (Context : Crypto_Context;
      Name    : String;
      Kind    : Node_Kind;
      Size    : Interfaces.Unsigned_64) return Metadata_Packet
   is
      Canonical : constant String := Metadata_Canonical_Text (Name, Kind, Size);
   begin
      return
        (Canonical_Text => To_Unbounded_String (Canonical),
         Authentication_Tag =>
           To_Unbounded_String
             (Metadata_Authentication_Tag (Context, Canonical)));
   end Build_Metadata_Packet;

   function Metadata_Envelope
     (Context : Crypto_Context;
      Packet  : Metadata_Packet) return String
   is
   begin
      if Length (Packet.Authentication_Tag) = 0 then
         return "{}";
      end if;
      return "{" &
        JSON_Pair ("format", "backup-proton-metadata-v1") & "," &
        JSON_Pair ("metadata_key_id", To_String (Context.Metadata_Key_Id)) & "," &
        JSON_Pair ("metadata_key_fingerprint", To_String (Context.Metadata_Key_Fingerprint)) & "," &
        JSON_Pair ("metadata_tag", To_String (Packet.Authentication_Tag)) & "," &
        JSON_Pair ("canonical", To_String (Packet.Canonical_Text)) &
        "}";
   end Metadata_Envelope;

   function Encrypted_Metadata_Envelope
     (Context : Crypto_Context;
      Packet  : Metadata_Packet) return String
   is
      Key       : constant String := Metadata_AEAD_Key (Context);
      Plaintext : constant String :=
        To_String (Packet.Canonical_Text) &
        "metadata_tag=" & To_String (Packet.Authentication_Tag) & ASCII.LF;
      Plain     : constant String := Packet_Text (Plaintext);
      Plain_B   : constant Ada.Streams.Stream_Element_Array := To_Bytes (Plain);
      Wire_B    :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset
            (Plain'Length + CryptoLib.ChaCha20_Poly1305.Tag_Length));
      Status    : CryptoLib.Errors.Status;
      Sequence  : constant Interfaces.Unsigned_32 := Sequence_From_Context (Context);
   begin
      if Key'Length /= CryptoLib.ChaCha20_Poly1305.Key_Length
        or else Length (Packet.Authentication_Tag) = 0
      then
         return "{}";
      end if;
      Status := CryptoLib.ChaCha20_Poly1305.Seal
        (To_Bytes (Key), Sequence, Plain_B, Wire_B);
      if Status /= CryptoLib.Errors.Ok then
         return "{}";
      end if;
      return "{" &
        JSON_Pair ("format", "backup-proton-metadata-v2") & "," &
        JSON_Pair ("algorithm", "cryptolib-chacha20-poly1305") & "," &
        JSON_Pair ("metadata_key_id", To_String (Context.Metadata_Key_Id)) & "," &
        JSON_Pair ("metadata_key_fingerprint", To_String (Context.Metadata_Key_Fingerprint)) & "," &
        JSON_Pair ("sequence", Interfaces.Unsigned_32'Image (Sequence)) & "," &
        JSON_Pair ("ciphertext", Hex_Text (From_Bytes (Wire_B))) &
        "}";
   exception
      when others =>
         return "{}";
   end Encrypted_Metadata_Envelope;

   function Open_Encrypted_Metadata_Envelope
     (Context  : Crypto_Context;
      Envelope : String;
      Metadata : out Unbounded_String) return Boolean
   is
      Key        : constant String := Metadata_AEAD_Key (Context);
      Format     : constant String := Project_Tools.JSON.Field_Value (Envelope, "format");
      Algorithm  : constant String := Project_Tools.JSON.Field_Value (Envelope, "algorithm");
      Key_Id     : constant String := Project_Tools.JSON.Field_Value (Envelope, "metadata_key_id");
      Fingerprint : constant String :=
        Project_Tools.JSON.Field_Value (Envelope, "metadata_key_fingerprint");
      Cipher_Hex : constant String := Project_Tools.JSON.Field_Value (Envelope, "ciphertext");
      Cipher     : constant String := Unhex_Text (Cipher_Hex);
      Wire_B     : constant Ada.Streams.Stream_Element_Array := To_Bytes (Cipher);
      Plain_B    :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset
            (Integer'Max (0, Cipher'Length - CryptoLib.ChaCha20_Poly1305.Tag_Length)));
      Status     : CryptoLib.Errors.Status;
      Plaintext  : Unbounded_String;
   begin
      Metadata := Null_Unbounded_String;
      if Format /= "backup-proton-metadata-v2"
        or else Algorithm /= "cryptolib-chacha20-poly1305"
        or else Key_Id /= To_String (Context.Metadata_Key_Id)
        or else Fingerprint /= To_String (Context.Metadata_Key_Fingerprint)
        or else Key'Length /= CryptoLib.ChaCha20_Poly1305.Key_Length
        or else Cipher'Length < 5 + CryptoLib.ChaCha20_Poly1305.Tag_Length
        or else Cipher'Length * 2 /= Cipher_Hex'Length
      then
         return False;
      end if;
      Status := CryptoLib.ChaCha20_Poly1305.Open
        (To_Bytes (Key), Sequence_From_Context (Context), Wire_B, Plain_B);
      if Status /= CryptoLib.Errors.Ok then
         return False;
      end if;
      Plaintext := To_Unbounded_String (Packet_Payload (From_Bytes (Plain_B)));
      if Length (Plaintext) = 0
        or else Ada.Strings.Fixed.Index
          (To_String (Plaintext), "metadata_tag=") = 0
      then
         return False;
      end if;
      Metadata := Plaintext;
      return True;
   exception
      when others =>
         Metadata := Null_Unbounded_String;
         return False;
   end Open_Encrypted_Metadata_Envelope;

   function Auth_Request_Envelope (Request : Auth_Request) return String is
   begin
      return "{" &
        JSON_Pair ("username", To_String (Request.Username)) & "," &
        JSON_Pair ("password_proof", To_String (Request.Password_Proof)) & "," &
        JSON_Pair ("mfa_code", To_String (Request.MFA_Code)) & "," &
        JSON_Pair ("session_label", To_String (Request.Session_Label)) &
        "}";
   end Auth_Request_Envelope;

   procedure Append_JSON_Text_Field
     (Text  : in out Unbounded_String;
      Name  : String;
      Value : String)
   is
   begin
      if Value'Length = 0 then
         return;
      end if;
      if Length (Text) > 2 then
         Append (Text, "," & ASCII.LF);
      else
         Append (Text, ASCII.LF);
      end if;
      Append (Text, "  " & JSON_Pair (Name, Value));
   end Append_JSON_Text_Field;

   procedure Append_JSON_Boolean_Field
     (Text  : in out Unbounded_String;
      Name  : String;
      Value : Boolean)
   is
      Quote : constant Character := Character'Val (16#22#);
   begin
      if Length (Text) > 2 then
         Append (Text, "," & ASCII.LF);
      else
         Append (Text, ASCII.LF);
      end if;
      Append (Text, "  " & Quote & Name & Quote & ":" &
        (if Value then "true" else "false"));
   end Append_JSON_Boolean_Field;

   function Existing_Or_Config_User_Address (Config : Client_Config) return String is
      Configured : constant String := To_String (Config.User_Address);
   begin
      if Configured'Length > 0 then
         return Configured;
      end if;
      return Descriptor_Text (Config, "user_address");
   end Existing_Or_Config_User_Address;

   function Session_Descriptor_Text
     (Config  : Client_Config;
      Session : Session_Info) return String
   is
      Text : Unbounded_String := To_Unbounded_String ("{");

      procedure Copy_Text (Name : String) is
      begin
         Append_JSON_Text_Field (Text, Name, Descriptor_Text (Config, Name));
      end Copy_Text;

      procedure Copy_Boolean (Name : String) is
      begin
         if Descriptor_Text (Config, Name)'Length > 0
           or else Descriptor_Boolean (Config, Name)
         then
            Append_JSON_Boolean_Field (Text, Name, Descriptor_Boolean (Config, Name));
         end if;
      end Copy_Boolean;
   begin
      Append_JSON_Text_Field (Text, "uid", To_String (Session.UID));
      Append_JSON_Text_Field (Text, "access_token", To_String (Session.Access_Token));
      Append_JSON_Text_Field (Text, "refresh_token", To_String (Session.Refresh_Token));
      Append_JSON_Text_Field
        (Text, "user_address", Existing_Or_Config_User_Address (Config));
      if Length (Session.Address_Id) > 0 then
         Append_JSON_Text_Field (Text, "address_id", To_String (Session.Address_Id));
      else
         Copy_Text ("address_id");
      end if;

      Copy_Text ("address_key_id");
      Copy_Text ("address_key_material");
      Copy_Text ("address_key_fingerprint");
      Copy_Text ("metadata_key_id");
      Copy_Text ("metadata_hmac_key");
      Copy_Text ("node_key_material");
      Copy_Text ("content_key_material");
      Copy_Text ("content_hmac_key");
      Copy_Text ("proton_drive_key_unlock_passphrase");
      Copy_Text ("proton_drive_key_unlock_rounds");
      Copy_Text ("proton_drive_key_unlock_salt");
      Copy_Text ("encrypted_content_hmac_key");
      Copy_Text ("encrypted_content_key_material");
      Copy_Text ("encrypted_node_key_material");
      Copy_Text ("encrypted_metadata_hmac_key");
      Copy_Text ("encrypted_address_key_material");
      Copy_Text ("proton_drive_descriptor_version");
      Copy_Text ("proton_drive_sdk_generation");
      Copy_Text ("proton_drive_wire_contract");
      Copy_Text ("proton_drive_large_upload_threshold");
      Copy_Text ("proton_drive_large_upload_chunk_size");
      Copy_Text ("proton_drive_operation_base_url");
      Copy_Text ("proton_drive_refresh_url");
      Copy_Text ("proton_drive_login_url");
      Copy_Text ("proton_drive_mfa_url");
      Copy_Text ("proton_drive_session_bootstrap_url");
      Copy_Text ("proton_drive_upload_url");
      Copy_Text ("proton_drive_download_url");
      Copy_Text ("proton_drive_delete_url");
      Copy_Text ("proton_drive_list_url");
      Copy_Text ("proton_drive_events_url");
      Copy_Text ("proton_drive_create_folder_url");
      Copy_Text ("proton_drive_conflict_url");
      Copy_Text ("proton_drive_list_continue_url");
      Copy_Text ("proton_drive_events_continue_url");
      Copy_Text ("proton_drive_trash_url");
      Copy_Text ("proton_drive_revision_url");
      Copy_Text ("proton_drive_upload_start_url");
      Copy_Text ("proton_drive_upload_chunk_url");
      Copy_Text ("proton_drive_upload_finish_url");
      Copy_Text ("proton_drive_resume_upload_url");
      Copy_Text ("proton_drive_live_check_url");
      Copy_Boolean ("proton_drive_auth_provider");
      Copy_Boolean ("proton_drive_native_api");
      Copy_Boolean ("proton_drive_live_check");
      Append (Text, ASCII.LF & "}" & ASCII.LF);
      return To_String (Text);
   end Session_Descriptor_Text;

   function Wire_Response_Valid
     (Operation : String;
      Response  : String) return Boolean
   is
   begin
      if Operation = "refresh" or else Operation = "login"
        or else Operation = "mfa" or else Operation = "session_bootstrap"
      then
         return Project_Tools.JSON.Field_Value (Response, "access_token")'Length > 0
           and then Project_Tools.JSON.Field_Value (Response, "uid")'Length > 0;
      elsif Operation = "upload_start" then
         return Project_Tools.JSON.Field_Value (Response, "upload_id")'Length > 0;
      elsif Operation = "list" then
         return Response'Length = 0
           or else Project_Tools.JSON.Field_Value (Response, "name")'Length > 0
           or else Project_Tools.JSON.Field_Value (Response, "next_page_token")'Length > 0;
      elsif Operation = "events" then
         return Response'Length = 0
           or else Project_Tools.JSON.Field_Value (Response, "cursor")'Length > 0
           or else Project_Tools.JSON.Field_Value (Response, "next_cursor")'Length > 0
           or else Project_Tools.JSON.Field_Value (Response, "name")'Length > 0;
      else
         return True;
      end if;
   exception
      when others =>
         return False;
   end Wire_Response_Valid;

   function Has_Operation_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "upload")'Length > 0
        and then Operation_Template (Config, "download")'Length > 0
        and then Operation_Template (Config, "delete")'Length > 0
        and then Operation_Template (Config, "list")'Length > 0
        and then Operation_Template (Config, "events")'Length > 0;
   end Has_Operation_Provider;

   function Has_Large_Upload_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "upload_start")'Length > 0
        and then Operation_Template (Config, "upload_chunk")'Length > 0
        and then Operation_Template (Config, "upload_finish")'Length > 0;
   end Has_Large_Upload_Provider;

   function Has_Folder_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "create_folder")'Length > 0;
   end Has_Folder_Provider;

   function Has_Conflict_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "conflict")'Length > 0;
   end Has_Conflict_Provider;

   function Has_Resume_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "resume_upload")'Length > 0;
   end Has_Resume_Provider;

   function Has_Trash_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "trash")'Length > 0;
   end Has_Trash_Provider;

   function Has_Revision_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "revision")'Length > 0;
   end Has_Revision_Provider;

   function Has_Event_Replay_Provider (Config : Client_Config) return Boolean is
   begin
      return Operation_Template (Config, "events")'Length > 0
        and then Operation_Template (Config, "events_continue")'Length > 0;
   end Has_Event_Replay_Provider;

   function Supports_Auth_Provider (Config : Client_Config) return Boolean is
   begin
      return Auth_Capability_Present (Config);
   end Supports_Auth_Provider;

   function Supports_Login_Provider (Config : Client_Config) return Boolean is
   begin
      return Auth_Operation_Template (Config, "login")'Length > 0
        and then Auth_Operation_Template (Config, "mfa")'Length > 0
        and then Auth_Operation_Template (Config, "session_bootstrap")'Length > 0;
   end Supports_Login_Provider;

   function Supports_Native_Auth_Flow (Config : Client_Config) return Boolean is
   begin
      return Supports_Login_Provider (Config)
        and then Auth_Operation_Template (Config, "refresh")'Length > 0
        and then Auth_Capability_Present (Config);
   end Supports_Native_Auth_Flow;

   function Has_Wire_Contract (Config : Client_Config) return Boolean is
   begin
      return Native_Wire_Contract (Config) = "proton-drive-sdk-compat-v1";
   end Has_Wire_Contract;

   function Supports_Live_Compatibility_Check (Config : Client_Config) return Boolean is
   begin
      return Descriptor_Text (Config, "proton_drive_live_check_url")'Length > 0
        or else Descriptor_Boolean (Config, "proton_drive_live_check");
   end Supports_Live_Compatibility_Check;

   function Refresh_Session
     (Config     : Client_Config;
      Session    : Session_Info;
      Updated    : out Session_Info;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Auth_Operation_Template (Config, "refresh");
      Dummy_Client : constant Client :=
        (Config  => Config,
         State   => SDK_Ok,
         Detail  => Null_Unbounded_String,
         Session => Session,
         Address => (others => Null_Unbounded_String),
         Crypto  => (others => Null_Unbounded_String));
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
   begin
      Updated := Session;
      if URL'Length = 0 or else Length (Session.Refresh_Token) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive refresh requires explicit proton_drive_refresh_url or provider operation base plus refresh_token");
         return SDK_Provider_Missing;
      end if;
      Status := Execute_HTTP
        (Dummy_Client, Http_Client.Types.POST, URL,
         "refresh_token=" & Percent_Encode (To_String (Session.Refresh_Token)),
         "application/x-www-form-urlencoded", Response_Text, Code, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      elsif not Wire_Response_Valid ("refresh", To_String (Response_Text)) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive refresh response did not satisfy wire contract");
         return SDK_HTTP_Failed;
      end if;
      declare
         Token : constant String := Project_Tools.JSON.Field_Value (To_String (Response_Text), "access_token");
      begin
         if Token'Length = 0 then
            Diagnostic := To_Unbounded_String
              ("Proton Drive refresh response did not include access_token");
            return SDK_Provider_Missing;
         end if;
         Updated.Access_Token := To_Unbounded_String (Token);
      end;
      return SDK_Ok;
   end Refresh_Session;

   function Execute_Auth_Operation
     (Config     : Client_Config;
      Operation  : String;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Auth_Operation_Template (Config, Operation);
      Dummy_Client : constant Client :=
        (Config  => Config,
         State   => SDK_Ok,
         Detail  => Null_Unbounded_String,
         Session => (others => Null_Unbounded_String),
         Address => (others => Null_Unbounded_String),
         Crypto  => (others => Null_Unbounded_String));
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
   begin
      Session := (others => Null_Unbounded_String);
      if URL'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive first-party auth is not implemented by the supported SDK; configure explicit proton_drive_" & Operation & "_url or provider operation base");
         return SDK_Provider_Missing;
      end if;
      Status := Execute_HTTP
        (Dummy_Client, Http_Client.Types.POST, URL,
         Auth_Request_Envelope (Request), "application/json",
         Response_Text, Code, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      elsif not Wire_Response_Valid (Operation, To_String (Response_Text)) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive " & Operation & " response did not satisfy wire contract");
         return SDK_HTTP_Failed;
      end if;
      Session.UID := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "uid"));
      Session.Access_Token := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "access_token"));
      Session.Refresh_Token := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "refresh_token"));
      Session.Address_Id := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "address_id"));
      Diagnostic := Null_Unbounded_String;
      return SDK_Ok;
   end Execute_Auth_Operation;

   function Start_Login
     (Config     : Client_Config;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Unbounded_String) return SDK_Status is
   begin
      return Execute_Auth_Operation (Config, "login", Request, Session, Diagnostic);
   end Start_Login;

   function Complete_MFA
     (Config     : Client_Config;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Unbounded_String) return SDK_Status is
   begin
      return Execute_Auth_Operation (Config, "mfa", Request, Session, Diagnostic);
   end Complete_MFA;

   function Bootstrap_Session
     (Config     : Client_Config;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Unbounded_String) return SDK_Status is
   begin
      return Execute_Auth_Operation
        (Config, "session_bootstrap", Request, Session, Diagnostic);
   end Bootstrap_Session;

   function Login_And_Save_Session
     (Config     : Client_Config;
      Request    : Auth_Request;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      Current : Session_Info;
      Status  : SDK_Status;
   begin
      if Length (Config.Session_File) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive login requires proton_drive_session_file");
         return SDK_Invalid_Config;
      elsif not Supports_Login_Provider (Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive login requires login, MFA, and session bootstrap endpoints in the session descriptor");
         return SDK_Provider_Missing;
      end if;

      Status := Start_Login (Config, Request, Current, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      end if;

      if Length (Request.MFA_Code) > 0 then
         Status := Complete_MFA (Config, Request, Current, Diagnostic);
         if Status /= SDK_Ok then
            return Status;
         end if;
      end if;

      Status := Bootstrap_Session (Config, Request, Current, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      elsif Length (Current.UID) = 0 or else Length (Current.Access_Token) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive login did not return uid and access_token");
         return SDK_Provider_Missing;
      end if;

      Write_File_Text
        (To_String (Config.Session_File), Session_Descriptor_Text (Config, Current));
      Diagnostic := To_Unbounded_String
        ("Proton Drive session descriptor updated: " & To_String (Config.Session_File));
      return SDK_Ok;
   end Login_And_Save_Session;

   function Validate_Config
     (Config     : Client_Config;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
      App : constant String := To_String (Config.App_Version);
      API : constant String := Normalized_API_Base (Config);
      Loaded_Session : Session_Info;
      Loaded_Address : User_Address_Info;
      Loaded_Crypto : Crypto_Context;
      Status : SDK_Status;
   begin
      if not Is_App_Version_Valid (App) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive app version must follow external-drive-{name}@{semver}-{channel}+{suffix}");
         return SDK_Invalid_Config;
      elsif not Is_Official_API_Base (API) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive API base must use the official endpoint " & Default_API_Base);
         return SDK_Invalid_Config;
      elsif Length (Config.Share_Id) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive remote URL must include a share id");
         return SDK_Invalid_Config;
      elsif not Auth_Capability_Present (Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive auth/session capability is missing");
         return SDK_Provider_Missing;
      elsif not Descriptor_Schema_Valid (Config, Diagnostic) then
         return SDK_Invalid_Config;
      end if;

      Status := Load_Session (To_String (Config.Session_File), Loaded_Session, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      end if;

      Status := Resolve_User_Address
        (Config, Loaded_Session, Loaded_Address, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      end if;

      Status := Load_Crypto_Context
        (Config, Loaded_Session, Loaded_Address, Loaded_Crypto, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      end if;

      if Has_Operation_Provider (Config) then
         Diagnostic := To_Unbounded_String (SDK_Status_Text);
         return SDK_Ok;
      end if;
      Diagnostic := To_Unbounded_String
        ("Proton Drive provider operation endpoints are missing; configure proton_drive_operation_base_url or per-operation endpoint templates");
      return SDK_Operations_Unavailable;
   end Validate_Config;

   function Create
     (Config     : Client_Config;
      Diagnostic : out Unbounded_String) return Client
   is
      Loaded_Session : Session_Info;
      Loaded_Address : User_Address_Info;
      Loaded_Crypto : Crypto_Context;
      State : constant SDK_Status := Validate_Config (Config, Diagnostic);
      Provider_Diagnostic : Unbounded_String;
   begin
      if State = SDK_Crypto_Unavailable
        or else State = SDK_Operations_Unavailable
        or else State = SDK_Ok
      then
         if Load_Session
           (To_String (Config.Session_File), Loaded_Session, Provider_Diagnostic) /= SDK_Ok
         then
            null;
         elsif Resolve_User_Address
           (Config, Loaded_Session, Loaded_Address, Provider_Diagnostic) /= SDK_Ok
         then
            null;
         elsif Load_Crypto_Context
           (Config, Loaded_Session, Loaded_Address, Loaded_Crypto, Provider_Diagnostic) /= SDK_Ok
         then
            null;
         end if;
      end if;

      return
        (Config  => Config,
         State   => State,
         Detail  => Diagnostic,
         Session => Loaded_Session,
         Address => Loaded_Address,
         Crypto  => Loaded_Crypto);
   end Create;

   function Status (Item : Client) return SDK_Status is
   begin
      return Item.State;
   end Status;

   function Ready (Item : Client) return Boolean is
   begin
      return Item.State = SDK_Ok;
   end Ready;

   function Diagnostic (Item : Client) return String is
   begin
      return To_String (Item.Detail);
   end Diagnostic;

   function Session (Item : Client) return Session_Info is
   begin
      return Item.Session;
   end Session;

   function User_Address (Item : Client) return User_Address_Info is
   begin
      return Item.Address;
   end User_Address;

   function Crypto (Item : Client) return Crypto_Context is
   begin
      return Item.Crypto;
   end Crypto;

   function Has_Crypto_Context (Item : Client) return Boolean is
   begin
      return Length (Item.Crypto.Metadata_Key_Id) > 0
        and then Length (Item.Crypto.Metadata_Key_Fingerprint) > 0
        and then Length (Item.Crypto.Address_Key_Fingerprint) > 0;
   end Has_Crypto_Context;

   function Supports_Encrypted_Operations (Item : Client) return Boolean is
   begin
      if not Has_Crypto_Context (Item) then
         return False;
      elsif Native_API_Enabled (Item.Config) then
         return Length (Item.Crypto.Node_Key_Fingerprint) > 0
           and then Length (Item.Crypto.Content_Key_Fingerprint) > 0
           and then Length (Item.Crypto.Content_Tag_Key_Fingerprint) > 0;
      else
         return True;
      end if;
   end Supports_Encrypted_Operations;

   function Operation_Unavailable
     (Item       : Client;
      Operation  : String;
      Diagnostic : out Unbounded_String) return SDK_Status
   is
   begin
      if Item.State = SDK_Crypto_Unavailable then
         Diagnostic := To_Unbounded_String
           ("Proton Drive " & Operation & " requires SDK-compatible encryption and metadata support before Drive data can be modified or read");
         return SDK_Crypto_Unavailable;
      elsif Item.State = SDK_Operations_Unavailable then
         Diagnostic := To_Unbounded_String
           ("Proton Drive " & Operation & " has CryptoLib-backed crypto metadata available, but no provider operation endpoint is configured");
         return SDK_Operations_Unavailable;
      else
         Diagnostic := Item.Detail;
         return Item.State;
      end if;
   end Operation_Unavailable;

   function Large_Upload_Threshold (Config : Client_Config) return Positive is
   begin
      return Descriptor_Positive
        (Config, "proton_drive_large_upload_threshold", 8 * 1024 * 1024);
   end Large_Upload_Threshold;

   function Large_Upload_Chunk_Size (Config : Client_Config) return Positive is
   begin
      return Descriptor_Positive
        (Config, "proton_drive_large_upload_chunk_size", 4 * 1024 * 1024);
   end Large_Upload_Chunk_Size;

   function Requires_Chunked_Upload
     (Config : Client_Config;
      Size   : Interfaces.Unsigned_64) return Boolean
   is
   begin
      return Size > Interfaces.Unsigned_64 (Large_Upload_Threshold (Config));
   end Requires_Chunked_Upload;

   function Plan_Upload
     (Config : Client_Config;
      Size   : Interfaces.Unsigned_64) return Upload_Plan
   is
      Chunk : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Large_Upload_Chunk_Size (Config));
      Parts : Natural := 0;
   begin
      if Size = 0 then
         Parts := 0;
      elsif Requires_Chunked_Upload (Config, Size) then
         Parts := Natural ((Size + Chunk - 1) / Chunk);
      else
         Parts := 1;
      end if;
      return
        (Total_Size        => Size,
         Chunk_Size        => Chunk,
         Part_Count        => Parts,
         Requires_Chunking => Requires_Chunked_Upload (Config, Size));
   end Plan_Upload;

   function Supports_Streaming_Transfer (Config : Client_Config) return Boolean is
   begin
      return Has_Large_Upload_Provider (Config)
        and then Large_Upload_Chunk_Size (Config) <= Large_Upload_Threshold (Config);
   end Supports_Streaming_Transfer;

   function Upload_File_In_Chunks
     (Item        : Client;
      Parent_Path : String;
      Local_Path  : String;
      Remote_Name : String;
      Packet      : Metadata_Packet;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      Start_URL : constant String := Operation_URL
        (Item.Config, "upload_start", Parent_Path, Remote_Name,
         Parent_Path & "/" & Remote_Name);
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
      Upload_Id : Unbounded_String;
      File_Size : constant Ada.Streams.Stream_IO.Count :=
        Ada.Streams.Stream_IO.Count (Ada.Directories.Size (Local_Path));
      Chunk_Size : constant Positive := Large_Upload_Chunk_Size (Item.Config);
      Offset : Ada.Streams.Stream_IO.Count := 0;
      Part : Positive := 1;
   begin
      Status := Execute_HTTP
        (Item, Http_Client.Types.POST, Start_URL,
         "{" & JSON_Pair ("name", Remote_Name) &
         ",""metadata"":" & Metadata_Envelope (Item.Crypto, Packet) & "}",
         "application/json", Response_Text, Code, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      elsif not Wire_Response_Valid ("upload_start", To_String (Response_Text)) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive large upload start response did not satisfy wire contract");
         return SDK_HTTP_Failed;
      end if;
      Upload_Id := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "upload_id"));
      if Length (Upload_Id) = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive large upload start response did not include upload_id");
         return SDK_HTTP_Failed;
      end if;

      while Offset < File_Size loop
         declare
            Remaining : constant Ada.Streams.Stream_IO.Count := File_Size - Offset;
            This_Size : constant Positive :=
              Positive'Min (Chunk_Size, Positive (Remaining));
            Chunk : constant String := File_Slice_Text (Local_Path, Offset, This_Size);
            Chunk_URL : constant String := Operation_URL
              (Item.Config, "upload_chunk", Parent_Path, Remote_Name,
               Parent_Path & "/" & Remote_Name, Upload_Id => To_String (Upload_Id),
               Part_Number => Natural_Text (Part));
         begin
            if Chunk'Length /= This_Size then
               Diagnostic := To_Unbounded_String
                 ("could not read Proton Drive upload chunk from " & Local_Path);
               return SDK_HTTP_Failed;
            end if;
            Status := Execute_HTTP
              (Item, Http_Client.Types.PUT, Chunk_URL,
               Streaming_Content_Block
                 (Item.Crypto, Parent_Path & "/" & Remote_Name, Part,
                  Interfaces.Unsigned_64 (Offset), Chunk),
               "application/octet-stream", Response_Text, Code, Diagnostic);
            if Status /= SDK_Ok then
               return Status;
            end if;
            Offset := Offset + Ada.Streams.Stream_IO.Count (This_Size);
            Part := Part + 1;
         end;
      end loop;

      declare
         Finish_URL : constant String := Operation_URL
           (Item.Config, "upload_finish", Parent_Path, Remote_Name,
            Parent_Path & "/" & Remote_Name, Upload_Id => To_String (Upload_Id));
      begin
         Status := Execute_HTTP
           (Item, Http_Client.Types.POST, Finish_URL,
            "{""parts"":" & Natural_Text (Part - 1) &
            ",""metadata"":" & Metadata_Envelope (Item.Crypto, Packet) &
            "}", "application/json", Response_Text, Code, Diagnostic);
         if Status = SDK_Ok then
            Diagnostic := To_Unbounded_String
              ("uploaded Proton Drive object in" & Natural'Image (Part - 1) &
               " chunks with metadata tag " & To_String (Packet.Authentication_Tag));
         end if;
         return Status;
      end;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("could not upload Proton Drive chunks: " & Local_Path);
         return SDK_HTTP_Failed;
   end Upload_File_In_Chunks;

   function Upload_File
     (Item        : Client;
      Parent_Path : String;
      Local_Path  : String;
      Remote_Name : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "upload", Parent_Path, Remote_Name, Parent_Path & "/" & Remote_Name);
      File_Size : constant Ada.Directories.File_Size := Ada.Directories.Size (Local_Path);
      Plan : constant Upload_Plan := Plan_Upload (Item.Config, Interfaces.Unsigned_64 (File_Size));
      Packet : constant Metadata_Packet := Build_Metadata_Packet
        (Item.Crypto, Remote_Name, Node_File, Interfaces.Unsigned_64 (File_Size));
      Payload : constant String :=
        (if Plan.Requires_Chunking then "" else File_Text (Local_Path));
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "upload", Diagnostic);
      elsif Plan.Requires_Chunking
        and then Supports_Streaming_Transfer (Item.Config)
      then
         return Upload_File_In_Chunks
           (Item, Parent_Path, Local_Path, Remote_Name, Packet, Diagnostic);
      elsif Plan.Requires_Chunking then
         Diagnostic := To_Unbounded_String
           ("Proton Drive upload requires chunk endpoints for files above the bounded-memory threshold");
         return SDK_Operations_Unavailable;
      elsif Payload'Length = 0 and then File_Size > 0 then
         Diagnostic := To_Unbounded_String ("could not read Proton Drive upload payload: " & Local_Path);
         return SDK_HTTP_Failed;
      end if;
      declare
         Tagged_Payload : constant String :=
           Streaming_Content_Block
             (Item.Crypto, Parent_Path & "/" & Remote_Name, 1, 0, Payload);
      begin
         Status := Execute_HTTP
        (Item, Http_Client.Types.PUT, URL, Tagged_Payload, "application/octet-stream", Response_Text, Code,
         Diagnostic);
      end;
      if Status = SDK_Ok then
         Diagnostic := To_Unbounded_String
           ("uploaded Proton Drive object with metadata tag " &
            To_String (Packet.Authentication_Tag));
      end if;
      return Status;
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("could not upload Proton Drive object: " & Local_Path);
         return SDK_HTTP_Failed;
   end Upload_File;

   function Verified_Download_Payload
     (Item        : Client;
      Remote_Path : String;
      Body_Text   : String;
      Diagnostic  : out Unbounded_String) return String
   is
      Stream_Payload : Unbounded_String;
      Stream_Prefix : constant String := "PROTON-STREAM-BLOCK-V1";
      Prefix : constant String := "PROTON-BLOCK-TAG:";
      Line_End : Natural := 0;
   begin
      if Open_Streaming_Content_Block
        (Item.Crypto, Remote_Path, Body_Text, Stream_Payload)
      then
         return To_String (Stream_Payload);
      elsif Body_Text'Length >= Stream_Prefix'Length
        and then Body_Text
          (Body_Text'First .. Body_Text'First + Stream_Prefix'Length - 1) =
            Stream_Prefix
      then
         Diagnostic := To_Unbounded_String
           ("Proton Drive streaming content block did not verify");
         return "";
      elsif Body_Text'Length < Prefix'Length
        or else Body_Text (Body_Text'First .. Body_Text'First + Prefix'Length - 1) /= Prefix
      then
         return Body_Text;
      end if;

      for Index in Body_Text'First .. Body_Text'Last loop
         if Body_Text (Index) = ASCII.LF then
            Line_End := Index;
            exit;
         end if;
      end loop;
      if Line_End = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive download block tag header is unterminated");
         return "";
      end if;

      declare
         Supplied : constant String :=
           Body_Text (Body_Text'First + Prefix'Length .. Line_End - 1);
         Payload  : constant String := Body_Text (Line_End + 1 .. Body_Text'Last);
         Expected : constant String :=
           Content_Block_Tag (Item.Crypto, Remote_Path, 1, 0, Payload);
      begin
         if Expected'Length > 0 and then Supplied /= Expected then
            Diagnostic := To_Unbounded_String
              ("Proton Drive download content block tag did not verify");
            return "";
         end if;
         return Payload;
      end;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("could not verify Proton Drive download content block tag");
         return "";
   end Verified_Download_Payload;

   function Download_File
     (Item        : Client;
      Remote_Path : String;
      Local_Path  : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "download", Remote_Path => Remote_Path);
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "download", Diagnostic);
      end if;
      Status := Execute_HTTP
        (Item, Http_Client.Types.GET, URL, "", "", Response_Text, Code, Diagnostic);
      if Status = SDK_Ok then
         declare
            Payload : constant String := Verified_Download_Payload
              (Item, Remote_Path, To_String (Response_Text), Diagnostic);
         begin
            if Payload'Length = 0 and then Length (Response_Text) > 0 then
               return SDK_HTTP_Failed;
            end if;
            Write_File_Text (Local_Path, Payload);
         end;
      end if;
      return Status;
   end Download_File;

   function Delete_Node
     (Item        : Client;
      Remote_Path : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "delete", Remote_Path => Remote_Path);
      Response_Text : Unbounded_String;
      Code : Natural;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "delete", Diagnostic);
      end if;
      return Execute_HTTP
        (Item, Http_Client.Types.DELETE, URL, "", "", Response_Text, Code, Diagnostic);
   end Delete_Node;

   function Create_Folder
     (Item        : Client;
      Parent_Path : String;
      Folder_Name : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "create_folder", Parent_Path, Folder_Name,
         Parent_Path & "/" & Folder_Name);
      Packet : constant Metadata_Packet := Build_Metadata_Packet
        (Item.Crypto, Folder_Name, Node_Folder, 0);
      Response_Text : Unbounded_String;
      Code : Natural;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "create folder", Diagnostic);
      elsif not Has_Folder_Provider (Item.Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive folder creation requires proton_drive_create_folder_url or operation base");
         return SDK_Operations_Unavailable;
      end if;
      return Execute_HTTP
        (Item, Http_Client.Types.POST, URL,
         "{" & JSON_Pair ("name", Folder_Name) &
         ",""metadata"":" & Encrypted_Metadata_Envelope (Item.Crypto, Packet) & "}",
         "application/json", Response_Text, Code, Diagnostic);
   end Create_Folder;

   function Trash_Node
     (Item        : Client;
      Remote_Path : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "trash", Remote_Path => Remote_Path);
      Response_Text : Unbounded_String;
      Code : Natural;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "trash", Diagnostic);
      elsif not Has_Trash_Provider (Item.Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive trash requires proton_drive_trash_url or operation base");
         return SDK_Operations_Unavailable;
      end if;
      return Execute_HTTP
        (Item, Http_Client.Types.POST, URL, "", "", Response_Text, Code, Diagnostic);
   end Trash_Node;

   function Resolve_Conflict
     (Item        : Client;
      Remote_Path : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "conflict", Remote_Path => Remote_Path);
      Response_Text : Unbounded_String;
      Code : Natural;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "conflict resolution", Diagnostic);
      elsif not Has_Conflict_Provider (Item.Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive conflict resolution requires proton_drive_conflict_url or operation base");
         return SDK_Operations_Unavailable;
      end if;
      return Execute_HTTP
        (Item, Http_Client.Types.GET, URL, "", "", Response_Text, Code, Diagnostic);
   end Resolve_Conflict;

   function Latest_Revision
     (Item        : Client;
      Remote_Path : String;
      Revision    : out Revision_Info;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "revision", Remote_Path => Remote_Path);
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
   begin
      Revision := (others => Null_Unbounded_String);
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "revision", Diagnostic);
      elsif not Has_Revision_Provider (Item.Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive revision lookup requires proton_drive_revision_url or operation base");
         return SDK_Operations_Unavailable;
      end if;
      Status := Execute_HTTP
        (Item, Http_Client.Types.GET, URL, "", "", Response_Text, Code, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      end if;
      Revision.Revision_Id := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "revision_id"));
      Revision.Created_At := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "created_at"));
      return SDK_Ok;
   end Latest_Revision;

   function Resume_Upload
     (Item        : Client;
      Parent_Path : String;
      Remote_Name : String;
      Upload_Id   : String;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "resume_upload", Parent_Path, Remote_Name,
         Parent_Path & "/" & Remote_Name, Upload_Id => Upload_Id);
      Response_Text : Unbounded_String;
      Code : Natural;
   begin
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "resume upload", Diagnostic);
      elsif not Has_Resume_Provider (Item.Config) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive resume upload requires proton_drive_resume_upload_url or operation base");
         return SDK_Operations_Unavailable;
      elsif Upload_Id'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("Proton Drive resume upload requires a non-empty upload id");
         return SDK_Invalid_Config;
      end if;
      return Execute_HTTP
        (Item, Http_Client.Types.POST, URL, "", "", Response_Text, Code, Diagnostic);
   end Resume_Upload;

   function List_Children
     (Item        : Client;
      Remote_Path : String;
      Nodes       : out Node_Metadata_Vectors.Vector;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "list", Remote_Path => Remote_Path);
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
      Id_Text : Unbounded_String;
      Name_Text : Unbounded_String;
      Size_Text : Unbounded_String;
      Parsed_Size : Interfaces.Unsigned_64 := 0;
      begin
      Nodes.Clear;
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "list", Diagnostic);
      end if;
      Status := Execute_HTTP
        (Item, Http_Client.Types.GET, URL, "", "", Response_Text, Code, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      elsif not Wire_Response_Valid ("list", To_String (Response_Text)) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive list response did not satisfy wire contract");
         return SDK_HTTP_Failed;
      end if;
      Id_Text := To_Unbounded_String (Project_Tools.JSON.Field_Value (To_String (Response_Text), "node_id"));
      Name_Text := To_Unbounded_String (Project_Tools.JSON.Field_Value (To_String (Response_Text), "name"));
      Size_Text := To_Unbounded_String (Project_Tools.JSON.Field_Value (To_String (Response_Text), "size"));
      if Length (Size_Text) > 0 then
         begin
            Parsed_Size := Interfaces.Unsigned_64'Value (To_String (Size_Text));
         exception
            when others =>
               Parsed_Size := 0;
         end;
      end if;
      if Length (Name_Text) > 0 then
         Nodes.Append
           (Node_Metadata'(Node_Id => Id_Text,
             Name    => Name_Text,
             Kind    => (if Project_Tools.JSON.Field_Value (To_String (Response_Text), "kind") = "folder" then Node_Folder else Node_File),
             Size    => Parsed_Size));
      end if;
      declare
         Next_Token : constant String :=
           Project_Tools.JSON.Field_Value (To_String (Response_Text), "next_page_token");
      begin
         if Next_Token'Length > 0
           and then Operation_Template (Item.Config, "list_continue")'Length > 0
         then
            Diagnostic := To_Unbounded_String
              ("Proton Drive list has continuation token " & Next_Token);
         else
            Diagnostic := Null_Unbounded_String;
         end if;
      end;
      return SDK_Ok;
   end List_Children;

   function Get_Events
     (Item        : Client;
      After       : Event_Cursor;
      Batch       : out Event_Batch;
      Diagnostic  : out Unbounded_String) return SDK_Status
   is
      URL : constant String := Operation_URL
        (Item.Config, "events", After => To_String (After.Value));
      Response_Text : Unbounded_String;
      Code : Natural;
      Status : SDK_Status;
   begin
      Batch.Cursor.Value := Null_Unbounded_String;
      Batch.Nodes.Clear;
      if Item.State /= SDK_Ok then
         return Operation_Unavailable (Item, "event sync", Diagnostic);
      end if;
      Status := Execute_HTTP
        (Item, Http_Client.Types.GET, URL, "", "", Response_Text, Code, Diagnostic);
      if Status /= SDK_Ok then
         return Status;
      elsif not Wire_Response_Valid ("events", To_String (Response_Text)) then
         Diagnostic := To_Unbounded_String
           ("Proton Drive events response did not satisfy wire contract");
         return SDK_HTTP_Failed;
      end if;
      Batch.Cursor.Value := To_Unbounded_String
        (Project_Tools.JSON.Field_Value (To_String (Response_Text), "cursor"));
      if Length (Batch.Cursor.Value) = 0 then
         Batch.Cursor.Value := To_Unbounded_String
           (Project_Tools.JSON.Field_Value (To_String (Response_Text), "next_cursor"));
      end if;
      declare
         Id_Text : constant String := Project_Tools.JSON.Field_Value (To_String (Response_Text), "node_id");
         Name_Text : constant String := Project_Tools.JSON.Field_Value (To_String (Response_Text), "name");
         Kind_Text : constant String := Project_Tools.JSON.Field_Value (To_String (Response_Text), "kind");
         Size_Text : constant String := Project_Tools.JSON.Field_Value (To_String (Response_Text), "size");
         Parsed_Size : Interfaces.Unsigned_64 := 0;
      begin
         if Size_Text'Length > 0 then
            begin
               Parsed_Size := Interfaces.Unsigned_64'Value (Size_Text);
            exception
               when others =>
                  Parsed_Size := 0;
            end;
         end if;
         if Name_Text'Length > 0 then
            Batch.Nodes.Append
              (Node_Metadata'
                 (Node_Id => To_Unbounded_String (Id_Text),
                  Name    => To_Unbounded_String (Name_Text),
                  Kind    => (if Kind_Text = "folder" then Node_Folder else Node_File),
                  Size    => Parsed_Size));
         end if;
      end;
      Diagnostic := Null_Unbounded_String;
      return SDK_Ok;
   end Get_Events;
end Proton_Drive;
