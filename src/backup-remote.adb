with Ada.Calendar.Formatting;
with Ada.Characters.Latin_1;
with Ada.Containers;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Text_IO;
with GNAT.OS_Lib;
with GNAT.SHA1;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings;
with Ada.Strings.Fixed;
with Interfaces.C;
with System;

with Backup.Encryption;
with Backup.Paths;
with Backup.Platform;
with Backup.Path_Syntax;
with Backup.Remote_Syntax;
with Backup.Remote_Sync_Syntax;
with Backup.Zip;

with CryptoLib.Checksums;
with CryptoLib.Errors;
with Project_Tools.JSON;
with Proton_Drive;

with SSH_Lib.Config;
with SSH_Lib.File_Transfer;
with SSH_Lib.Remote_Names;
with SSH_Lib.SFTP;
with SSH_Lib.Sessions;

with Http_Client.Auth;
with Http_Client.Auth.Bearer;
with Http_Client.Clients;
with Http_Client.Crypto;
with Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.Request_Bodies;
with Http_Client.Requests;
with Http_Client.Responses;
with Http_Client.TLS.Client_Certificates;
with Http_Client.Transports.TLS;
with Http_Client.Types;
with Http_Client.URI;



package body Backup.Remote is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   use type Ada.Directories.File_Kind;
   use type Backup.Zip.Write_Result;
   use type Http_Client.Errors.Result_Status;
   use type Proton_Drive.SDK_Status;
   use type CryptoLib.Errors.Status;
   use type Ada.Streams.Stream_Element_Offset;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (Positive range <>) of aliased Byte;

   function EVP_SHA256 return System.Address
     with Import, Convention => C, External_Name => "EVP_sha256";

   function C_HMAC
     (EVP_MD  : System.Address;
      Key     : System.Address;
      Key_Len : Interfaces.C.int;
      Data    : System.Address;
      Data_Len : Interfaces.C.size_t;
      MD      : System.Address;
      MD_Len  : access Interfaces.C.unsigned) return System.Address
     with Import, Convention => C, External_Name => "HMAC";

   function Text_Address (Text : String) return System.Address is
   begin
      if Text'Length = 0 then
         return System.Null_Address;
      else
         return Text (Text'First)'Address;
      end if;
   end Text_Address;

   function To_Bytes (Text : String) return Byte_Array is
      Result : Byte_Array (1 .. Text'Length);
      Offset : Natural := 0;
   begin
      for Ch of Text loop
         Offset := Offset + 1;
         Result (Offset) := Byte (Character'Pos (Ch));
      end loop;
      return Result;
   end To_Bytes;

   function HMAC_SHA256 (Key : Byte_Array; Text : String) return Byte_Array is
      Result : aliased Byte_Array (1 .. 32) := [others => 0];
      Length : aliased Interfaces.C.unsigned := 0;
      Ignored : System.Address;
   begin
      Ignored := C_HMAC
        (EVP_SHA256, Key (Key'First)'Address, Interfaces.C.int (Key'Length),
         Text_Address (Text), Interfaces.C.size_t (Text'Length),
         Result (Result'First)'Address, Length'Access);
      pragma Unreferenced (Ignored);
      return Result;
   end HMAC_SHA256;

   function Hex (Bytes : Byte_Array) return String is
      Hex_Digits : constant String := "0123456789abcdef";
      Result     : String (1 .. Bytes'Length * 2);
      Pos        : Natural := Result'First;
      Value      : Natural;
   begin
      for B of Bytes loop
         Value := Natural (B);
         Result (Pos) := Hex_Digits (Hex_Digits'First + Value / 16);
         Result (Pos + 1) := Hex_Digits (Hex_Digits'First + Value mod 16);
         Pos := Pos + 2;
      end loop;
      return Result;
   end Hex;

   function Digest_File_SHA1_Hex (Path : String) return String is
      File    : Ada.Streams.Stream_IO.File_Type;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
      Last    : Ada.Streams.Stream_Element_Offset;
      Context : GNAT.SHA1.Context := GNAT.SHA1.Initial_Context;
   begin
      Ada.Streams.Stream_IO.Open
        (File, Ada.Streams.Stream_IO.In_File, Path);
      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Ada.Streams.Stream_IO.Read (File, Buffer, Last);
         if Last >= Buffer'First then
            GNAT.SHA1.Update (Context, Buffer (Buffer'First .. Last));
         end if;
      end loop;
      Ada.Streams.Stream_IO.Close (File);
      return GNAT.SHA1.Digest (Context);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end Digest_File_SHA1_Hex;

   function HTTP_Error_Status
     (Status : Http_Client.Errors.Result_Status) return Remote_Status;

   function Resolved_S3_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Options;

   function JSON_Field (Text : String; Name : String) return String;



   function Read_Text_File (Path : String) return String;

   procedure Write_Text_File (Path : String; Text : String);

   function HTTP_Post_Form_Text
     (URL        : String;
      Form       : String;
      Options    : Remote_Options;
      Text       : out Unbounded_String;
      Diagnostic : out Unbounded_String) return Remote_Status;

   function Stream_HTTP_Put
     (URL          : String;
      Path         : String;
      Length       : Interfaces.Unsigned_64;
      Backup_Crc32 : String;
      Local_Crc32  : Interfaces.Unsigned_32;
      Options      : Remote_Options;
      Result       : out Http_Client.Clients.Client_Result;
      Diagnostic   : out Unbounded_String;
      Sign_S3      : Boolean := False)
      return Remote_Status;

   function File_Metadata
     (Path       : String;
      Managed    : Boolean;
      Partial    : Boolean;
      Metadata   : out Archive_Metadata;
      Diagnostic : out Unbounded_String)
      return Remote_Status;

   procedure Delete_If_Exists (Path : String);

   function Download_PCloud_Object_By_Name
     (Location    : Remote_Location;
      Stored_Name : String;
      Local_Path  : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status;

   function Starts_With (Value : String; Prefix : String) return Boolean is
   begin
      return Value'Length >= Prefix'Length
        and then Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Ends_With (Value : String; Suffix : String) return Boolean is
   begin
      return Value'Length >= Suffix'Length
        and then Value (Value'Last - Suffix'Length + 1 .. Value'Last) = Suffix;
   end Ends_With;

   function Equal_Hex_Case_Insensitive (Left : String; Right : String) return Boolean is
      function Fold (Ch : Character) return Character is
      begin
         if Ch in 'A' .. 'F' then
            return Character'Val (Character'Pos (Ch) + 32);
         end if;
         return Ch;
      end Fold;
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;
      for Offset in 0 .. Left'Length - 1 loop
         if Fold (Left (Left'First + Offset)) /= Fold (Right (Right'First + Offset)) then
            return False;
         end if;
      end loop;
      return True;
   end Equal_Hex_Case_Insensitive;

   function Decimal (Value : Interfaces.Unsigned_64) return String is
      Image : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Decimal_32 (Value : Interfaces.Unsigned_32) return String is
      Image : constant String := Interfaces.Unsigned_32'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal_32;

   function S3_CRC32_Base64 (Value : Interfaces.Unsigned_32) return String is
      B1 : constant Natural := Natural ((Value / 16#01_00_00_00#) mod 256);
      B2 : constant Natural := Natural ((Value / 16#00_01_00_00#) mod 256);
      B3 : constant Natural := Natural ((Value / 16#00_00_01_00#) mod 256);
      B4 : constant Natural := Natural (Value mod 256);
   begin
      return Http_Client.Auth.Base64_Encode
        (Character'Val (B1) & Character'Val (B2) &
         Character'Val (B3) & Character'Val (B4));
   end S3_CRC32_Base64;

   function Decimal_Natural (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal_Natural;

   function Hex_Digit (Value : Natural) return Character is
      Hex : constant String := "0123456789abcdef";
   begin
      pragma Assert (Value <= 15, "hex digit input is in range");
      return Hex (Hex'First + Value);
   end Hex_Digit;

   function Json_Escape (Text : String) return String is
      Result : Unbounded_String;
      Code   : Natural;

      procedure Append_Escape (Escaped : Character) is
      begin
         Append (Result, '\');
         Append (Result, Escaped);
      end Append_Escape;
   begin
      for Ch of Text loop
         case Ch is
            when '"' =>
               Append_Escape ('"');
            when '\' =>
               Append_Escape ('\');
            when Ada.Characters.Latin_1.BS =>
               Append_Escape ('b');
            when Ada.Characters.Latin_1.HT =>
               Append_Escape ('t');
            when Ada.Characters.Latin_1.LF =>
               Append_Escape ('n');
            when Ada.Characters.Latin_1.FF =>
               Append_Escape ('f');
            when Ada.Characters.Latin_1.CR =>
               Append_Escape ('r');
            when others =>
               Code := Character'Pos (Ch);
               if Code < 32 then
                  Append_Escape ('u');
                  Append (Result, '0');
                  Append (Result, '0');
                  Append (Result, Hex_Digit (Code / 16));
                  Append (Result, Hex_Digit (Code mod 16));
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

   function Transport_Name (Kind : Transport_Kind) return String is
   begin
      return Backup.Remote_Syntax.Transport_Name (Kind);
   end Transport_Name;

   function Action_Name (Action : Sync_Action) return String is
   begin
      return Backup.Remote_Syntax.Action_Name (Action);
   end Action_Name;

   function Status_Text (Status : Remote_Status) return String is
   begin
      return Backup.Remote_Syntax.Status_Text (Status);
   end Status_Text;

   function Basename (Path : String) return String is
   begin
      for Index in reverse Path'Range loop
         if Path (Index) = '/' or else Path (Index) = '\' then
            if Index = Path'Last then
               return "";
            else
               return Path (Index + 1 .. Path'Last);
            end if;
         end if;
      end loop;
      return Path;
   end Basename;

   function Join (Directory : String; Name : String) return String is
   begin
      if Directory'Length = 0 or else Directory = "." then
         return Name;
      elsif Ends_With (Directory, "/") then
         return Directory & Name;
      else
         return Directory & "/" & Name;
      end if;
   end Join;

   function Remote_Object_Path (Location : Remote_Location) return String is
   begin
      return Join
        (To_String (Location.Namespace),
         To_String (Location.Object_Name));
   end Remote_Object_Path;

   function Remote_Object_URL (Location : Remote_Location) return String is
   begin
      if Ends_With (To_String (Location.Namespace), "/") then
         return To_String (Location.Namespace) & To_String (Location.Object_Name);
      else
         return To_String (Location.Namespace) & "/" & To_String (Location.Object_Name);
      end if;
   end Remote_Object_URL;

   function S3_Endpoint (Options : Remote_Options) return String is
      Value : constant String := To_String (Options.S3_Endpoint);
   begin
      if Value'Length = 0 then
         return "https://s3.amazonaws.com";
      elsif Ends_With (Value, "/") then
         return Value (Value'First .. Value'Last - 1);
      else
         return Value;
      end if;
   end S3_Endpoint;

   function S3_Region (Options : Remote_Options) return String is
      Value : constant String := To_String (Options.S3_Region);
   begin
      if Value'Length = 0 then
         return "us-east-1";
      else
         return Value;
      end if;
   end S3_Region;

   function S3_Bucket (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 5;
   begin
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            return Text (Start .. Index - 1);
         end if;
      end loop;
      return Text (Start .. Text'Last);
   end S3_Bucket;

   function S3_Prefix (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 5;
   begin
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            if Index = Text'Last then
               return "";
            else
               return Text (Index + 1 .. Text'Last);
            end if;
         end if;
      end loop;
      return "";
   end S3_Prefix;

   function S3_Key (Location : Remote_Location; Object_Name : String) return String is
      Prefix : constant String := S3_Prefix (Location);
   begin
      if Prefix'Length = 0 then
         return Object_Name;
      elsif Ends_With (Prefix, "/") then
         return Prefix & Object_Name;
      else
         return Prefix & "/" & Object_Name;
      end if;
   end S3_Key;

   function Google_Drive_API_Base (Options : Remote_Options) return String is
      Value : constant String := To_String (Options.Google_Drive_API_Base);
   begin
      if Value'Length = 0 then
         return "https://www.googleapis.com/drive/v3";
      elsif Ends_With (Value, "/") then
         return Value (Value'First .. Value'Last - 1);
      else
         return Value;
      end if;
   end Google_Drive_API_Base;

   function Google_Drive_Upload_Base (Options : Remote_Options) return String is
      Value : constant String := To_String (Options.Google_Drive_Upload_Base);
   begin
      if Value'Length = 0 then
         return "https://www.googleapis.com/upload/drive/v3";
      elsif Ends_With (Value, "/") then
         return Value (Value'First .. Value'Last - 1);
      else
         return Value;
      end if;
   end Google_Drive_Upload_Base;

   function Google_Drive_Folder_Id (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 9;
   begin
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            return Text (Start .. Index - 1);
         end if;
      end loop;
      return Text (Start .. Text'Last);
   end Google_Drive_Folder_Id;

   function Google_Drive_Prefix (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 9;
   begin
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            if Index = Text'Last then
               return "";
            else
               return Text (Index + 1 .. Text'Last);
            end if;
         end if;
      end loop;
      return "";
   end Google_Drive_Prefix;

   function Google_Drive_Name
     (Location    : Remote_Location;
      Object_Name : String) return String
   is
      Prefix : constant String := Google_Drive_Prefix (Location);
   begin
      if Prefix'Length = 0 then
         return Object_Name;
      elsif Ends_With (Prefix, "/") then
         return Prefix & Object_Name;
      else
         return Prefix & "/" & Object_Name;
      end if;
   end Google_Drive_Name;

   function PCloud_API_Base (Options : Remote_Options) return String is
      Value  : constant String := To_String (Options.PCloud_API_Base);
      Region : constant String := To_String (Options.PCloud_Region);
   begin
      if Value'Length > 0 then
         if Ends_With (Value, "/") then
            return Value (Value'First .. Value'Last - 1);
         else
            return Value;
         end if;
      elsif Region = "eu" then
         return "https://eapi.pcloud.com";
      else
         return "https://api.pcloud.com";
      end if;
   end PCloud_API_Base;

   function PCloud_Token_URI_For_Base (API_Base : String) return String is
   begin
      if API_Base'Length = 0 then
         return "https://api.pcloud.com/oauth2_token";
      else
         return API_Base & "/oauth2_token";
      end if;
   end PCloud_Token_URI_For_Base;

   function PCloud_Token_URI (Options : Remote_Options) return String is
      Value : constant String := To_String (Options.PCloud_Token_URI);
   begin
      if Value'Length = 0 then
         return PCloud_Token_URI_For_Base (PCloud_API_Base (Options));
      else
         return Value;
      end if;
   end PCloud_Token_URI;

   function PCloud_Namespace_Text (Location : Remote_Location) return String is
      Text : constant String := To_String (Location.Namespace);
   begin
      if Starts_With (Text, "pcloud://") then
         return Text (Text'First + 9 .. Text'Last);
      else
         return Text;
      end if;
   end PCloud_Namespace_Text;

   function PCloud_Namespace_Uses_Folder_Id
     (Location : Remote_Location) return Boolean
   is
      Text : constant String := PCloud_Namespace_Text (Location);
   begin
      if Text'Length = 0 then
         return False;
      end if;
      for Ch of Text loop
         exit when Ch = '/';
         if Ch not in '0' .. '9' then
            return False;
         end if;
      end loop;
      return True;
   end PCloud_Namespace_Uses_Folder_Id;

   function PCloud_Folder_Path (Location : Remote_Location) return String is
      Text : constant String := PCloud_Namespace_Text (Location);
   begin
      if Text'Length = 0 then
         return "/";
      elsif Starts_With (Text, "/") then
         return Text;
      else
         return "/" & Text;
      end if;
   end PCloud_Folder_Path;

   function PCloud_Folder_Id (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 9;
   begin
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            return Text (Start .. Index - 1);
         end if;
      end loop;
      return Text (Start .. Text'Last);
   end PCloud_Folder_Id;

   function PCloud_Prefix (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 9;
   begin
      if not PCloud_Namespace_Uses_Folder_Id (Location) then
         return "";
      end if;
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            if Index = Text'Last then
               return "";
            else
               return Text (Index + 1 .. Text'Last);
            end if;
         end if;
      end loop;
      return "";
   end PCloud_Prefix;

   function PCloud_Name
     (Location    : Remote_Location;
      Object_Name : String) return String
   is
      Prefix : constant String := PCloud_Prefix (Location);
   begin
      if Prefix'Length = 0 then
         return Object_Name;
      elsif Ends_With (Prefix, "/") then
         return Prefix & Object_Name;
      else
         return Prefix & "/" & Object_Name;
      end if;
   end PCloud_Name;

   function Proton_Drive_Share_Id (Location : Remote_Location) return String is
      Text  : constant String := To_String (Location.Namespace);
      Start : constant Natural := Text'First + 14;
   begin
      for Index in Start .. Text'Last loop
         if Text (Index) = '/' then
            return Text (Start .. Index - 1);
         end if;
      end loop;
      return Text (Start .. Text'Last);
   end Proton_Drive_Share_Id;

   function Proton_Drive_Config
     (Location : Remote_Location;
      Options  : Remote_Options) return Proton_Drive.Client_Config
   is
   begin
      return
        (App_Version  => Options.Proton_Drive_App_Version,
         API_Base     =>
           (if Length (Options.Proton_Drive_API_Base) > 0 then
              Options.Proton_Drive_API_Base
            else
              To_Unbounded_String (Proton_Drive.Default_API_Base)),
         Session_File => Options.Proton_Drive_Session_File,
         User_Address => Options.Proton_Drive_User_Address,
         Share_Id     => To_Unbounded_String (Proton_Drive_Share_Id (Location)));
   end Proton_Drive_Config;

   function Proton_Drive_Remote_Path
     (Location : Remote_Location;
      Object_Name : String) return String
   is
      Namespace : constant String := To_String (Location.Namespace);
      Share     : constant String := Proton_Drive_Share_Id (Location);
      Prefix_First : constant Natural := Namespace'First + 14 + Share'Length;
      Prefix : constant String :=
        (if Prefix_First <= Namespace'Last then Namespace (Prefix_First .. Namespace'Last) else "");
   begin
      if Prefix'Length = 0 or else Prefix = "/" then
         return Object_Name;
      elsif Prefix (Prefix'Last) = '/' then
         return Prefix & Object_Name;
      elsif Prefix (Prefix'First) = '/' then
         return Prefix & "/" & Object_Name;
      else
         return "/" & Prefix & "/" & Object_Name;
      end if;
   end Proton_Drive_Remote_Path;

   function Proton_Drive_Status
     (Status : Proton_Drive.SDK_Status) return Remote_Status
   is
   begin
      case Status is
         when Proton_Drive.SDK_Ok =>
            return Remote_Ok;
         when Proton_Drive.SDK_Invalid_Config =>
            return Remote_Invalid_URL;
         when Proton_Drive.SDK_Provider_Missing =>
            return Remote_Authentication_Failed;
         when Proton_Drive.SDK_Crypto_Unavailable
            | Proton_Drive.SDK_Operations_Unavailable =>
            return Remote_Unsupported_Transport;
         when Proton_Drive.SDK_Not_Found =>
            return Remote_Not_Found;
         when Proton_Drive.SDK_Rate_Limited =>
            return Remote_Timeout;
         when Proton_Drive.SDK_HTTP_Failed =>
            return Remote_Write_Failed;
      end case;
   end Proton_Drive_Status;

   function Proton_Drive_Client
     (Location   : Remote_Location;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Proton_Drive.Client
   is
   begin
      return Proton_Drive.Create (Proton_Drive_Config (Location, Options), Diagnostic);
   end Proton_Drive_Client;

   function Percent_Encode_Path (Path : String) return String is
      Result : Unbounded_String;
      Code   : Natural;
   begin
      for Ch of Path loop
         if Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z' or else Ch in '0' .. '9'
           or else Ch = '-' or else Ch = '_' or else Ch = '.' or else Ch = '~'
           or else Ch = '/'
         then
            Append (Result, Ch);
         else
            Code := Character'Pos (Ch);
            Append (Result, '%');
            Append (Result, Hex_Digit (Code / 16));
            Append (Result, Hex_Digit (Code mod 16));
         end if;
      end loop;
      return To_String (Result);
   end Percent_Encode_Path;


   function URL_Host (URL : String) return String;

   function Is_S3_Bucket_Character (Ch : Character) return Boolean is
   begin
      return Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z' or else Ch in '0' .. '9'
        or else Ch = '-' or else Ch = '.' or else Ch = '_';
   end Is_S3_Bucket_Character;

   function Is_Valid_S3_Bucket (Bucket : String) return Boolean is
   begin
      if Bucket'Length = 0 or else Bucket = "." or else Bucket = ".." then
         return False;
      end if;

      for Ch of Bucket loop
         if not Is_S3_Bucket_Character (Ch) then
            return False;
         end if;
      end loop;
      return True;
   end Is_Valid_S3_Bucket;

   function Is_Valid_S3_Endpoint (Endpoint : String) return Boolean is
      Host : constant String := URL_Host (Endpoint);
   begin
      if not Starts_With (Endpoint, "https://")
        and then not Starts_With (Endpoint, "http://")
      then
         return False;
      elsif Host'Length = 0 then
         return False;
      end if;

      for Ch of Endpoint loop
         if Ch = '?' or else Ch = '#' or else Character'Pos (Ch) < 32 then
            return False;
         end if;
      end loop;
      return True;
   end Is_Valid_S3_Endpoint;

   function Endpoint_Path_Prefix (Endpoint : String) return String is
      Start : Natural;
   begin
      if Starts_With (Endpoint, "https://") then
         Start := Endpoint'First + 8;
      elsif Starts_With (Endpoint, "http://") then
         Start := Endpoint'First + 7;
      else
         return "";
      end if;

      for Index in Start .. Endpoint'Last loop
         if Endpoint (Index) = '/' then
            return Endpoint (Index .. Endpoint'Last);
         end if;
      end loop;
      return "";
   end Endpoint_Path_Prefix;

   function Endpoint_Scheme (Endpoint : String) return String is
   begin
      if Starts_With (Endpoint, "https://") then
         return "https://";
      elsif Starts_With (Endpoint, "http://") then
         return "http://";
      else
         return "";
      end if;
   end Endpoint_Scheme;

   function Percent_Encode_Query_Component (Text : String) return String is
      Result : Unbounded_String;
      Code   : Natural;
   begin
      for Ch of Text loop
         if Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z' or else Ch in '0' .. '9'
           or else Ch = '-' or else Ch = '_' or else Ch = '.' or else Ch = '~'
         then
            Append (Result, Ch);
         else
            Code := Character'Pos (Ch);
            Append (Result, '%');
            Append (Result, Hex_Digit (Code / 16));
            Append (Result, Hex_Digit (Code mod 16));
         end if;
      end loop;
      return To_String (Result);
   end Percent_Encode_Query_Component;

   function Canonical_Query (Query : String) return String is
   begin
      if Query'Length = 0 then
         return "";
      elsif Ada.Strings.Fixed.Index (Query, "=") = 0 then
         return Percent_Encode_Query_Component (Query) & "=";
      else
         return Query;
      end if;
   end Canonical_Query;

   function S3_Object_URL
     (Location    : Remote_Location;
      Options     : Remote_Options;
      Object_Name : String) return String
   is
      Bucket : constant String := S3_Bucket (Location);
      Key    : constant String := Percent_Encode_Path (S3_Key (Location, Object_Name));
      Endpoint : constant String := S3_Endpoint (Options);
      Prefix   : constant String := Endpoint_Path_Prefix (Endpoint);
   begin
      if Options.S3_Virtual_Hosted_Style then
         return Endpoint_Scheme (Endpoint) & Bucket & "." & URL_Host (Endpoint) &
           (if Prefix'Length = 0 then "/" else Prefix & "/") & Key;
      else
         return Endpoint & "/" & Bucket & "/" & Key;
      end if;
   end S3_Object_URL;

   function S3_Bucket_URL
     (Location : Remote_Location;
      Options  : Remote_Options) return String
   is
      Bucket   : constant String := S3_Bucket (Location);
      Endpoint : constant String := S3_Endpoint (Options);
   begin
      if Options.S3_Virtual_Hosted_Style then
         return Endpoint_Scheme (Endpoint) & Bucket & "." & URL_Host (Endpoint) & "/";
      else
         return Endpoint & "/" & Bucket;
      end if;
   end S3_Bucket_URL;

   function Remote_Object_URL
     (Location : Remote_Location;
      Options  : Remote_Options) return String is
   begin
      if Location.Kind = Transport_S3 then
         return S3_Object_URL (Location, Options, To_String (Location.Object_Name));
      elsif Location.Kind = Transport_Google_Drive then
         return Google_Drive_API_Base (Options) & "/files/" &
           Percent_Encode_Query_Component (To_String (Location.Object_Name)) &
           "?alt=media";
      else
         return Remote_Object_URL (Location);
      end if;
   end Remote_Object_URL;

   function Remote_Index_URL
     (Location : Remote_Location;
      Options  : Remote_Options) return String is
   begin
      if Location.Kind = Transport_S3 then
         return S3_Object_URL (Location, Options, "backup-remote-index-v1");
      elsif Location.Kind = Transport_Google_Drive then
         return Google_Drive_API_Base (Options) & "/files/backup-remote-index-v1?alt=media";
      else
         return To_String (Location.Namespace);
      end if;
   end Remote_Index_URL;

   function URL_Host (URL : String) return String is
      Start : Natural;
   begin
      if Starts_With (URL, "https://") then
         Start := URL'First + 8;
      elsif Starts_With (URL, "http://") then
         Start := URL'First + 7;
      else
         return "";
      end if;
      for Index in Start .. URL'Last loop
         if URL (Index) = '/' or else URL (Index) = '?' then
            return URL (Start .. Index - 1);
         end if;
      end loop;
      return URL (Start .. URL'Last);
   end URL_Host;

   function URL_Path (URL : String) return String is
      Start : Natural;
      Stop  : Natural;
   begin
      if Starts_With (URL, "https://") then
         Start := URL'First + 8;
      elsif Starts_With (URL, "http://") then
         Start := URL'First + 7;
      else
         return "/";
      end if;
      for Index in Start .. URL'Last loop
         if URL (Index) = '/' then
            Stop := Index;
            while Stop <= URL'Last and then URL (Stop) /= '?' loop
               Stop := Stop + 1;
            end loop;
            return URL (Index .. Stop - 1);
         elsif URL (Index) = '?' then
            return "/";
         end if;
      end loop;
      return "/";
   end URL_Path;

   function URL_Query (URL : String) return String is
   begin
      for Index in URL'Range loop
         if URL (Index) = '?' then
            if Index = URL'Last then
               return "";
            else
               return URL (Index + 1 .. URL'Last);
            end if;
         end if;
      end loop;
      return "";
   end URL_Query;

   function Method_Text (Method : Http_Client.Types.Method_Name) return String is
   begin
      case Method is
         when Http_Client.Types.GET => return "GET";
         when Http_Client.Types.HEAD => return "HEAD";
         when Http_Client.Types.POST => return "POST";
         when Http_Client.Types.PUT => return "PUT";
         when Http_Client.Types.PATCH => return "PATCH";
         when Http_Client.Types.DELETE => return "DELETE";
         when Http_Client.Types.OPTIONS => return "OPTIONS";
      end case;
   end Method_Text;

   procedure S3_Timestamps (Amz_Date : out String; Date_Stamp : out String) is
      Image : constant String := Ada.Calendar.Formatting.Image
        (Ada.Calendar.Clock, Include_Time_Fraction => False, Time_Zone => 0);
   begin
      Date_Stamp := Image (Image'First .. Image'First + 3) &
        Image (Image'First + 5 .. Image'First + 6) &
        Image (Image'First + 8 .. Image'First + 9);
      Amz_Date := Date_Stamp & "T" &
        Image (Image'First + 11 .. Image'First + 12) &
        Image (Image'First + 14 .. Image'First + 15) &
        Image (Image'First + 17 .. Image'First + 18) & "Z";
   end S3_Timestamps;

   function S3_Metadata_Header (Name : String) return String is
   begin
      if Name'Length = 0 then
         return "";
      else
         return "x-amz-meta-" & Name;
      end if;
   end S3_Metadata_Header;

   function Is_S3_Metadata_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0 then
         return False;
      end if;
      for Ch of Name loop
         if not (Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z'
                 or else Ch in '0' .. '9' or else Ch = '-' or else Ch = '_')
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_S3_Metadata_Name;

   function S3_Authorization
     (Method     : Http_Client.Types.Method_Name;
      URL        : String;
      Options    : Remote_Options;
      Amz_Date   : String;
      Date_Stamp : String;
      SSE        : String;
      KMS_Key_Id : String;
      ACL        : String;
      Checksum_Algorithm : String;
      Checksum_CRC32 : String;
      Checksum_Mode : String;
      Storage_Class : String;
      Tagging    : String;
      Metadata_Name : String;
      Metadata_Value : String;
      Backup_Crc32 : String;
      Object_Lock_Mode : String;
      Object_Lock_Retain_Until : String;
      Object_Lock_Legal_Hold : String) return String
   is
      Host       : constant String := URL_Host (URL);
      Region     : constant String := S3_Region (Options);
      Scope      : constant String := Date_Stamp & "/" & Region & "/s3/aws4_request";
      Token      : constant String := To_String (Options.S3_Session_Token);
      Meta_Header : constant String := S3_Metadata_Header (Metadata_Name);
      Has_ACL    : constant Boolean := ACL'Length > 0;
      Has_Checksum_Algorithm : constant Boolean := Checksum_Algorithm'Length > 0;
      Has_Checksum_CRC32 : constant Boolean := Checksum_CRC32'Length > 0;
      Has_Checksum_Mode : constant Boolean := Checksum_Mode'Length > 0;
      Has_Storage : constant Boolean := Storage_Class'Length > 0;
      Has_Tagging : constant Boolean := Tagging'Length > 0;
      Has_Meta   : constant Boolean := Meta_Header'Length > 0;
      Has_Backup_Crc32 : constant Boolean :=
        Backup_Crc32'Length > 0 and then Meta_Header /= "x-amz-meta-backup-crc32";
      Meta_Before_Backup_Crc32 : constant Boolean :=
        Has_Meta and then Has_Backup_Crc32
        and then Meta_Header < "x-amz-meta-backup-crc32";
      Has_Lock_Mode : constant Boolean := Object_Lock_Mode'Length > 0;
      Has_Lock_Retain : constant Boolean := Object_Lock_Retain_Until'Length > 0;
      Has_Lock_Hold : constant Boolean := Object_Lock_Legal_Hold'Length > 0;
      Has_SSE    : constant Boolean := SSE'Length > 0;
      Has_KMS    : constant Boolean := KMS_Key_Id'Length > 0;
      Signed     : constant String :=
        "host" &
        (if Has_ACL then ";x-amz-acl" else "") &
        (if Has_Checksum_Algorithm then ";x-amz-checksum-algorithm" else "") &
        (if Has_Checksum_CRC32 then ";x-amz-checksum-crc32" else "") &
        (if Has_Checksum_Mode then ";x-amz-checksum-mode" else "") &
        ";x-amz-content-sha256;x-amz-date" &
        (if Has_Meta and then Meta_Before_Backup_Crc32 then ";" & Meta_Header else "") &
        (if Has_Backup_Crc32 then ";x-amz-meta-backup-crc32" else "") &
        (if Has_Meta and then not Meta_Before_Backup_Crc32 then ";" & Meta_Header else "") &
        (if Has_Lock_Hold then ";x-amz-object-lock-legal-hold" else "") &
        (if Has_Lock_Mode then ";x-amz-object-lock-mode" else "") &
        (if Has_Lock_Retain then ";x-amz-object-lock-retain-until-date" else "") &
        (if Token'Length = 0 then "" else ";x-amz-security-token") &
        (if Has_SSE then ";x-amz-server-side-encryption" else "") &
        (if Has_KMS then ";x-amz-server-side-encryption-aws-kms-key-id" else "") &
        (if Has_Storage then ";x-amz-storage-class" else "") &
        (if Has_Tagging then ";x-amz-tagging" else "");
      Canonical_Headers : constant String :=
        "host:" & Host & ASCII.LF &
        (if Has_ACL then "x-amz-acl:" & ACL & ASCII.LF else "") &
        (if Has_Checksum_Algorithm then "x-amz-checksum-algorithm:" & Checksum_Algorithm & ASCII.LF else "") &
        (if Has_Checksum_CRC32 then "x-amz-checksum-crc32:" & Checksum_CRC32 & ASCII.LF else "") &
        (if Has_Checksum_Mode then "x-amz-checksum-mode:" & Checksum_Mode & ASCII.LF else "") &
        "x-amz-content-sha256:UNSIGNED-PAYLOAD" & ASCII.LF &
        "x-amz-date:" & Amz_Date & ASCII.LF &
        (if Has_Meta and then Meta_Before_Backup_Crc32 then Meta_Header & ":" & Metadata_Value & ASCII.LF else "") &
        (if Has_Backup_Crc32 then "x-amz-meta-backup-crc32:" & Backup_Crc32 & ASCII.LF else "") &
        (if Has_Meta and then not Meta_Before_Backup_Crc32 then Meta_Header & ":" & Metadata_Value & ASCII.LF else "") &
        (if Has_Lock_Hold then "x-amz-object-lock-legal-hold:" & Object_Lock_Legal_Hold & ASCII.LF else "") &
        (if Has_Lock_Mode then "x-amz-object-lock-mode:" & Object_Lock_Mode & ASCII.LF else "") &
        (if Has_Lock_Retain then "x-amz-object-lock-retain-until-date:" & Object_Lock_Retain_Until & ASCII.LF else "") &
        (if Token'Length = 0 then "" else "x-amz-security-token:" & Token & ASCII.LF) &
        (if Has_SSE then "x-amz-server-side-encryption:" & SSE & ASCII.LF else "") &
        (if Has_KMS then "x-amz-server-side-encryption-aws-kms-key-id:" & KMS_Key_Id & ASCII.LF else "") &
        (if Has_Storage then "x-amz-storage-class:" & Storage_Class & ASCII.LF else "") &
        (if Has_Tagging then "x-amz-tagging:" & Tagging & ASCII.LF else "");
      Canonical_Request : constant String :=
        Method_Text (Method) & ASCII.LF & URL_Path (URL) & ASCII.LF &
        Canonical_Query (URL_Query (URL)) & ASCII.LF &
        Canonical_Headers & ASCII.LF & Signed & ASCII.LF & "UNSIGNED-PAYLOAD";
      String_To_Sign : constant String :=
        "AWS4-HMAC-SHA256" & ASCII.LF & Amz_Date & ASCII.LF & Scope & ASCII.LF &
        Http_Client.Crypto.Digest_SHA256_Hex (Canonical_Request);
      K_Date    : constant Byte_Array := HMAC_SHA256
        (To_Bytes ("AWS4" & To_String (Options.S3_Secret_Key)), Date_Stamp);
      K_Region  : constant Byte_Array := HMAC_SHA256 (K_Date, Region);
      K_Service : constant Byte_Array := HMAC_SHA256 (K_Region, "s3");
      K_Signing : constant Byte_Array := HMAC_SHA256 (K_Service, "aws4_request");
      Signature : constant String := Hex (HMAC_SHA256 (K_Signing, String_To_Sign));
   begin
      return "AWS4-HMAC-SHA256 Credential=" & To_String (Options.S3_Access_Key) &
        "/" & Scope & ", SignedHeaders=" & Signed & ", Signature=" & Signature;
   end S3_Authorization;

   function S3_Presign_Method_Text (Method : S3_Presign_Method) return String is
   begin
      case Method is
         when S3_Presign_GET =>
            return "GET";
         when S3_Presign_PUT =>
            return "PUT";
         when S3_Presign_DELETE =>
            return "DELETE";
      end case;
   end S3_Presign_Method_Text;

   function S3_Presign_Query
     (URL             : String;
      Options         : Remote_Options;
      Method          : S3_Presign_Method;
      Amz_Date        : String;
      Date_Stamp      : String;
      Expires_Seconds : Natural) return String
   is
      Host       : constant String := URL_Host (URL);
      Region     : constant String := S3_Region (Options);
      Scope      : constant String := Date_Stamp & "/" & Region & "/s3/aws4_request";
      Token      : constant String := To_String (Options.S3_Session_Token);
      Credential : constant String := To_String (Options.S3_Access_Key) & "/" & Scope;
      Base_Query : constant String :=
        "X-Amz-Algorithm=AWS4-HMAC-SHA256" &
        "&X-Amz-Credential=" & Percent_Encode_Query_Component (Credential) &
        "&X-Amz-Date=" & Amz_Date &
        "&X-Amz-Expires=" & Decimal_Natural (Expires_Seconds) &
        (if Token'Length = 0 then "" else
         "&X-Amz-Security-Token=" & Percent_Encode_Query_Component (Token)) &
        "&X-Amz-SignedHeaders=host";
      Existing_Query : constant String := URL_Query (URL);
      Canonical_Q    : constant String :=
        (if Existing_Query'Length = 0 then Base_Query else Existing_Query & "&" & Base_Query);
      Canonical_Headers : constant String := "host:" & Host & ASCII.LF;
      Canonical_Request : constant String :=
        S3_Presign_Method_Text (Method) & ASCII.LF & URL_Path (URL) & ASCII.LF &
        Canonical_Q & ASCII.LF & Canonical_Headers & ASCII.LF & "host" & ASCII.LF &
        "UNSIGNED-PAYLOAD";
      String_To_Sign : constant String :=
        "AWS4-HMAC-SHA256" & ASCII.LF & Amz_Date & ASCII.LF & Scope & ASCII.LF &
        Http_Client.Crypto.Digest_SHA256_Hex (Canonical_Request);
      K_Date    : constant Byte_Array := HMAC_SHA256
        (To_Bytes ("AWS4" & To_String (Options.S3_Secret_Key)), Date_Stamp);
      K_Region  : constant Byte_Array := HMAC_SHA256 (K_Date, Region);
      K_Service : constant Byte_Array := HMAC_SHA256 (K_Region, "s3");
      K_Signing : constant Byte_Array := HMAC_SHA256 (K_Service, "aws4_request");
      Signature : constant String := Hex (HMAC_SHA256 (K_Signing, String_To_Sign));
   begin
      return Base_Query & "&X-Amz-Signature=" & Signature;
   end S3_Presign_Query;

   function Add_S3_Auth_Headers
     (Method     : Http_Client.Types.Method_Name;
      URL        : String;
      Options    : Remote_Options;
      Headers    : in out Http_Client.Headers.Header_List;
      Diagnostic : out Unbounded_String;
      Include_Put_Headers : Boolean := False;
      Backup_Crc32 : String := "";
      Checksum_CRC32 : String := "";
      Request_Checksum_Mode : Boolean := False;
      Checksum_Algorithm : String := "") return Remote_Status
   is
      HTTP_Status : Http_Client.Errors.Result_Status;
      Amz_Date    : String (1 .. 16);
      Date_Stamp  : String (1 .. 8);
      Auth        : Unbounded_String;
      Resolved    : constant Remote_Options := Resolved_S3_Options (Options, Diagnostic);
      SSE         : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Server_Side_Encryption) else "");
      KMS_Key_Id  : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_SSE_KMS_Key_Id) else "");
      ACL         : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_ACL) else "");
      Checksum_Algorithm_Header : constant String := Checksum_Algorithm;
      Checksum_CRC32_Header : constant String := Checksum_CRC32;
      Checksum_Mode_Header : constant String :=
        (if Request_Checksum_Mode then "ENABLED" else "");
      Storage_Class : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Storage_Class) else "");
      Tagging     : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Tagging) else "");
      Metadata_Name : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Metadata_Name) else "");
      Metadata_Value : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Metadata_Value) else "");
      Object_Lock_Mode : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Object_Lock_Mode) else "");
      Object_Lock_Retain_Until : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Object_Lock_Retain_Until) else "");
      Object_Lock_Legal_Hold : constant String :=
        (if Include_Put_Headers then To_String (Resolved.S3_Object_Lock_Legal_Hold) else "");
      Backup_Crc32_Header : constant String :=
        (if Include_Put_Headers and then Metadata_Name /= "backup-crc32"
         then Backup_Crc32 else "");
   begin
      if Length (Resolved.S3_Access_Key) = 0 or else Length (Resolved.S3_Secret_Key) = 0 then
         Diagnostic := To_Unbounded_String ("S3 credentials are required for request signing");
         return Remote_Authentication_Failed;
      end if;
      S3_Timestamps (Amz_Date, Date_Stamp);
      Auth := To_Unbounded_String
        (S3_Authorization
           (Method, URL, Resolved, Amz_Date, Date_Stamp, SSE, KMS_Key_Id,
            ACL, Checksum_Algorithm_Header, Checksum_CRC32_Header,
            Checksum_Mode_Header, Storage_Class, Tagging, Metadata_Name,
            Metadata_Value, Backup_Crc32_Header,
            Object_Lock_Mode, Object_Lock_Retain_Until,
            Object_Lock_Legal_Hold));
      HTTP_Status := Http_Client.Headers.Set (Headers, "Host", URL_Host (URL));
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-content-sha256", "UNSIGNED-PAYLOAD");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set (Headers, "x-amz-date", Amz_Date);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then ACL'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set (Headers, "x-amz-acl", ACL);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Checksum_Algorithm_Header'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-checksum-algorithm", Checksum_Algorithm_Header);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Checksum_CRC32_Header'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-checksum-crc32", Checksum_CRC32_Header);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Checksum_Mode_Header'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-checksum-mode", Checksum_Mode_Header);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Storage_Class'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-storage-class", Storage_Class);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Tagging'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set (Headers, "x-amz-tagging", Tagging);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Backup_Crc32_Header'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-meta-backup-crc32", Backup_Crc32_Header);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Metadata_Name'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, S3_Metadata_Header (Metadata_Name), Metadata_Value);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Object_Lock_Mode'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-object-lock-mode", Object_Lock_Mode);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok
        and then Object_Lock_Retain_Until'Length > 0
      then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-object-lock-retain-until-date",
            Object_Lock_Retain_Until);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok
        and then Object_Lock_Legal_Hold'Length > 0
      then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-object-lock-legal-hold", Object_Lock_Legal_Hold);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok
        and then Include_Put_Headers
        and then Length (Resolved.S3_Cache_Control) > 0
      then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Cache-Control", To_String (Resolved.S3_Cache_Control));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok
        and then Include_Put_Headers
        and then Length (Resolved.S3_Content_Disposition) > 0
      then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Disposition",
            To_String (Resolved.S3_Content_Disposition));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok
        and then Include_Put_Headers
        and then Length (Resolved.S3_Content_Encoding) > 0
      then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Encoding", To_String (Resolved.S3_Content_Encoding));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then SSE'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-server-side-encryption", SSE);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then KMS_Key_Id'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-server-side-encryption-aws-kms-key-id", KMS_Key_Id);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok
        and then Ada.Strings.Unbounded.Length (Resolved.S3_Session_Token) > 0
      then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "x-amz-security-token", To_String (Resolved.S3_Session_Token));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Authorization", To_String (Auth));
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("invalid S3 authentication header");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Add_S3_Auth_Headers;

   type HTTP_Index_Validator is record
      Found    : Boolean := False;
      Has_ETag : Boolean := False;
      ETag     : Unbounded_String;
   end record;

   type HTTP_Index_Publish_Result is
     (HTTP_Index_Published,
      HTTP_Index_Conflict,
      HTTP_Index_Failed);

   HTTP_Index_Conflict_Retry_Limit : constant Natural := 3;

   function HTTP_Status_OK
     (Code : Natural;
      For_Upload : Boolean := False) return Boolean
   is
   begin
      return Backup.Remote_Syntax.HTTP_Status_OK (Code, For_Upload);
   end HTTP_Status_OK;

   function Is_HTTP_Transport (Kind : Transport_Kind) return Boolean is
   begin
      return Backup.Remote_Syntax.Is_HTTP_Transport (Kind);
   end Is_HTTP_Transport;

   function Is_Unsupported_Transfer_Transport
     (Kind : Transport_Kind) return Boolean
   is
   begin
      return Backup.Remote_Syntax.Is_Unsupported_Transfer_Transport (Kind);
   end Is_Unsupported_Transfer_Transport;

   function Resume_Upload_Enabled (Mode : Upload_Mode) return Boolean is
   begin
      return Backup.Remote_Syntax.Resume_Upload_Enabled (Mode);
   end Resume_Upload_Enabled;

   function Configure_HTTP_Client
     (URL        : String;
      Options    : Remote_Options;
      Client     : in out Http_Client.Clients.Client;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Config      : Http_Client.Clients.Client_Configuration :=
        Http_Client.Clients.Strict_Client_Configuration;
      URI         : Http_Client.URI.URI_Reference;
      HTTP_Status : Http_Client.Errors.Result_Status;
   begin
      Client := Http_Client.Clients.Create;
      if Length (Options.TLS_CA_File) = 0
        and then Length (Options.TLS_CA_Directory) = 0
        and then Length (Options.TLS_Client_Cert_File) = 0
        and then Length (Options.TLS_Client_Key_File) = 0
      then
         return Remote_Ok;
      end if;

      if Length (Options.TLS_CA_File) > 0 then
         Config.Execution.TLS.CA_File := Options.TLS_CA_File;
      end if;

      if Length (Options.TLS_CA_Directory) > 0 then
         Config.Execution.TLS.CA_Directory := Options.TLS_CA_Directory;
      end if;

      if Length (Options.TLS_Client_Cert_File) > 0
        or else Length (Options.TLS_Client_Key_File) > 0
      then
         HTTP_Status := Http_Client.URI.Parse (URL, URI);
         if HTTP_Status /= Http_Client.Errors.Ok then
            Diagnostic := To_Unbounded_String
              ("invalid HTTPS remote URL for client certificate: " & URL);
            return HTTP_Error_Status (HTTP_Status);
         end if;

         Config.Execution.TLS.Client_Certificate :=
           Http_Client.TLS.Client_Certificates.For_Origin
             (Http_Client.TLS.Client_Certificates.From_PEM_Files
                (Certificate_File => To_String (Options.TLS_Client_Cert_File),
                 Private_Key_File => To_String (Options.TLS_Client_Key_File),
                 Passphrase       => To_String (Options.TLS_Client_Key_Passphrase),
                 Has_Passphrase   => Options.TLS_Client_Has_Passphrase,
                 Allow_Any_Origin => False),
              URI);
      end if;

      HTTP_Status := Http_Client.Transports.TLS.Validate_Options
        (Config.Execution.TLS);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Configure (Client, Config);
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("invalid HTTPS client certificate configuration for remote");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Configure_HTTP_Client;

   function Add_HTTP_Auth_Headers
     (Options    : Remote_Options;
      Headers    : in out Http_Client.Headers.Header_List;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      HTTP_Status : Http_Client.Errors.Result_Status := Http_Client.Errors.Ok;
   begin
      case Options.HTTP_Auth is
         when HTTP_Auth_None =>
            return Remote_Ok;
         when HTTP_Auth_Bearer =>
            declare
               Token : constant String := To_String (Options.HTTP_Bearer_Token);
            begin
               if not Http_Client.Auth.Bearer.Is_Valid_Token (Token) then
                  Diagnostic := To_Unbounded_String
                    ("invalid HTTP bearer token in remote options");
                  return Remote_Authentication_Failed;
               end if;
               HTTP_Status := Http_Client.Headers.Set
                 (Headers, "Authorization",
                  Http_Client.Auth.Bearer.Authorization_Value (Token));
            end;
         when HTTP_Auth_Basic =>
            declare
               Username : constant String := To_String (Options.HTTP_Basic_User);
               Password : constant String := To_String (Options.HTTP_Basic_Pass);
            begin
               if not Http_Client.Auth.Is_Valid_Basic_Credentials
                 (Username, Password)
               then
                  Diagnostic := To_Unbounded_String
                    ("invalid HTTP basic credentials in remote options");
                  return Remote_Authentication_Failed;
               end if;
               HTTP_Status := Http_Client.Headers.Set
                 (Headers, "Authorization",
                  Http_Client.Auth.Basic_Authorization_Value
                    (Username, Password));
            end;
         when HTTP_Auth_Custom_Header =>
            HTTP_Status := Http_Client.Headers.Set
              (Headers, To_String (Options.HTTP_Header_Name),
               To_String (Options.HTTP_Header_Value));
      end case;

      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("invalid HTTP authentication header in remote options");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Add_HTTP_Auth_Headers;

   type File_Body_Producer is limited new Http_Client.Request_Bodies.Body_Producer
   with record
      File   : Ada.Streams.Stream_IO.File_Type;
      Opened : Boolean := False;
   end record;

   overriding function Read_Some
     (Item   : in out File_Body_Producer;
      Buffer : out String;
      Count  : out Natural) return Http_Client.Errors.Result_Status;

   overriding function Reset
     (Item : in out File_Body_Producer) return Http_Client.Errors.Result_Status;

   procedure Open_File_Response_Text
     (Item : in out File_Body_Producer;
      Path : String) is
   begin
      if Item.Opened then
         Ada.Streams.Stream_IO.Close (Item.File);
         Item.Opened := False;
      end if;
      Ada.Streams.Stream_IO.Open
        (Item.File, Ada.Streams.Stream_IO.In_File, Path);
      Item.Opened := True;
   end Open_File_Response_Text;

   procedure Close_File_Response_Text (Item : in out File_Body_Producer) is
   begin
      if Item.Opened then
         Ada.Streams.Stream_IO.Close (Item.File);
         Item.Opened := False;
      end if;
   exception
      when others =>
         Item.Opened := False;
   end Close_File_Response_Text;

   overriding function Read_Some
     (Item   : in out File_Body_Producer;
      Buffer : out String;
      Count  : out Natural) return Http_Client.Errors.Result_Status
   is
      use Ada.Streams;
      Raw  : Stream_Element_Array
        (1 .. Stream_Element_Offset (Buffer'Length));
      Last : Stream_Element_Offset;
   begin
      Count := 0;
      if not Item.Opened then
         return Http_Client.Errors.Body_Producer_Failed;
      end if;

      Ada.Streams.Stream_IO.Read (Item.File, Raw, Last);
      if Last < Raw'First then
         return Http_Client.Errors.Ok;
      end if;

      Count := Natural (Last - Raw'First + 1);
      for Offset in 0 .. Count - 1 loop
         Buffer (Buffer'First + Offset) :=
           Character'Val (Integer (Raw (Raw'First + Stream_Element_Offset (Offset))));
      end loop;
      return Http_Client.Errors.Ok;
   exception
      when others =>
         Count := 0;
         return Http_Client.Errors.Body_Producer_Failed;
   end Read_Some;

   overriding function Reset
     (Item : in out File_Body_Producer) return Http_Client.Errors.Result_Status
   is
      pragma Unreferenced (Item);
   begin
      return Http_Client.Errors.Body_Not_Replayable;
   end Reset;

   function Prepare_HTTP_Request
     (Method     : Http_Client.Types.Method_Name;
      URL        : String;
      Options    : Remote_Options;
      Request    : out Http_Client.Requests.Request;
      Diagnostic : out Unbounded_String;
      Sign_S3    : Boolean := False;
      Include_S3_Put_Headers : Boolean := False) return Remote_Status
   is
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Auth_Status : Remote_Status;
   begin
      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("invalid HTTP remote URL: " & URL);
         return HTTP_Error_Status (HTTP_Status);
      end if;

      if Sign_S3 then
         Auth_Status := Add_S3_Auth_Headers
           (Method, URL, Options, Headers, Diagnostic, Include_S3_Put_Headers);
      else
         Auth_Status := Add_HTTP_Auth_Headers (Options, Headers, Diagnostic);
      end if;
      if Auth_Status /= Remote_Ok then
         return Auth_Status;
      end if;

      HTTP_Status := Http_Client.Requests.Create
        (Method  => Method,
         URI     => URI,
         Item    => Request,
         Headers => Headers);
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("could not create HTTP request: " & URL);
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Prepare_HTTP_Request;

   function HTTP_Download_To_File
     (URL        : String;
      Path       : String;
      Options    : Remote_Options;
      Result     : out Http_Client.Clients.Download_Result;
      Diagnostic : out Unbounded_String;
      Sign_S3    : Boolean := False) return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      Status      : Remote_Status;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Download_Options : Http_Client.Clients.Download_Options :=
        Http_Client.Clients.Default_Download_Options;
   begin
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Prepare_HTTP_Request
        (Http_Client.Types.GET, URL, Options, Request, Diagnostic, Sign_S3);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Download_Options.Create_Parent_Dirs := True;
      HTTP_Status := Http_Client.Clients.Execute_To_File
        (Client, Request, Path, Result, Download_Options);
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("HTTP download failed: " &
            Http_Client.Errors.Result_Status'Image (HTTP_Status));
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end HTTP_Download_To_File;

   function HTTP_Get
     (URL        : String;
      Options    : Remote_Options;
      Result     : out Http_Client.Clients.Client_Result;
      Diagnostic : out Unbounded_String;
      Sign_S3    : Boolean := False) return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      Status      : Remote_Status;
      HTTP_Status : Http_Client.Errors.Result_Status;
   begin
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Prepare_HTTP_Request
        (Http_Client.Types.GET, URL, Options, Request, Diagnostic, Sign_S3);
      if Status /= Remote_Ok then
         return Status;
      end if;
      HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
      if HTTP_Status /= Http_Client.Errors.Ok then
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end HTTP_Get;


   function Google_Drive_Token_URI (Options : Remote_Options) return String is
      Value : constant String := To_String (Options.Google_Drive_Token_URI);
   begin
      if Value'Length = 0 then
         return "https://oauth2.googleapis.com/token";
      else
         return Value;
      end if;
   end Google_Drive_Token_URI;

   function Resolved_Google_Drive_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Options
   is
      Result : Remote_Options := Options;
      Token_Text : Unbounded_String;
      Status     : Remote_Status;
   begin
      if Length (Result.Google_Drive_Access_Token) > 0 then
         return Result;
      elsif Length (Result.Google_Drive_Access_Token_File) > 0 then
         declare
            Token : constant String := Ada.Strings.Fixed.Trim
              (Read_Text_File (To_String (Result.Google_Drive_Access_Token_File)),
               Ada.Strings.Both);
         begin
            if Token'Length = 0 then
               Diagnostic := To_Unbounded_String
                 ("Google Drive access token file is empty or unreadable");
            else
               Result.Google_Drive_Access_Token := To_Unbounded_String (Token);
            end if;
            return Result;
         end;
      elsif Length (Result.Google_Drive_Refresh_Token) > 0 then
         if Length (Result.Google_Drive_Client_Id) = 0
           or else Length (Result.Google_Drive_Client_Secret) = 0
         then
            Diagnostic := To_Unbounded_String
              ("Google Drive refresh token requires google_drive_client_id and google_drive_client_secret");
            return Result;
         end if;

         Status := HTTP_Post_Form_Text
           (Google_Drive_Token_URI (Result),
            "grant_type=refresh_token" &
            "&client_id=" & Percent_Encode_Query_Component
              (To_String (Result.Google_Drive_Client_Id)) &
            "&client_secret=" & Percent_Encode_Query_Component
              (To_String (Result.Google_Drive_Client_Secret)) &
            "&refresh_token=" & Percent_Encode_Query_Component
              (To_String (Result.Google_Drive_Refresh_Token)),
            Result, Token_Text, Diagnostic);
         if Status = Remote_Ok then
            declare
               Token : constant String := JSON_Field
                 (To_String (Token_Text), "access_token");
            begin
               if Token'Length = 0 then
                  Diagnostic := To_Unbounded_String
                    ("Google Drive token refresh response did not contain access_token");
               else
                  Result.Google_Drive_Access_Token := To_Unbounded_String (Token);
               end if;
            end;
         end if;
      end if;
      return Result;
   end Resolved_Google_Drive_Options;

   function Google_Drive_HTTP_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Options
   is
      Result : Remote_Options := Resolved_Google_Drive_Options (Options, Diagnostic);
   begin
      Result.HTTP_Auth := HTTP_Auth_Bearer;
      Result.HTTP_Bearer_Token := Result.Google_Drive_Access_Token;
      return Result;
   end Google_Drive_HTTP_Options;

   function Google_Drive_Query_Escape (Text : String) return String is
      Result : Unbounded_String;
   begin
      for Ch of Text loop
         if Ch = Character'Val (39) then
            Append (Result, Character'Val (16#5C#));
            Append (Result, Ch);
         elsif Ch = Character'Val (16#5C#) then
            Append (Result, Character'Val (16#5C#));
            Append (Result, Character'Val (16#5C#));
         else
            Append (Result, Ch);
         end if;
      end loop;
      return To_String (Result);
   end Google_Drive_Query_Escape;

   function Google_Drive_Supports_All_Drives
     (Options : Remote_Options) return Boolean
   is
   begin
      return Options.Google_Drive_Supports_All_Drives
        or else Length (Options.Google_Drive_Drive_Id) > 0;
   end Google_Drive_Supports_All_Drives;

   function Google_Drive_Supports_Query
     (Options : Remote_Options;
      Prefix  : String := "&") return String
   is
   begin
      if Google_Drive_Supports_All_Drives (Options) then
         return Prefix & "supportsAllDrives=true";
      else
         return "";
      end if;
   end Google_Drive_Supports_Query;

   function JSON_Field_Count (Text : String; Name : String) return Natural is
      Pattern : constant String := '"' & Name & '"';
      Count   : Natural := 0;
      Start   : Natural := Text'First;
      Pos     : Natural;
   begin
      while Start <= Text'Last loop
         Pos := Ada.Strings.Fixed.Index (Text (Start .. Text'Last), Pattern);
         exit when Pos = 0;
         Count := Count + 1;
         Start := Pos + Pattern'Length;
      end loop;
      return Count;
   exception
      when others =>
         return Count;
   end JSON_Field_Count;

   function Google_Drive_Retryable_Response
     (Code : Natural;
      Response_Body : String) return Boolean
   is
   begin
      return Code = 408
        or else Code = 409
        or else Code = 429
        or else Code >= 500
        or else
          (Code = 403
           and then
             (Ada.Strings.Fixed.Index (Response_Body, "rateLimitExceeded") > 0
              or else Ada.Strings.Fixed.Index (Response_Body, "userRateLimitExceeded") > 0
              or else Ada.Strings.Fixed.Index (Response_Body, "quotaExceeded") > 0));
   end Google_Drive_Retryable_Response;

   function Google_Drive_Metadata_JSON
     (Location    : Remote_Location;
      Object_Name : String) return String
   is
   begin
      return "{""name"":""" &
        JSON_Escape (Google_Drive_Name (Location, Object_Name)) &
        """,""parents"": [""" & JSON_Escape (Google_Drive_Folder_Id (Location)) &
        """]}";
   end Google_Drive_Metadata_JSON;

   function Google_Drive_Query_URL
     (Location    : Remote_Location;
      Options     : Remote_Options;
      Object_Name : String;
      Page_Token  : String := "") return String
   is
      Query : constant String :=
        "'" & Google_Drive_Query_Escape (Google_Drive_Folder_Id (Location)) &
        "' in parents and name = '" &
        Google_Drive_Query_Escape (Google_Drive_Name (Location, Object_Name)) &
        "' and trashed = false";
      Shared_Drive_Query : constant String :=
        (if Length (Options.Google_Drive_Drive_Id) > 0 then
            "&corpora=drive&driveId=" &
            Percent_Encode_Query_Component (To_String (Options.Google_Drive_Drive_Id)) &
            "&includeItemsFromAllDrives=true&supportsAllDrives=true"
         elsif Google_Drive_Supports_All_Drives (Options) then
            "&includeItemsFromAllDrives=true&supportsAllDrives=true"
         else
            "&spaces=drive");
   begin
      return Google_Drive_API_Base (Options) & "/files?q=" &
        Percent_Encode_Query_Component (Query) & Shared_Drive_Query &
        "&pageSize=100&fields=nextPageToken,files(id,name,size,modifiedTime,md5Checksum)" &
        (if Page_Token'Length = 0 then "" else
           "&pageToken=" & Percent_Encode_Query_Component (Page_Token));
   end Google_Drive_Query_URL;

   function Google_Drive_File_Id
     (Location    : Remote_Location;
      Options     : Remote_Options;
      Object_Name : String;
      Diagnostic  : out Unbounded_String) return String
   is
      Result      : Http_Client.Clients.Client_Result;
      Status      : Remote_Status;
      Code        : Natural;
      Page_Token  : Unbounded_String;
      Found_Id    : Unbounded_String;
      Found_Count : Natural := 0;
      Page_Count  : Natural := 0;
   begin
      Diagnostic := Null_Unbounded_String;
      loop
         Page_Count := Page_Count + 1;
         if Page_Count > 10_000 then
            Diagnostic := To_Unbounded_String
              ("Google Drive file lookup pagination did not terminate");
            return "";
         end if;

         for Attempt in Natural range 0 .. Options.Retry_Count loop
            Status := HTTP_Get
              (Google_Drive_Query_URL
                 (Location, Options, Object_Name, To_String (Page_Token)),
               Google_Drive_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
            exit when Status = Remote_Ok;
            if not Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               return "";
            end if;
         end loop;
         Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
         declare
            Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
         begin
            if Code = 401 or else
              (Code = 403 and then not Google_Drive_Retryable_Response (Code, Response_Body))
            then
               Diagnostic := To_Unbounded_String
                 ("Google Drive authentication failed with status" & Natural'Image (Code));
               return "";
            elsif Code /= 200 then
               if Google_Drive_Retryable_Response (Code, Response_Body)
                 and then Options.Retry_Count > 0
               then
                  declare
                     Retried : Boolean := False;
                  begin
                     for Attempt in Natural range 1 .. Options.Retry_Count loop
                        Status := HTTP_Get
                          (Google_Drive_Query_URL
                             (Location, Options, Object_Name, To_String (Page_Token)),
                           Google_Drive_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
                        exit when Status = Remote_Ok;
                        Retried := True;
                     end loop;
                     pragma Unreferenced (Retried);
                     Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
                     if Code /= 200 then
                        Diagnostic := To_Unbounded_String
                          ("Google Drive file lookup returned status" & Natural'Image (Code));
                        return "";
                     end if;
                  end;
               else
                  Diagnostic := To_Unbounded_String
                    ("Google Drive file lookup returned status" & Natural'Image (Code));
                  return "";
               end if;
            end if;
         end;

         declare
            Text       : constant String := Http_Client.Clients.Response_Text (Result);
            Page_Count_Ids : constant Natural := JSON_Field_Count (Text, "id");
            Page_Id    : constant String := JSON_Field (Text, "id");
            Next_Token : constant String := JSON_Field (Text, "nextPageToken");
         begin
            if Page_Count_Ids > 0 then
               if Length (Found_Id) = 0 and then Page_Id'Length > 0 then
                  Found_Id := To_Unbounded_String (Page_Id);
               end if;
               Found_Count := Found_Count + Page_Count_Ids;
               if Found_Count > 1 then
                  Diagnostic := To_Unbounded_String
                    ("Google Drive remote has multiple files named " &
                     Google_Drive_Name (Location, Object_Name) &
                     " in the target folder");
                  return "";
               end if;
            end if;
            exit when Next_Token'Length = 0;
            Page_Token := To_Unbounded_String (Next_Token);
         end;
      end loop;
      return To_String (Found_Id);
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("Google Drive file lookup failed");
         return "";
   end Google_Drive_File_Id;

   function Google_Drive_Multipart_Response_Text
     (Metadata_JSON : String;
      Payload       : String;
      Content_Type  : String) return String
   is
      Boundary : constant String := "backup-drive-boundary-v1";
      CRLF_Text : constant String := Ada.Characters.Latin_1.CR & Ada.Characters.Latin_1.LF;
   begin
      return "--" & Boundary & CRLF_Text &
        "Content-Type: application/json; charset=UTF-8" & CRLF_Text & CRLF_Text &
        Metadata_JSON & CRLF_Text &
        "--" & Boundary & CRLF_Text &
        "Content-Type: " & Content_Type & CRLF_Text & CRLF_Text &
        Payload & CRLF_Text &
        "--" & Boundary & "--" & CRLF_Text;
   end Google_Drive_Multipart_Response_Text;

   function Execute_Google_Drive_Multipart
     (Method      : Http_Client.Types.Method_Name;
      URL         : String;
      Multipart_Response_Text : String;
      Options     : Remote_Options;
      Result      : out Http_Client.Clients.Client_Result;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Status      : Remote_Status;
      Drive_Options : constant Remote_Options := Google_Drive_HTTP_Options (Options, Diagnostic);
   begin
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Type",
            "multipart/related; boundary=backup-drive-boundary-v1");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         Status := Add_HTTP_Auth_Headers (Drive_Options, Headers, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method => Method, URI => URI, Item => Request, Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String (Multipart_Response_Text));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("Google Drive multipart request failed");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Execute_Google_Drive_Multipart;

   function Upload_Google_Drive_Object
     (Location    : Remote_Location;
      Object_Name : String;
      Payload     : String;
      Content_Type : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Lookup_Diagnostic : Unbounded_String;
      Id     : constant String := Google_Drive_File_Id
        (Location, Options, Object_Name, Lookup_Diagnostic);
      URL    : constant String :=
        (if Id'Length = 0 then
            Google_Drive_Upload_Base (Options) &
            "/files?uploadType=multipart&fields=id" &
            Google_Drive_Supports_Query (Options)
         else
            Google_Drive_Upload_Base (Options) & "/files/" &
            Percent_Encode_Query_Component (Id) &
            "?uploadType=multipart&fields=id" &
            Google_Drive_Supports_Query (Options));
      Method : constant Http_Client.Types.Method_Name :=
        (if Id'Length = 0 then Http_Client.Types.POST else Http_Client.Types.PATCH);
      Multipart_Response_Text : constant String := Google_Drive_Multipart_Response_Text
        (Google_Drive_Metadata_JSON (Location, Object_Name), Payload, Content_Type);
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural;
   begin
      if Id'Length = 0 and then Length (Lookup_Diagnostic) > 0 then
         Diagnostic := Lookup_Diagnostic;
         return Remote_Read_Failed;
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Execute_Google_Drive_Multipart
           (Method, URL, Multipart_Response_Text, Options, Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
            begin
               if Code = 401 or else
                 (Code = 403 and then not Google_Drive_Retryable_Response (Code, Response_Body))
               then
                  Diagnostic := To_Unbounded_String
                    ("Google Drive upload authentication failed with status" & Natural'Image (Code));
                  return Remote_Authentication_Failed;
               elsif HTTP_Status_OK (Code, For_Upload => True) then
                  return Remote_Ok;
               elsif Google_Drive_Retryable_Response (Code, Response_Body)
                 and then Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    ("Google Drive upload returned status" & Natural'Image (Code));
                  return Remote_Write_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("Google Drive upload retry loop did not run");
      return Remote_Write_Failed;
   end Upload_Google_Drive_Object;

   function Initiate_Google_Drive_Resumable_Upload
     (Location     : Remote_Location;
      Object_Name  : String;
      Content_Type : String;
      Size         : Interfaces.Unsigned_64;
      Options      : Remote_Options;
      Session_URL  : out Unbounded_String;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Lookup_Diagnostic : Unbounded_String;
      Id     : constant String := Google_Drive_File_Id
        (Location, Options, Object_Name, Lookup_Diagnostic);
      URL    : constant String :=
        (if Id'Length = 0 then
            Google_Drive_Upload_Base (Options) &
            "/files?uploadType=resumable&fields=id" &
            Google_Drive_Supports_Query (Options)
         else
            Google_Drive_Upload_Base (Options) & "/files/" &
            Percent_Encode_Query_Component (Id) &
            "?uploadType=resumable&fields=id" &
            Google_Drive_Supports_Query (Options));
      Method : constant Http_Client.Types.Method_Name :=
        (if Id'Length = 0 then Http_Client.Types.POST else Http_Client.Types.PATCH);
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      Result      : Http_Client.Clients.Client_Result;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Status      : Remote_Status;
      Drive_Options : constant Remote_Options := Google_Drive_HTTP_Options (Options, Diagnostic);
      Code        : Natural := 0;
   begin
      Session_URL := Null_Unbounded_String;
      if Id'Length = 0 and then Length (Lookup_Diagnostic) > 0 then
         Diagnostic := Lookup_Diagnostic;
         return Remote_Read_Failed;
      end if;

      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Type", "application/json; charset=UTF-8");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "X-Upload-Content-Type", Content_Type);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "X-Upload-Content-Length", Decimal (Size));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         Status := Add_HTTP_Auth_Headers (Drive_Options, Headers, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method => Method, URI => URI, Item => Request, Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String
              (Google_Drive_Metadata_JSON (Location, Object_Name)));
      end if;

      for Attempt in Natural range 0 .. Options.Retry_Count loop
         if HTTP_Status = Http_Client.Errors.Ok then
            HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
         end if;
         if HTTP_Status /= Http_Client.Errors.Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               Diagnostic := To_Unbounded_String
                 ("Google Drive resumable upload initiation failed");
               return HTTP_Error_Status (HTTP_Status);
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
            begin
               if (Code = 200 or else Code = 201)
                 and then Http_Client.Responses.Has_Header (Result.Response, "Location")
               then
                  Session_URL := To_Unbounded_String
                    (Http_Client.Responses.Header (Result.Response, "Location"));
                  return Remote_Ok;
               elsif Code = 401 or else
                 (Code = 403 and then not Google_Drive_Retryable_Response (Code, Response_Body))
               then
                  Diagnostic := To_Unbounded_String
                    ("Google Drive resumable upload authentication failed with status" &
                     Natural'Image (Code));
                  return Remote_Authentication_Failed;
               elsif Google_Drive_Retryable_Response (Code, Response_Body)
                 and then Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    ("Google Drive resumable upload initiation returned status" &
                     Natural'Image (Code));
                  return Remote_Write_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String
        ("Google Drive resumable upload initiation retry loop did not run");
      return Remote_Write_Failed;
   end Initiate_Google_Drive_Resumable_Upload;

   function Upload_Google_Drive_File
     (Location     : Remote_Location;
      Object_Name  : String;
      Path         : String;
      Size         : Interfaces.Unsigned_64;
      Crc32        : Interfaces.Unsigned_32;
      Content_Type : String;
      Options      : Remote_Options;
      Report       : in out Transfer_Report;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Session_URL : Unbounded_String;
      Result      : Http_Client.Clients.Client_Result;
      Status      : Remote_Status;
      Code        : Natural := 0;
   begin
      pragma Unreferenced (Crc32);
      Status := Initiate_Google_Drive_Resumable_Upload
        (Location, Object_Name, Content_Type, Size, Options, Session_URL,
         Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Stream_HTTP_Put
           (To_String (Session_URL), Path, Size, "", 0,
            Google_Drive_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               Report.Retried := Report.Retried + 1;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
            begin
               if Code = 200 or else Code = 201 then
                  return Remote_Ok;
               elsif Code = 401 or else
                 (Code = 403 and then not Google_Drive_Retryable_Response (Code, Response_Body))
               then
                  Diagnostic := To_Unbounded_String
                    ("Google Drive resumable upload authentication failed with status" &
                     Natural'Image (Code));
                  return Remote_Authentication_Failed;
               elsif Google_Drive_Retryable_Response (Code, Response_Body)
                 and then Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  Report.Retried := Report.Retried + 1;
               else
                  Diagnostic := To_Unbounded_String
                    ("Google Drive resumable upload returned status" &
                     Natural'Image (Code));
                  return Remote_Write_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String
        ("Google Drive resumable upload retry loop did not run");
      return Remote_Write_Failed;
   end Upload_Google_Drive_File;

   function Download_Google_Drive_Object
     (Location    : Remote_Location;
      Object_Name : String;
      Local_Path  : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Id : constant String := Google_Drive_File_Id
        (Location, Options, Object_Name, Diagnostic);
      Download : Http_Client.Clients.Download_Result;
      Status   : Remote_Status;
      Code     : Natural;
   begin
      if Id'Length = 0 then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String ("Google Drive object was not found: " & Object_Name);
            return Remote_Not_Found;
         end if;
         return Remote_Read_Failed;
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Download_To_File
           (Google_Drive_API_Base (Options) & "/files/" &
            Percent_Encode_Query_Component (Id) & "?alt=media" &
            Google_Drive_Supports_Query (Options),
            Local_Path, Google_Drive_HTTP_Options (Options, Diagnostic), Download, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Download.HTTP_Status_Code;
            if Code = 401 or else Code = 403 then
               Diagnostic := To_Unbounded_String
                 ("Google Drive download authentication failed with status" & Natural'Image (Code));
               return Remote_Authentication_Failed;
            elsif Code = 404 then
               return Remote_Not_Found;
            elsif Code = 200 then
               return Remote_Ok;
            elsif Google_Drive_Retryable_Response (Code, "")
              and then Backup.Remote_Syntax.Retry_Available
                (Attempt, Options.Retry_Count)
            then
               null;
            else
               Diagnostic := To_Unbounded_String
                 ("Google Drive download returned status" & Natural'Image (Code));
               return Remote_Read_Failed;
            end if;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("Google Drive download retry loop did not run");
      return Remote_Read_Failed;
   end Download_Google_Drive_Object;

   function Delete_Google_Drive_Object
     (Location    : Remote_Location;
      Object_Name : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Id : constant String := Google_Drive_File_Id
        (Location, Options, Object_Name, Diagnostic);
      Client : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request : Http_Client.Requests.Request;
      Result  : Http_Client.Clients.Client_Result;
      Status  : Remote_Status;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Code : Natural;
   begin
      if Id'Length = 0 then
         if Length (Diagnostic) > 0 then
            return Remote_Read_Failed;
         end if;
         return Remote_Ok;
      end if;
      declare
         URL : constant String := Google_Drive_API_Base (Options) & "/files/" &
           Percent_Encode_Query_Component (Id) &
           Google_Drive_Supports_Query (Options, "?");
      begin
         Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
         Status := Prepare_HTTP_Request
           (Http_Client.Types.DELETE, URL, Google_Drive_HTTP_Options (Options, Diagnostic),
            Request, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
         for Attempt in Natural range 0 .. Options.Retry_Count loop
            HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
            if HTTP_Status /= Http_Client.Errors.Ok then
               if Backup.Remote_Syntax.Retry_Available
                 (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  return HTTP_Error_Status (HTTP_Status);
               end if;
            else
               Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
               declare
                  Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               begin
                  if Code = 200 or else Code = 202 or else Code = 204 or else Code = 404 then
                     return Remote_Ok;
                  elsif Code = 401 or else
                    (Code = 403 and then not Google_Drive_Retryable_Response (Code, Response_Body))
                  then
                     Diagnostic := To_Unbounded_String
                       ("Google Drive delete authentication failed with status" & Natural'Image (Code));
                     return Remote_Authentication_Failed;
                  elsif Google_Drive_Retryable_Response (Code, Response_Body)
                    and then Backup.Remote_Syntax.Retry_Available
                      (Attempt, Options.Retry_Count)
                  then
                     null;
                  else
                     Diagnostic := To_Unbounded_String
                       ("Google Drive delete returned status" & Natural'Image (Code));
                     return Remote_Delete_Refused;
                  end if;
               end;
            end if;
         end loop;
      end;
      Diagnostic := To_Unbounded_String ("Google Drive delete retry loop did not run");
      return Remote_Delete_Refused;
   end Delete_Google_Drive_Object;

   function Exchange_PCloud_Authorization_Code
     (Client_Id     : String;
      Client_Secret : String;
      Code          : String;
      Redirect_URI  : String;
      API_Base      : String;
      Token_JSON    : out Unbounded_String;
      Diagnostic    : out Unbounded_String) return Remote_Status
   is
      Options : Remote_Options;
      Status  : Remote_Status;
   begin
      if Client_Id'Length = 0 or else Code'Length = 0 or else Redirect_URI'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("pCloud OAuth token exchange requires CLIENT_ID, CODE, and REDIRECT_URI");
         Token_JSON := Null_Unbounded_String;
         return Remote_Invalid_URL;
      end if;
      Options.PCloud_API_Base := To_Unbounded_String (API_Base);
      Status := HTTP_Post_Form_Text
        (PCloud_Token_URI_For_Base (PCloud_API_Base (Options)),
         "grant_type=authorization_code" &
         "&client_id=" & Percent_Encode_Query_Component (Client_Id) &
         (if Client_Secret'Length = 0 then "" else
            "&client_secret=" & Percent_Encode_Query_Component (Client_Secret)) &
         "&code=" & Percent_Encode_Query_Component (Code) &
         "&redirect_uri=" & Percent_Encode_Query_Component (Redirect_URI),
         Options, Token_JSON, Diagnostic);
      if Status = Remote_Ok
        and then JSON_Field (To_String (Token_JSON), "access_token")'Length = 0
      then
         Diagnostic := To_Unbounded_String
           ("pCloud token exchange response did not contain access_token");
         return Remote_Read_Failed;
      end if;
      return Status;
   end Exchange_PCloud_Authorization_Code;

   function Resolved_PCloud_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Options
   is
      Result : Remote_Options := Options;
      Token_Text : Unbounded_String;
      Status     : Remote_Status;

      function Region_Auto return Boolean is
         Region : constant String := To_String (Result.PCloud_Region);
      begin
         return Length (Result.PCloud_API_Base) = 0
           and then (Region'Length = 0 or else Region = "auto");
      end Region_Auto;

      function Probe_Base (Base : String) return Boolean is
         Probe_Options : Remote_Options := Result;
         Probe_Result  : Http_Client.Clients.Client_Result;
         Probe_Diag    : Unbounded_String;
         Probe_Status  : Remote_Status;
         Code          : Natural := 0;
      begin
         Probe_Options.PCloud_API_Base := To_Unbounded_String (Base);
         Probe_Options.PCloud_Region := Null_Unbounded_String;
         Probe_Options.HTTP_Auth := HTTP_Auth_Bearer;
         Probe_Options.HTTP_Bearer_Token := Result.PCloud_Access_Token;
         Probe_Status := HTTP_Get
           (Base & "/userinfo", Probe_Options, Probe_Result, Probe_Diag);
         if Probe_Status /= Remote_Ok then
            return False;
         end if;
         Code := Natural (Http_Client.Responses.Status_Code (Probe_Result.Response));
         if Code /= 200 then
            return False;
         end if;
         return Project_Tools.JSON.Field_Value
           (Http_Client.Clients.Response_Text (Probe_Result), "result") = "0";
      exception
         when others =>
            return False;
      end Probe_Base;

      procedure Resolve_Auto_Region is
      begin
         if Region_Auto and then Length (Result.PCloud_Access_Token) > 0 then
            if Probe_Base ("https://api.pcloud.com") then
               Result.PCloud_API_Base := To_Unbounded_String ("https://api.pcloud.com");
            elsif Probe_Base ("https://eapi.pcloud.com") then
               Result.PCloud_API_Base := To_Unbounded_String ("https://eapi.pcloud.com");
            end if;
         end if;
      end Resolve_Auto_Region;
   begin
      if Length (Result.PCloud_Access_Token) > 0 then
         null;
      elsif Length (Result.PCloud_Token_Cache_File) > 0 then
         declare
            Token : constant String := Ada.Strings.Fixed.Trim
              (Read_Text_File (To_String (Result.PCloud_Token_Cache_File)),
               Ada.Strings.Both);
         begin
            if Token'Length > 0 then
               Result.PCloud_Access_Token := To_Unbounded_String (Token);
            end if;
         end;
      end if;

      if Length (Result.PCloud_Access_Token) > 0 then
         null;
      elsif Length (Result.PCloud_Access_Token_File) > 0 then
         declare
            Token : constant String := Ada.Strings.Fixed.Trim
              (Read_Text_File (To_String (Result.PCloud_Access_Token_File)),
               Ada.Strings.Both);
         begin
            if Token'Length = 0 then
               Diagnostic := To_Unbounded_String
                 ("pCloud access token file is empty or unreadable");
            else
               Result.PCloud_Access_Token := To_Unbounded_String (Token);
            end if;
         end;
      elsif Length (Result.PCloud_Refresh_Token) > 0 then
         if Length (Result.PCloud_Client_Id) = 0 then
            Diagnostic := To_Unbounded_String
              ("pCloud refresh token requires pcloud_client_id");
            return Result;
         end if;

         Status := HTTP_Post_Form_Text
           (PCloud_Token_URI (Result),
            "grant_type=refresh_token" &
            "&client_id=" & Percent_Encode_Query_Component
              (To_String (Result.PCloud_Client_Id)) &
            (if Length (Result.PCloud_Client_Secret) = 0 then "" else
               "&client_secret=" & Percent_Encode_Query_Component
                 (To_String (Result.PCloud_Client_Secret))) &
            "&refresh_token=" & Percent_Encode_Query_Component
              (To_String (Result.PCloud_Refresh_Token)),
            Result, Token_Text, Diagnostic);
         if Status = Remote_Ok then
            declare
               Token : constant String := JSON_Field
                 (To_String (Token_Text), "access_token");
            begin
               if Token'Length = 0 then
                  Diagnostic := To_Unbounded_String
                    ("pCloud token refresh response did not contain access_token");
               else
                  Result.PCloud_Access_Token := To_Unbounded_String (Token);
                  if Length (Result.PCloud_Token_Cache_File) > 0 then
                     Write_Text_File
                       (To_String (Result.PCloud_Token_Cache_File), Token);
                  end if;
               end if;
            end;
         end if;
      end if;
      Resolve_Auto_Region;
      return Result;
   end Resolved_PCloud_Options;

   function PCloud_HTTP_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Options
   is
      Result : Remote_Options := Resolved_PCloud_Options (Options, Diagnostic);
   begin
      Result.HTTP_Auth := HTTP_Auth_Bearer;
      Result.HTTP_Bearer_Token := Result.PCloud_Access_Token;
      return Result;
   end PCloud_HTTP_Options;

   function PCloud_API_URL
     (Options  : Remote_Options;
      Endpoint : String;
      Query    : String := "") return String
   is
   begin
      return PCloud_API_Base (Options) & "/" & Endpoint &
        (if Query'Length = 0 then "" else "?" & Query);
   end PCloud_API_URL;

   function PCloud_JSON_Field_Value
     (Text  : String;
      Field : String) return String is
   begin
      return Project_Tools.JSON.Field_Value (Text, Field);
   end PCloud_JSON_Field_Value;

   function PCloud_JSON_Array_First_Number
     (Text  : String;
      Field : String) return String is
   begin
      return Project_Tools.JSON.Array_First_Value (Text, Field);
   end PCloud_JSON_Array_First_Number;

   function PCloud_JSON_Array_First_String
     (Text  : String;
      Field : String) return String is
   begin
      return Project_Tools.JSON.Array_First_Value (Text, Field);
   end PCloud_JSON_Array_First_String;

   function PCloud_JSON_File_Object_Field
     (Text        : String;
      Match_Field : String;
      Match_Value : String;
      Value_Field : String) return String is
   begin
      return Project_Tools.JSON.Find_Object_Field
        (Text, Match_Field, Match_Value, Value_Field);
   end PCloud_JSON_File_Object_Field;

   function PCloud_Result_Code (Text : String) return Natural is
      Value : constant String := PCloud_JSON_Field_Value (Text, "result");
   begin
      if Value'Length > 0 then
         return Natural'Value (Value);
      end if;
      return Natural'Last;
   exception
      when others =>
         return Natural'Last;
   end PCloud_Result_Code;

   function PCloud_Result_OK (Text : String) return Boolean is
   begin
      return PCloud_Result_Code (Text) = 0;
   end PCloud_Result_OK;

   function PCloud_Retryable_Result (Result_Code : Natural) return Boolean is
   begin
      return (Result_Code >= 1_900 and then Result_Code <= 1_999)
        or else (Result_Code >= 4_000 and then Result_Code <= 5_999);
   end PCloud_Retryable_Result;

   function PCloud_Not_Found_Result (Result_Code : Natural) return Boolean is
   begin
      return Result_Code = 2_005 or else Result_Code = 2_009;
   end PCloud_Not_Found_Result;

   function PCloud_Authentication_Result (Result_Code : Natural) return Boolean is
   begin
      return Result_Code = 1_000 or else Result_Code = 2_000
        or else Result_Code = 2_003;
   end PCloud_Authentication_Result;

   function PCloud_Retryable_Response
     (Code : Natural;
      Text : String := "") return Boolean
   is
      Result_Code : constant Natural := PCloud_Result_Code (Text);
   begin
      return Code = 408 or else Code = 429 or else Code >= 500
        or else PCloud_Retryable_Result (Result_Code);
   end PCloud_Retryable_Response;

   function PCloud_Error_Diagnostic
     (Operation : String;
      Code      : Natural;
      Text      : String) return String
   is
      Result_Code : constant Natural := PCloud_Result_Code (Text);
      Error_Text  : constant String := PCloud_JSON_Field_Value (Text, "error");
      Message     : constant String := PCloud_JSON_Field_Value (Text, "message");
      Detail      : constant String :=
        (if Error_Text'Length > 0 then Error_Text else Message);
      Advice      : constant String :=
        (if PCloud_Authentication_Result (Result_Code) then
           "; check token validity and whether pcloud_api_base matches the account region (US https://api.pcloud.com, EU https://eapi.pcloud.com)"
         elsif Result_Code = 2_001 then
           "; check generated pCloud object names and folder path characters"
         elsif Result_Code = 2_005 then
           "; check that the pCloud folder exists or enable parent-folder creation for folder-path URLs"
         elsif Result_Code = 2_008 then
           "; pCloud reports insufficient quota for this upload"
         elsif Result_Code = 2_009 then
           "; the pCloud file or folder was not found"
         elsif Result_Code >= 4_000 and then Result_Code <= 5_999 then
           "; provider returned a retryable/transient pCloud failure; consider increasing retry_count"
         else "");
   begin
      return "pCloud " & Operation & " returned status" & Natural'Image (Code) &
        (if Result_Code = Natural'Last then "" else
           " result" & Natural'Image (Result_Code)) &
        (if Detail'Length = 0 then "" else ": " & Detail) & Advice;
   end PCloud_Error_Diagnostic;

   function PCloud_Free_Quota
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Interfaces.Unsigned_64
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
   begin
      Status := HTTP_Get
        (PCloud_API_URL (Options, "userinfo"),
         PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
      if Status /= Remote_Ok then
         return Interfaces.Unsigned_64'Last;
      end if;
      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      declare
         Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
         Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
         Free_Text : constant String := PCloud_JSON_Field_Value (Response_Body, "freequota");
         Quota_Text : constant String := PCloud_JSON_Field_Value (Response_Body, "quota");
         Used_Text : constant String := PCloud_JSON_Field_Value (Response_Body, "usedquota");
      begin
         if Code /= 200 or else Result_Code /= 0 then
            return Interfaces.Unsigned_64'Last;
         elsif Free_Text'Length > 0 then
            return Interfaces.Unsigned_64'Value (Free_Text);
         elsif Quota_Text'Length > 0 and then Used_Text'Length > 0 then
            declare
               Quota : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64'Value (Quota_Text);
               Used : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64'Value (Used_Text);
            begin
               if Quota >= Used then
                  return Quota - Used;
               end if;
            end;
         end if;
      end;
      return Interfaces.Unsigned_64'Last;
   exception
      when others =>
         return Interfaces.Unsigned_64'Last;
   end PCloud_Free_Quota;

   function PCloud_Quota_Allows
     (Options    : Remote_Options;
      Size       : Interfaces.Unsigned_64;
      Diagnostic : out Unbounded_String) return Boolean
   is
      Free : Interfaces.Unsigned_64;
   begin
      if not Options.PCloud_Check_Quota or else Size = 0 then
         return True;
      end if;
      Free := PCloud_Free_Quota (Options, Diagnostic);
      if Free /= Interfaces.Unsigned_64'Last and then Free < Size then
         Diagnostic := To_Unbounded_String
           ("pCloud quota preflight failed: required" &
            Interfaces.Unsigned_64'Image (Size) & " bytes but freequota is" &
            Interfaces.Unsigned_64'Image (Free) & " bytes");
         return False;
      end if;
      return True;
   end PCloud_Quota_Allows;

   function Create_PCloud_Folder_Child
     (Options    : Remote_Options;
      Parent_Id  : String;
      Name       : String;
      Diagnostic : out Unbounded_String) return String
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
   begin
      if Parent_Id'Length = 0 or else Name'Length = 0 then
         return "";
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (PCloud_API_URL
              (Options, "createfolderifnotexists",
               "folderid=" & Percent_Encode_Query_Component (Parent_Id) &
               "&name=" & Percent_Encode_Query_Component (Name)),
            PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available (Attempt, Options.Retry_Count) then
               null;
            else
               return "";
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
               Folder_Id : constant String := PCloud_JSON_Field_Value (Response_Body, "folderid");
            begin
               if Code = 200 and then Result_Code = 0 and then Folder_Id'Length > 0 then
                  return Folder_Id;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
                 Backup.Remote_Syntax.Retry_Available (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("createfolderifnotexists", Code, Response_Body));
                  return "";
               end if;
            end;
         end if;
      end loop;
      return "";
   end Create_PCloud_Folder_Child;

   function Create_PCloud_Folder_Path
     (Options    : Remote_Options;
      Path       : String;
      Diagnostic : out Unbounded_String) return String
   is
      Current_Id : Unbounded_String := To_Unbounded_String ("0");
      First      : Natural := Path'First;
      Last       : Natural;
   begin
      if Path'Length = 0 then
         return "0";
      end if;
      while First <= Path'Last loop
         while First <= Path'Last and then Path (First) = '/' loop
            First := First + 1;
         end loop;
         exit when First > Path'Last;
         Last := First;
         while Last <= Path'Last and then Path (Last) /= '/' loop
            Last := Last + 1;
         end loop;
         Current_Id := To_Unbounded_String
           (Create_PCloud_Folder_Child
              (Options, To_String (Current_Id), Path (First .. Last - 1), Diagnostic));
         if Length (Current_Id) = 0 then
            return "";
         end if;
         First := Last + 1;
      end loop;
      return To_String (Current_Id);
   end Create_PCloud_Folder_Path;

   function PCloud_Upload_Progress_Available
     (Options       : Remote_Options;
      Progress_Hash : String) return Boolean
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Poll_Diagnostic : Unbounded_String;
      Code   : Natural := 0;
   begin
      if Progress_Hash'Length = 0 then
         return False;
      end if;
      Status := HTTP_Get
        (PCloud_API_URL
           (Options, "uploadprogress",
            "progresshash=" & Percent_Encode_Query_Component (Progress_Hash)),
         PCloud_HTTP_Options (Options, Poll_Diagnostic), Result, Poll_Diagnostic);
      if Status = Remote_Ok then
         Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
         declare
            Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
            Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
         begin
            return Code = 200 and then Result_Code = 0;
         end;
      end if;
      return False;
   end PCloud_Upload_Progress_Available;

   procedure Poll_PCloud_Upload_Progress
     (Options       : Remote_Options;
      Progress_Hash : String;
      Diagnostic    : in out Unbounded_String)
   is
   begin
      if not Options.PCloud_Poll_Progress or else Progress_Hash'Length = 0 then
         return;
      end if;
      if not PCloud_Upload_Progress_Available (Options, Progress_Hash)
        and then Length (Diagnostic) = 0
      then
         Diagnostic := To_Unbounded_String ("pCloud uploadprogress polling did not return progress metadata");
      end if;
   end Poll_PCloud_Upload_Progress;

   function PCloud_Target_Folder_Id
     (Location   : Remote_Location;
      Options    : Remote_Options;
      Create     : Boolean;
      Diagnostic : out Unbounded_String) return String
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
      URL    : Unbounded_String;
   begin
      if PCloud_Namespace_Uses_Folder_Id (Location) then
         return PCloud_Folder_Id (Location);
      end if;

      if Create then
         URL := To_Unbounded_String
           (PCloud_API_URL
              (Options, "createfolderifnotexists",
               "path=" & Percent_Encode_Query_Component (PCloud_Folder_Path (Location))));
      else
         URL := To_Unbounded_String
           (PCloud_API_URL
              (Options, "listfolder",
               "path=" & Percent_Encode_Query_Component (PCloud_Folder_Path (Location))));
      end if;

      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (To_String (URL), PCloud_HTTP_Options (Options, Diagnostic),
            Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return "";
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
               Folder_Id : constant String := PCloud_JSON_Field_Value (Response_Body, "folderid");
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (Result_Code)
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic
                       ((if Create then "createfolderifnotexists" else "listfolder"),
                        Code, Response_Body));
                  return "";
               elsif Code = 404 or else PCloud_Not_Found_Result (Result_Code) then
                  if Create and then Options.PCloud_Create_Parents then
                     return Create_PCloud_Folder_Path
                       (Options, PCloud_Folder_Path (Location), Diagnostic);
                  elsif Create then
                     Diagnostic := To_Unbounded_String
                       (PCloud_Error_Diagnostic
                          ("createfolderifnotexists", Code, Response_Body));
                  end if;
                  return "";
               elsif Code = 200 and then Result_Code = 0 and then Folder_Id'Length > 0 then
                  return Folder_Id;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
                 Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  if Create and then Options.PCloud_Create_Parents then
                     declare
                        Fallback_Id : constant String :=
                          Create_PCloud_Folder_Path
                            (Options, PCloud_Folder_Path (Location), Diagnostic);
                     begin
                        if Fallback_Id'Length > 0 then
                           return Fallback_Id;
                        end if;
                     end;
                  end if;
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic
                       ((if Create then "createfolderifnotexists" else "listfolder"),
                        Code, Response_Body));
                  return "";
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud folder lookup retry loop did not run");
      return "";
   end PCloud_Target_Folder_Id;

   function PCloud_File_Id_By_Name
     (Location    : Remote_Location;
      Options     : Remote_Options;
      Stored_Name : String;
      Diagnostic  : out Unbounded_String) return String
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
      Folder_Id : constant String := PCloud_Target_Folder_Id
        (Location, Options, False, Diagnostic);
      URL    : constant String := PCloud_API_URL
        (Options, "listfolder",
         "folderid=" & Percent_Encode_Query_Component (Folder_Id));
   begin
      if Folder_Id'Length = 0 then
         return "";
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (URL, PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return "";
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
            begin
               if Code = 401 or else Code = 403 then
                  Diagnostic := To_Unbounded_String
                    ("pCloud authentication failed with status" & Natural'Image (Code));
                  return "";
               elsif Code = 404 then
                  Diagnostic := Null_Unbounded_String;
                  return "";
               elsif Code = 200 and then PCloud_Result_OK (Response_Body) then
                  declare
                     File_Id : constant String := PCloud_JSON_File_Object_Field
                       (Response_Body, "name", Stored_Name, "fileid");
                  begin
                     if File_Id'Length = 0 then
                        Diagnostic := Null_Unbounded_String;
                     end if;
                     return File_Id;
                  end;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
                 Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("listfolder", Code, Response_Body));
                  return "";
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud listfolder retry loop did not run");
      return "";
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("pCloud file lookup failed");
         return "";
   end PCloud_File_Id_By_Name;

   function PCloud_File_Id
     (Location    : Remote_Location;
      Options     : Remote_Options;
      Object_Name : String;
      Diagnostic  : out Unbounded_String) return String
   is
   begin
      return PCloud_File_Id_By_Name
        (Location, Options, PCloud_Name (Location, Object_Name), Diagnostic);
   end PCloud_File_Id;

   function PCloud_Checksum_Metadata_By_Name
     (Location      : Remote_Location;
      Options       : Remote_Options;
      Stored_Name   : String;
      Size          : out Interfaces.Unsigned_64;
      Has_SHA256    : out Boolean;
      SHA256        : out Unbounded_String;
      Has_SHA1      : out Boolean;
      SHA1          : out Unbounded_String;
      Diagnostic    : out Unbounded_String) return Remote_Status
   is
      Id     : constant String := PCloud_File_Id_By_Name
        (Location, Options, Stored_Name, Diagnostic);
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
   begin
      Size := 0;
      Has_SHA256 := False;
      SHA256 := Null_Unbounded_String;
      Has_SHA1 := False;
      SHA1 := Null_Unbounded_String;
      if Id'Length = 0 then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String ("pCloud object was not found: " & Stored_Name);
            return Remote_Not_Found;
         end if;
         return Remote_Read_Failed;
      end if;

      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (PCloud_API_URL
              (Options, "checksumfile",
               "fileid=" & Percent_Encode_Query_Component (Id)),
            PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
               Size_Text : constant String := PCloud_JSON_Field_Value (Response_Body, "size");
               SHA_Text  : constant String := PCloud_JSON_Field_Value (Response_Body, "sha256");
               SHA1_Text : constant String := PCloud_JSON_Field_Value (Response_Body, "sha1");
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (Result_Code)
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("checksumfile", Code, Response_Body));
                  return Remote_Authentication_Failed;
               elsif Code = 404 or else PCloud_Not_Found_Result (Result_Code) then
                  Diagnostic := To_Unbounded_String ("pCloud object was not found: " & Stored_Name);
                  return Remote_Not_Found;
               elsif Code = 200 and then Result_Code = 0 and then Size_Text'Length > 0 then
                  Size := Interfaces.Unsigned_64'Value (Size_Text);
                  if SHA_Text'Length > 0 then
                     Has_SHA256 := True;
                     SHA256 := To_Unbounded_String (SHA_Text);
                  end if;
                  if SHA1_Text'Length > 0 then
                     Has_SHA1 := True;
                     SHA1 := To_Unbounded_String (SHA1_Text);
                  end if;
                  return Remote_Ok;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
                 Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("checksumfile", Code, Response_Body));
                  return Remote_Read_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud checksumfile retry loop did not run");
      return Remote_Read_Failed;
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("pCloud checksum metadata parsing failed");
         return Remote_Read_Failed;
   end PCloud_Checksum_Metadata_By_Name;

   function PCloud_Checksum_Metadata
     (Location      : Remote_Location;
      Options       : Remote_Options;
      Object_Name   : String;
      Size          : out Interfaces.Unsigned_64;
      Has_SHA256    : out Boolean;
      SHA256        : out Unbounded_String;
      Has_SHA1      : out Boolean;
      SHA1          : out Unbounded_String;
      Diagnostic    : out Unbounded_String) return Remote_Status
   is
   begin
      return PCloud_Checksum_Metadata_By_Name
        (Location, Options, PCloud_Name (Location, Object_Name), Size,
         Has_SHA256, SHA256, Has_SHA1, SHA1, Diagnostic);
   end PCloud_Checksum_Metadata;

   function Delete_PCloud_File_Id
     (Options     : Remote_Options;
      File_Id     : String;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
   begin
      if File_Id'Length = 0 then
         return Remote_Ok;
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (PCloud_API_URL
              (Options, "deletefile",
               "fileid=" & Percent_Encode_Query_Component (File_Id)),
            PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (Result_Code)
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("deletefile", Code, Response_Body));
                  return Remote_Authentication_Failed;
               elsif Code = 404 or else PCloud_Not_Found_Result (Result_Code)
                 or else (Code = 200 and then Result_Code = 0)
               then
                  return Remote_Ok;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
              Backup.Remote_Syntax.Retry_Available
                (Attempt, Options.Retry_Count)
            then
               null;
            else
               Diagnostic := To_Unbounded_String
                 (PCloud_Error_Diagnostic
                    ("deletefile", Code, Http_Client.Clients.Response_Text (Result)));
               return Remote_Delete_Refused;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud delete retry loop did not run");
      return Remote_Delete_Refused;
   end Delete_PCloud_File_Id;

   function Delete_PCloud_Object
     (Location    : Remote_Location;
      Object_Name : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Id : constant String := PCloud_File_Id
        (Location, Options, Object_Name, Diagnostic);
   begin
      if Id'Length = 0 then
         if Length (Diagnostic) > 0 then
            return Remote_Read_Failed;
         end if;
         return Remote_Ok;
      end if;
      return Delete_PCloud_File_Id (Options, Id, Diagnostic);
   end Delete_PCloud_Object;

   function Cleanup_PCloud_Temporary_Objects
     (Location   : Remote_Location;
      Options    : Remote_Options;
      Deleted    : out Natural;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Folder_Id : constant String := PCloud_Target_Folder_Id
        (Location, Options, False, Diagnostic);
      function Object_Start (Text : String; At_Pos : Natural) return Natural is
         Pos : Natural := At_Pos;
      begin
         while Pos > Text'First loop
            if Text (Pos) = '{' then
               return Pos;
            end if;
            Pos := Pos - 1;
         end loop;
         return 0;
      end Object_Start;

      function Object_End (Text : String; At_Pos : Natural) return Natural is
         Pos : Natural := At_Pos;
      begin
         while Pos <= Text'Last loop
            if Text (Pos) = '}' then
               return Pos;
            end if;
            Pos := Pos + 1;
         end loop;
         return 0;
      end Object_End;

      procedure Delete_Temporary_Metadata (Response_Text : String) is
         Pos   : Natural := Response_Text'First;
         Hit   : Natural;
         First : Natural;
         Last  : Natural;
      begin
         loop
            Hit := Ada.Strings.Fixed.Index
              (Response_Text (Pos .. Response_Text'Last), ".backup-upload-");
            exit when Hit = 0;
            First := Object_Start (Response_Text, Hit);
            Last := Object_End (Response_Text, Hit);
            if First > 0 and then Last >= First then
               declare
                  Object_Text : constant String := Response_Text (First .. Last);
                  Name : constant String :=
                    Project_Tools.JSON.Object_Field_Value (Object_Text, "name");
                  File_Id : constant String :=
                    Project_Tools.JSON.Object_Field_Value (Object_Text, "fileid");
                  Delete_Status : Remote_Status;
               begin
                  if Name'Length > 0
                    and then Ada.Strings.Fixed.Index (Name, ".backup-upload-") > 0
                    and then File_Id'Length > 0
                  then
                     Delete_Status :=
                       Delete_PCloud_File_Id (Options, File_Id, Diagnostic);
                     if Delete_Status = Remote_Ok then
                        Deleted := Deleted + 1;
                     end if;
                  end if;
               end;
               Pos := Last + 1;
            elsif Hit < Response_Text'Last then
               Pos := Hit + 1;
            else
               exit;
            end if;
            exit when Pos > Response_Text'Last;
         end loop;
      end Delete_Temporary_Metadata;

      procedure Cleanup_Folder
        (Current_Folder_Id : String;
         Depth             : Natural;
         Folder_Status     : out Remote_Status)
      is
         Result : Http_Client.Clients.Client_Result;
         Status : Remote_Status;
         Code   : Natural := 0;

         procedure Recurse_Child_Folders (Response_Text : String) is
            Pos   : Natural := Response_Text'First;
            Hit   : Natural;
            First : Natural;
            Last  : Natural;
         begin
            if not Options.PCloud_Clean_Recursive or else Depth >= 32 then
               return;
            end if;

            loop
               Hit := Ada.Strings.Fixed.Index
                 (Response_Text (Pos .. Response_Text'Last), """folderid""");
               exit when Hit = 0;
               First := Object_Start (Response_Text, Hit);
               Last := Object_End (Response_Text, Hit);
               if First > 0 and then Last >= First then
                  declare
                     Object_Text : constant String := Response_Text (First .. Last);
                     Is_Folder : constant String :=
                       Project_Tools.JSON.Object_Field_Value
                         (Object_Text, "isfolder");
                     Child_Id : constant String :=
                       Project_Tools.JSON.Object_Field_Value
                         (Object_Text, "folderid");
                     Child_Status : Remote_Status;
                  begin
                     if Is_Folder = "true" and then Child_Id'Length > 0 then
                        Cleanup_Folder (Child_Id, Depth + 1, Child_Status);
                        if Child_Status /= Remote_Ok then
                           Folder_Status := Child_Status;
                           return;
                        end if;
                     end if;
                  end;
                  Pos := Last + 1;
               elsif Hit < Response_Text'Last then
                  Pos := Hit + 1;
               else
                  exit;
               end if;
               exit when Pos > Response_Text'Last;
            end loop;
         end Recurse_Child_Folders;
      begin
         Folder_Status := Remote_Delete_Refused;
         for Attempt in Natural range 0 .. Options.Retry_Count loop
            Status := HTTP_Get
              (PCloud_API_URL
                 (Options, "listfolder",
                  "folderid=" & Percent_Encode_Query_Component (Current_Folder_Id)),
               PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
            if Status /= Remote_Ok then
               if Backup.Remote_Syntax.Retry_Available
                 (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Folder_Status := Status;
                  return;
               end if;
            else
               Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
               declare
                  Response_Body : constant String :=
                    Http_Client.Clients.Response_Text (Result);
                  Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
               begin
                  if Code = 401 or else Code = 403
                    or else PCloud_Authentication_Result (Result_Code)
                  then
                     Diagnostic := To_Unbounded_String
                       (PCloud_Error_Diagnostic ("listfolder", Code, Response_Body));
                     Folder_Status := Remote_Authentication_Failed;
                     return;
                  elsif Code = 200 and then Result_Code = 0 then
                     Delete_Temporary_Metadata (Response_Body);
                     Folder_Status := Remote_Ok;
                     Recurse_Child_Folders (Response_Body);
                     return;
                  elsif PCloud_Retryable_Response (Code, Response_Body) and then
                    Backup.Remote_Syntax.Retry_Available
                      (Attempt, Options.Retry_Count)
                  then
                     null;
                  else
                     Diagnostic := To_Unbounded_String
                       (PCloud_Error_Diagnostic ("listfolder", Code, Response_Body));
                     Folder_Status := Remote_Delete_Refused;
                     return;
                  end if;
               end;
            end if;
         end loop;
         Diagnostic := To_Unbounded_String ("pCloud cleanup retry loop did not run");
         Folder_Status := Remote_Delete_Refused;
      end Cleanup_Folder;
   begin
      Deleted := 0;
      if Folder_Id'Length = 0 then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String ("pCloud cleanup folder was not found");
         end if;
         return Remote_Not_Found;
      end if;

      declare
         Folder_Status : Remote_Status;
      begin
         Cleanup_Folder (Folder_Id, 0, Folder_Status);
         return Folder_Status;
      end;
   end Cleanup_PCloud_Temporary_Objects;

   function Execute_PCloud_Text_Upload
     (URL          : String;
      Payload      : String;
      Content_Type : String;
      Options      : Remote_Options;
      Result       : out Http_Client.Clients.Client_Result;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Status      : Remote_Status;
   begin
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set (Headers, "Content-Type", Content_Type);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         Status := Add_HTTP_Auth_Headers
           (PCloud_HTTP_Options (Options, Diagnostic), Headers, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method => Http_Client.Types.PUT, URI => URI, Item => Request, Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String (Payload));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("pCloud uploadfile request failed");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Execute_PCloud_Text_Upload;

   function Rename_PCloud_File
     (Options      : Remote_Options;
      File_Id      : String;
      Folder_Id    : String;
      Final_Name   : String;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
      URL    : constant String := PCloud_API_URL
        (Options, "renamefile",
         "fileid=" & Percent_Encode_Query_Component (File_Id) &
         "&tofolderid=" & Percent_Encode_Query_Component (Folder_Id) &
         "&toname=" & Percent_Encode_Query_Component (Final_Name));
   begin
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (URL, PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (Result_Code)
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("renamefile", Code, Response_Body));
                  return Remote_Authentication_Failed;
               elsif Code = 200 and then Result_Code = 0 then
                  return Remote_Ok;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
                 Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("renamefile", Code, Response_Body));
                  return Remote_Write_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud renamefile retry loop did not run");
      return Remote_Write_Failed;
   end Rename_PCloud_File;

   function PCloud_Uploaded_File_Id (Response_Body : String) return String is
      Id : constant String := PCloud_JSON_Field_Value (Response_Body, "fileid");
      Array_Id : constant String :=
        PCloud_JSON_Array_First_Number (Response_Body, "fileids");
   begin
      if Id'Length > 0 then
         return Id;
      elsif Array_Id'Length > 0 then
         return Array_Id;
      end if;
      return PCloud_JSON_Field_Value (Response_Body, "fileid");
   end PCloud_Uploaded_File_Id;

   function PCloud_Temporary_Name
     (Final_Name : String;
      Size       : Interfaces.Unsigned_64;
      Resumable  : Boolean := False) return String
   is
      Raw : constant String := Interfaces.Unsigned_64'Image (Size);
      Stable_Nonce : constant String := Http_Client.Crypto.Digest_SHA256_Hex
        ("backup:pcloud:resume:" & Final_Name & ":" & Raw);
      Stamp : constant String := Ada.Calendar.Formatting.Image
        (Ada.Calendar.Clock, Include_Time_Fraction => True);
      Nonce : constant String := Http_Client.Crypto.Digest_SHA256_Hex
        (Final_Name & ":" & Raw & ":" & Stamp);
      Size_Text : constant String := Raw (Raw'First + 1 .. Raw'Last);
   begin
      if Resumable then
         return Final_Name & ".backup-upload-resume-" & Size_Text & "-" &
           Stable_Nonce (Stable_Nonce'First .. Stable_Nonce'First + 15);
      end if;

      return Final_Name & ".backup-upload-" & Size_Text & "-" &
        Nonce (Nonce'First .. Nonce'First + 15);
   end PCloud_Temporary_Name;


   function PCloud_Progress_Hash
     (Final_Name : String;
      Temp_Name  : String;
      Size       : Interfaces.Unsigned_64) return String
   is
   begin
      return Http_Client.Crypto.Digest_SHA256_Hex
        ("backup:pcloud:upload:" & Final_Name & ":" & Temp_Name & ":" &
         Interfaces.Unsigned_64'Image (Size));
   end PCloud_Progress_Hash;

   function PCloud_Object_Matches_Local_By_Name
     (Location    : Remote_Location;
      Stored_Name : String;
      Local_Path  : String;
      Size        : Interfaces.Unsigned_64;
      Options     : Remote_Options;
      Found       : out Boolean;
      Match       : out Boolean;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Remote_Size : Interfaces.Unsigned_64 := 0;
      Has_SHA256  : Boolean := False;
      Remote_SHA256 : Unbounded_String;
      Has_SHA1    : Boolean := False;
      Remote_SHA1 : Unbounded_String;
      Status      : Remote_Status;
      Check_Diagnostic : Unbounded_String;
   begin
      Found := False;
      Match := False;
      Check_Diagnostic := Null_Unbounded_String;
      Status := PCloud_Checksum_Metadata_By_Name
        (Location, Options, Stored_Name, Remote_Size, Has_SHA256, Remote_SHA256,
         Has_SHA1, Remote_SHA1, Check_Diagnostic);
      if Status = Remote_Not_Found then
         Diagnostic := Null_Unbounded_String;
         return Remote_Ok;
      elsif Status /= Remote_Ok then
         Diagnostic := Check_Diagnostic;
         return Status;
      end if;

      Found := True;
      if Remote_Size /= Size then
         Diagnostic := Null_Unbounded_String;
         return Remote_Ok;
      elsif Has_SHA256 then
         Match := Equal_Hex_Case_Insensitive
           (To_String (Remote_SHA256),
            Http_Client.Crypto.Digest_File_SHA256_Hex (Local_Path));
         Diagnostic := Null_Unbounded_String;
         return Remote_Ok;
      elsif Has_SHA1 then
         declare
            Local_SHA1 : constant String := Digest_File_SHA1_Hex (Local_Path);
         begin
            Match := Local_SHA1'Length > 0
              and then Equal_Hex_Case_Insensitive
                (To_String (Remote_SHA1), Local_SHA1);
            Diagnostic := Null_Unbounded_String;
            return Remote_Ok;
         end;
      end if;

      declare
         Temp_Path : constant String := Local_Path & ".pcloud-resume-check.tmp";
         Local     : Archive_Metadata;
         Remote    : Archive_Metadata;
      begin
         Status := Download_PCloud_Object_By_Name
           (Location, Stored_Name, Temp_Path, Options, Diagnostic);
         if Status /= Remote_Ok then
            Delete_If_Exists (Temp_Path);
            return Status;
         end if;
         Status := File_Metadata (Local_Path, True, False, Local, Diagnostic);
         if Status = Remote_Ok then
            Status := File_Metadata (Temp_Path, True, False, Remote, Diagnostic);
         end if;
         Delete_If_Exists (Temp_Path);
         if Status /= Remote_Ok then
            return Status;
         end if;
         Match := Remote.Size = Local.Size and then Remote.Crc32 = Local.Crc32;
         Diagnostic := Null_Unbounded_String;
         return Remote_Ok;
      end;
   end PCloud_Object_Matches_Local_By_Name;

   function Publish_PCloud_Temporary_File
     (Options    : Remote_Options;
      File_Id    : String;
      Folder_Id  : String;
      Final_Name : String;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Status : Remote_Status;
      Cleanup_Diagnostic : Unbounded_String;
   begin
      Status := Rename_PCloud_File
        (Options, File_Id, Folder_Id, Final_Name, Diagnostic);
      if Status /= Remote_Ok then
         Cleanup_Diagnostic := Null_Unbounded_String;
         declare
            Ignored : constant Remote_Status :=
              Delete_PCloud_File_Id (Options, File_Id, Cleanup_Diagnostic);
         begin
            null;
         end;
      end if;
      return Status;
   end Publish_PCloud_Temporary_File;

   function Upload_PCloud_Object
     (Location     : Remote_Location;
      Object_Name  : String;
      Payload      : String;
      Content_Type : String;
      Options      : Remote_Options;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
      Folder_Id  : constant String :=
        PCloud_Target_Folder_Id (Location, Options, True, Diagnostic);
      Final_Name : constant String := PCloud_Name (Location, Object_Name);
      Temp_Name  : constant String :=
        PCloud_Temporary_Name
          (Final_Name, Interfaces.Unsigned_64 (Payload'Length));
      Progress_Hash : constant String :=
        PCloud_Progress_Hash
          (Final_Name, Temp_Name, Interfaces.Unsigned_64 (Payload'Length));
      URL    : constant String := PCloud_API_URL
        (Options, "uploadfile",
         "folderid=" & Percent_Encode_Query_Component (Folder_Id) &
         "&filename=" & Percent_Encode_Query_Component (Temp_Name) &
         "&nopartial=1&renameifexists=0" &
         (if Options.PCloud_Upload_Progress then
            "&progresshash=" & Percent_Encode_Query_Component (Progress_Hash)
          else ""));
   begin
      if Folder_Id'Length = 0 then
         return Remote_Write_Failed;
      elsif not PCloud_Quota_Allows
        (Options, Interfaces.Unsigned_64 (Payload'Length), Diagnostic)
      then
         return Remote_Write_Failed;
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Execute_PCloud_Text_Upload
           (URL, Payload, Content_Type, Options, Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (Result_Code)
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("uploadfile", Code, Response_Body));
                  return Remote_Authentication_Failed;
               elsif HTTP_Status_OK (Code, For_Upload => True) and then Result_Code = 0
               then
                  declare
                     File_Id : constant String := PCloud_Uploaded_File_Id (Response_Body);
                  begin
                     if File_Id'Length = 0 then
                        Diagnostic := To_Unbounded_String
                          ("pCloud uploadfile response did not contain fileid");
                        return Remote_Write_Failed;
                     end if;
                     Poll_PCloud_Upload_Progress
                       (Options, Progress_Hash, Diagnostic);
                     return Publish_PCloud_Temporary_File
                       (Options, File_Id, Folder_Id, Final_Name, Diagnostic);
                  end;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
              Backup.Remote_Syntax.Retry_Available
                (Attempt, Options.Retry_Count)
            then
               null;
            else
               Diagnostic := To_Unbounded_String
                 (PCloud_Error_Diagnostic
                    ("uploadfile", Code, Http_Client.Clients.Response_Text (Result)));
               return Remote_Write_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud upload retry loop did not run");
      return Remote_Write_Failed;
   end Upload_PCloud_Object;

   function Upload_PCloud_File
     (Location     : Remote_Location;
      Object_Name  : String;
      Path         : String;
      Size         : Interfaces.Unsigned_64;
      Options      : Remote_Options;
      Report       : in out Transfer_Report;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
      Folder_Id  : constant String :=
        PCloud_Target_Folder_Id (Location, Options, True, Diagnostic);
      Final_Name : constant String := PCloud_Name (Location, Object_Name);
      Temp_Name  : constant String := PCloud_Temporary_Name
        (Final_Name, Size, Resume_Upload_Enabled (Options.Upload_Behavior));
      Progress_Hash : constant String :=
        PCloud_Progress_Hash (Final_Name, Temp_Name, Size);
      URL    : constant String := PCloud_API_URL
        (Options, "uploadfile",
         "folderid=" & Percent_Encode_Query_Component (Folder_Id) &
         "&filename=" & Percent_Encode_Query_Component (Temp_Name) &
         "&nopartial=1&renameifexists=0" &
         (if Options.PCloud_Upload_Progress then
            "&progresshash=" & Percent_Encode_Query_Component (Progress_Hash)
          else ""));
   begin
      if Folder_Id'Length = 0 then
         return Remote_Write_Failed;
      end if;

      if Resume_Upload_Enabled (Options.Upload_Behavior) then
         declare
            Found : Boolean := False;
            Match : Boolean := False;
            Resume_Status : Remote_Status;
         begin
            Resume_Status := PCloud_Object_Matches_Local_By_Name
              (Location, Final_Name, Path, Size, Options, Found, Match,
               Diagnostic);
            if Resume_Status /= Remote_Ok then
               return Resume_Status;
            elsif Match then
               Report.Resumed := True;
               return Remote_Ok;
            end if;

            Resume_Status := PCloud_Object_Matches_Local_By_Name
              (Location, Temp_Name, Path, Size, Options, Found, Match,
               Diagnostic);
            if Resume_Status /= Remote_Ok then
               return Resume_Status;
            elsif Match then
               declare
                  File_Id : constant String := PCloud_File_Id_By_Name
                    (Location, Options, Temp_Name, Diagnostic);
               begin
                  if File_Id'Length = 0 then
                     Diagnostic := To_Unbounded_String
                       ("matching pCloud temporary upload disappeared before publish");
                     return Remote_Not_Found;
                  end if;
                  Resume_Status := Publish_PCloud_Temporary_File
                    (Options, File_Id, Folder_Id, Final_Name, Diagnostic);
                  if Resume_Status = Remote_Ok then
                     Report.Resumed := True;
                  end if;
                  return Resume_Status;
               end;
            elsif Found then
               declare
                  Stale_Id : constant String := PCloud_File_Id_By_Name
                    (Location, Options, Temp_Name, Diagnostic);
               begin
                  if Stale_Id'Length > 0 then
                     Resume_Status := Delete_PCloud_File_Id
                       (Options, Stale_Id, Diagnostic);
                     if Resume_Status /= Remote_Ok then
                        return Resume_Status;
                     end if;
                  end if;
               end;
            end if;
         end;
      end if;

      if not PCloud_Quota_Allows (Options, Size, Diagnostic) then
         return Remote_Write_Failed;
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         declare
            task Progress_Monitor is
               entry Stop (Samples : out Natural);
            end Progress_Monitor;

            task body Progress_Monitor is
               Count : Natural := 0;
            begin
               if Options.PCloud_Poll_Progress
                 and then Options.PCloud_Upload_Progress
                 and then Progress_Hash'Length > 0
               then
                  loop
                     select
                        accept Stop (Samples : out Natural) do
                           Samples := Count;
                        end Stop;
                        exit;
                     or
                        delay 0.25;
                        if PCloud_Upload_Progress_Available
                          (Options, Progress_Hash)
                        then
                           Count := Count + 1;
                        end if;
                     end select;
                  end loop;
               else
                  accept Stop (Samples : out Natural) do
                     Samples := 0;
                  end Stop;
               end if;
            exception
               when others =>
                  accept Stop (Samples : out Natural) do
                     Samples := Count;
                  end Stop;
            end Progress_Monitor;

            Samples : Natural := 0;
         begin
            Status := Stream_HTTP_Put
              (URL, Path, Size, "", 0,
               PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
            Progress_Monitor.Stop (Samples);
            Report.PCloud_Progress_Samples :=
              Report.PCloud_Progress_Samples + Samples;
         end;
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               Report.Retried := Report.Retried + 1;
            else
               return Status;
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (Result_Code)
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("uploadfile", Code, Response_Body));
                  return Remote_Authentication_Failed;
               elsif HTTP_Status_OK (Code, For_Upload => True) and then Result_Code = 0
               then
                  declare
                     File_Id : constant String := PCloud_Uploaded_File_Id (Response_Body);
                  begin
                     if File_Id'Length = 0 then
                        Diagnostic := To_Unbounded_String
                          ("pCloud uploadfile response did not contain fileid");
                        return Remote_Write_Failed;
                     end if;
                     Poll_PCloud_Upload_Progress
                       (Options, Progress_Hash, Diagnostic);
                     return Publish_PCloud_Temporary_File
                       (Options, File_Id, Folder_Id, Final_Name, Diagnostic);
                  end;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
              Backup.Remote_Syntax.Retry_Available
                (Attempt, Options.Retry_Count)
            then
               Report.Retried := Report.Retried + 1;
            else
               Diagnostic := To_Unbounded_String
                 (PCloud_Error_Diagnostic
                    ("uploadfile", Code, Http_Client.Clients.Response_Text (Result)));
               return Remote_Write_Failed;
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud upload retry loop did not run");
      return Remote_Write_Failed;
   end Upload_PCloud_File;

   function PCloud_Download_URL_By_Name
     (Location    : Remote_Location;
      Stored_Name : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return String
   is
      Id     : constant String := PCloud_File_Id_By_Name
        (Location, Options, Stored_Name, Diagnostic);
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
   begin
      if Id'Length = 0 then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String ("pCloud object was not found: " & Stored_Name);
         end if;
         return "";
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Get
           (PCloud_API_URL
              (Options, "getfilelink",
               "fileid=" & Percent_Encode_Query_Component (Id)),
            PCloud_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return "";
            end if;
         else
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            declare
               Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
               Direct_URL : constant String := PCloud_JSON_Field_Value (Response_Body, "url");
               Host : constant String := PCloud_JSON_Array_First_String (Response_Body, "hosts");
               Path : constant String := PCloud_JSON_Field_Value (Response_Body, "path");
            begin
               if Code = 401 or else Code = 403
                 or else PCloud_Authentication_Result (PCloud_Result_Code (Response_Body))
               then
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("getfilelink", Code, Response_Body));
                  return "";
               elsif PCloud_Not_Found_Result (PCloud_Result_Code (Response_Body)) then
                  return "";
               elsif Code = 200 and then PCloud_Result_OK (Response_Body) then
                  if Direct_URL'Length > 0 then
                     return Direct_URL;
                  elsif Host'Length > 0 and then Path'Length > 0 then
                     return (if Starts_With (Host, "127.0.0.1")
                                or else Starts_With (Host, "localhost")
                             then "http://" else "https://") & Host & Path;
                  else
                     Diagnostic := To_Unbounded_String
                       ("pCloud getfilelink response did not contain host/path");
                     return "";
                  end if;
               elsif PCloud_Retryable_Response (Code, Response_Body) and then
                 Backup.Remote_Syntax.Retry_Available
                   (Attempt, Options.Retry_Count)
               then
                  null;
               else
                  Diagnostic := To_Unbounded_String
                    (PCloud_Error_Diagnostic ("getfilelink", Code, Response_Body));
                  return "";
               end if;
            end;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud getfilelink retry loop did not run");
      return "";
   end PCloud_Download_URL_By_Name;

   function PCloud_Download_URL
     (Location    : Remote_Location;
      Object_Name : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return String
   is
   begin
      return PCloud_Download_URL_By_Name
        (Location, PCloud_Name (Location, Object_Name), Options, Diagnostic);
   end PCloud_Download_URL;

   function Download_PCloud_Object_By_Name
     (Location    : Remote_Location;
      Stored_Name : String;
      Local_Path  : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      URL      : constant String := PCloud_Download_URL_By_Name
        (Location, Stored_Name, Options, Diagnostic);
      Download : Http_Client.Clients.Download_Result;
      Status   : Remote_Status;
      Code     : Natural := 0;
   begin
      if URL'Length = 0 then
         if Length (Diagnostic) = 0 then
            return Remote_Not_Found;
         end if;
         return Remote_Read_Failed;
      end if;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := HTTP_Download_To_File
           (URL, Local_Path, Options, Download, Diagnostic);
         if Status /= Remote_Ok then
            if Backup.Remote_Syntax.Retry_Available
              (Attempt, Options.Retry_Count)
            then
               null;
            else
               return Status;
            end if;
         else
            Code := Download.HTTP_Status_Code;
            if Code = 404 then
               return Remote_Not_Found;
            elsif Code = 200 then
               return Remote_Ok;
            elsif PCloud_Retryable_Response (Code) and then
              Backup.Remote_Syntax.Retry_Available
                (Attempt, Options.Retry_Count)
            then
               null;
            else
               Diagnostic := To_Unbounded_String
                 ("pCloud download returned status" & Natural'Image (Code));
               return Remote_Read_Failed;
            end if;
         end if;
      end loop;
      Diagnostic := To_Unbounded_String ("pCloud download retry loop did not run");
      return Remote_Read_Failed;
   end Download_PCloud_Object_By_Name;

   function Download_PCloud_Object
     (Location    : Remote_Location;
      Object_Name : String;
      Local_Path  : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
   begin
      return Download_PCloud_Object_By_Name
        (Location, PCloud_Name (Location, Object_Name), Local_Path,
         Options, Diagnostic);
   end Download_PCloud_Object;

   type File_Slice_Body_Producer is limited new Http_Client.Request_Bodies.Body_Producer
   with record
      File      : Ada.Streams.Stream_IO.File_Type;
      Opened    : Boolean := False;
      Remaining : Natural := 0;
   end record;

   overriding function Read_Some
     (Item   : in out File_Slice_Body_Producer;
      Buffer : out String;
      Count  : out Natural) return Http_Client.Errors.Result_Status;

   overriding function Reset
     (Item : in out File_Slice_Body_Producer) return Http_Client.Errors.Result_Status;

   procedure Open_File_Slice_Response_Text
     (Item   : in out File_Slice_Body_Producer;
      Path   : String;
      Offset : Interfaces.Unsigned_64;
      Length : Natural) is
   begin
      if Item.Opened then
         Ada.Streams.Stream_IO.Close (Item.File);
         Item.Opened := False;
      end if;
      Ada.Streams.Stream_IO.Open
        (Item.File, Ada.Streams.Stream_IO.In_File, Path);
      Ada.Streams.Stream_IO.Set_Index
        (Item.File, Ada.Streams.Stream_IO.Positive_Count (Offset + 1));
      Item.Remaining := Length;
      Item.Opened := True;
   end Open_File_Slice_Response_Text;

   procedure Close_File_Slice_Response_Text (Item : in out File_Slice_Body_Producer) is
   begin
      if Item.Opened then
         Ada.Streams.Stream_IO.Close (Item.File);
         Item.Opened := False;
      end if;
   exception
      when others =>
         Item.Opened := False;
   end Close_File_Slice_Response_Text;

   overriding function Read_Some
     (Item   : in out File_Slice_Body_Producer;
      Buffer : out String;
      Count  : out Natural) return Http_Client.Errors.Result_Status
   is
      use Ada.Streams;
      Wanted : constant Natural := Natural'Min (Buffer'Length, Item.Remaining);
      Raw    : Stream_Element_Array (1 .. Stream_Element_Offset (Natural'Max (Wanted, 1)));
      Last   : Stream_Element_Offset;
   begin
      Count := 0;
      if not Item.Opened then
         return Http_Client.Errors.Body_Producer_Failed;
      elsif Wanted = 0 then
         return Http_Client.Errors.Ok;
      end if;

      Ada.Streams.Stream_IO.Read
        (Item.File, Raw (Raw'First .. Stream_Element_Offset (Wanted)), Last);
      if Last < Raw'First then
         return Http_Client.Errors.Ok;
      end if;
      Count := Natural (Last - Raw'First + 1);
      for Offset in 0 .. Count - 1 loop
         Buffer (Buffer'First + Offset) :=
           Character'Val (Integer (Raw (Raw'First + Stream_Element_Offset (Offset))));
      end loop;
      Item.Remaining := Item.Remaining - Count;
      return Http_Client.Errors.Ok;
   exception
      when others =>
         Count := 0;
         return Http_Client.Errors.Body_Producer_Failed;
   end Read_Some;

   overriding function Reset
     (Item : in out File_Slice_Body_Producer) return Http_Client.Errors.Result_Status
   is
      pragma Unreferenced (Item);
   begin
      return Http_Client.Errors.Body_Not_Replayable;
   end Reset;

   function Stream_HTTP_Put
     (URL          : String;
      Path         : String;
      Length       : Interfaces.Unsigned_64;
      Backup_Crc32 : String;
      Local_Crc32  : Interfaces.Unsigned_32;
      Options      : Remote_Options;
      Result       : out Http_Client.Clients.Client_Result;
      Diagnostic   : out Unbounded_String;
      Sign_S3      : Boolean := False)
      return Remote_Status
   is
      Producer    : aliased File_Body_Producer;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      Request     : Http_Client.Requests.Request;
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Client_Status : Remote_Status;
   begin
      if Length > Interfaces.Unsigned_64 (Natural'Last) then
         Diagnostic := To_Unbounded_String
           ("archive is too large for streaming HTTP upload API: " & Path);
         return Remote_Copy_Failed;
      end if;

      Client_Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Client_Status /= Remote_Ok then
         return Client_Status;
      end if;

      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Type", "application/zip");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         declare
            Auth_Status : Remote_Status;
         begin
            if Sign_S3 then
               Auth_Status := Add_S3_Auth_Headers
                 (Http_Client.Types.PUT, URL, Options, Headers, Diagnostic, True,
                  Backup_Crc32, S3_CRC32_Base64 (Local_Crc32));
            else
               Auth_Status := Add_HTTP_Auth_Headers
                 (Options, Headers, Diagnostic);
            end if;
            if Auth_Status /= Remote_Ok then
               return Auth_Status;
            end if;
         end;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method  => Http_Client.Types.PUT,
            URI     => URI,
            Item    => Request,
            Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         begin
            Open_File_Response_Text (Producer, Path);
         exception
            when others =>
               Diagnostic := To_Unbounded_String
                 ("could not open archive for streaming HTTP upload: " & Path);
               return Remote_Read_Failed;
         end;
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request,
            Http_Client.Request_Bodies.From_Fixed_Length_Stream
              (Producer   => Producer'Unchecked_Access,
               Length     => Natural (Length),
               Replayable => False));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute
           (Client, Request, Result);
      end if;

      Close_File_Response_Text (Producer);
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("HTTP remote streaming upload failed for " & URL);
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   exception
      when others =>
         Close_File_Response_Text (Producer);
         Diagnostic := To_Unbounded_String
           ("HTTP remote streaming upload failed for " & URL);
         return Remote_Copy_Failed;
   end Stream_HTTP_Put;

   function File_Slice_CRC32_Base64
     (Path   : String;
      Offset : Interfaces.Unsigned_64;
      Length : Natural) return String
   is
      File  : Ada.Streams.Stream_IO.File_Type;
      State : CryptoLib.Checksums.CRC32_State;
      Remaining : Natural := Length;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 16_384);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      CryptoLib.Checksums.CRC32_Reset (State);
      Ada.Streams.Stream_IO.Open
        (File, Ada.Streams.Stream_IO.In_File, Path);
      Ada.Streams.Stream_IO.Set_Index
        (File, Ada.Streams.Stream_IO.Positive_Count (Offset + 1));
      while Remaining > 0 loop
         declare
            Wanted : constant Ada.Streams.Stream_Element_Offset :=
              Ada.Streams.Stream_Element_Offset
                (Natural'Min (Remaining, Buffer'Length));
         begin
            Ada.Streams.Stream_IO.Read (File, Buffer (1 .. Wanted), Last);
            exit when Last < Buffer'First;
            CryptoLib.Checksums.CRC32_Update (State, Buffer (Buffer'First .. Last));
            Remaining := Remaining - Natural (Last - Buffer'First + 1);
         end;
      end loop;
      Ada.Streams.Stream_IO.Close (File);
      return S3_CRC32_Base64 (CryptoLib.Checksums.CRC32_Value (State));
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end File_Slice_CRC32_Base64;

   function Stream_HTTP_Put_Slice
     (URL          : String;
      Path         : String;
      Offset       : Interfaces.Unsigned_64;
      Length       : Natural;
      Options      : Remote_Options;
      Result       : out Http_Client.Clients.Client_Result;
      Diagnostic   : out Unbounded_String;
      Sign_S3      : Boolean := False;
      Checksum_CRC32 : String := "")
      return Remote_Status
   is
      Producer    : aliased File_Slice_Body_Producer;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      Request     : Http_Client.Requests.Request;
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Client_Status : Remote_Status;
   begin
      Client_Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Client_Status /= Remote_Ok then
         return Client_Status;
      end if;

      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Type", "application/octet-stream");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         declare
            Auth_Status : Remote_Status;
         begin
            if Sign_S3 then
               Auth_Status := Add_S3_Auth_Headers
                 (Http_Client.Types.PUT, URL, Options, Headers, Diagnostic, False,
                  Checksum_CRC32 => Checksum_CRC32);
            else
               Auth_Status := Add_HTTP_Auth_Headers
                 (Options, Headers, Diagnostic);
            end if;
            if Auth_Status /= Remote_Ok then
               return Auth_Status;
            end if;
         end;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method  => Http_Client.Types.PUT,
            URI     => URI,
            Item    => Request,
            Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         begin
            Open_File_Slice_Response_Text (Producer, Path, Offset, Length);
         exception
            when others =>
               Diagnostic := To_Unbounded_String
                 ("could not open archive slice for HTTP upload: " & Path);
               return Remote_Read_Failed;
         end;
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request,
            Http_Client.Request_Bodies.From_Fixed_Length_Stream
              (Producer   => Producer'Unchecked_Access,
               Length     => Length,
               Replayable => False));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute
           (Client, Request, Result);
      end if;

      Close_File_Slice_Response_Text (Producer);
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("HTTP remote slice upload failed for " & URL);
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   exception
      when others =>
         Close_File_Slice_Response_Text (Producer);
         Diagnostic := To_Unbounded_String
           ("HTTP remote slice upload failed for " & URL);
         return Remote_Copy_Failed;
   end Stream_HTTP_Put_Slice;

   function Stream_HTTP_Put_With_Retry
     (URL        : String;
      Path       : String;
      Length     : Interfaces.Unsigned_64;
      Backup_Crc32 : String;
      Local_Crc32  : Interfaces.Unsigned_32;
      Options    : Remote_Options;
      Report     : in out Transfer_Report;
      Result     : out Http_Client.Clients.Client_Result;
      Diagnostic : out Unbounded_String;
      Sign_S3    : Boolean := False)
      return Remote_Status
   is
      Status : Remote_Status := Remote_Copy_Failed;
      Code   : Natural := 0;
   begin
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Stream_HTTP_Put
           (URL, Path, Length, Backup_Crc32, Local_Crc32, Options, Result, Diagnostic, Sign_S3);
         if Status = Remote_Ok then
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            if HTTP_Status_OK (Code, For_Upload => True) then
               return Remote_Ok;
            end if;

            Diagnostic := To_Unbounded_String
              ("HTTP remote upload returned status" & Natural'Image (Code));
            Status := Remote_Write_Failed;
         end if;

         if Backup.Remote_Syntax.Retry_Available
           (Attempt, Options.Retry_Count)
         then
            Report.Retried := Report.Retried + 1;
         end if;
      end loop;

      return Status;
   end Stream_HTTP_Put_With_Retry;

   function HTTP_Error_Status
     (Status : Http_Client.Errors.Result_Status) return Remote_Status
   is
   begin
      case Status is
         when Http_Client.Errors.Ok =>
            return Remote_Ok;
         when Http_Client.Errors.Timeout | Http_Client.Errors.Cancelled =>
            return Remote_Timeout;
         when Http_Client.Errors.Authentication_Required
            | Http_Client.Errors.Authentication_Failed
            | Http_Client.Errors.Invalid_Credentials =>
            return Remote_Authentication_Failed;
         when Http_Client.Errors.Read_Failed | Http_Client.Errors.Incomplete_Message =>
            return Remote_Read_Failed;
         when Http_Client.Errors.Write_Failed =>
            return Remote_Write_Failed;
         when others =>
            return Remote_Copy_Failed;
      end case;
   end HTTP_Error_Status;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   S3_Minimum_Nonfinal_Part_Size : constant Natural := 5 * 1024 * 1024;
   S3_Maximum_Multipart_Parts    : constant Natural := 10_000;

   function Append_S3_Query (URL : String; Query : String) return String is
   begin
      return URL & "?" & Query;
   end Append_S3_Query;

   function XML_Tag_Value (Text : String; Name : String) return String is
      Open_Tag  : constant String := "<" & Name & ">";
      Close_Tag : constant String := "</" & Name & ">";
      First     : constant Natural := Ada.Strings.Fixed.Index (Text, Open_Tag);
      Last      : Natural;
   begin
      if First = 0 then
         return "";
      end if;
      Last := Ada.Strings.Fixed.Index
        (Text (First + Open_Tag'Length .. Text'Last), Close_Tag);
      if Last = 0 then
         return "";
      end if;
      return Text (First + Open_Tag'Length .. Last - 1);
   end XML_Tag_Value;

   function XML_Block_Value (Text : String; Name : String; Start : Positive) return String is
      Open_Tag  : constant String := "<" & Name & ">";
      Close_Tag : constant String := "</" & Name & ">";
      First     : constant Natural := Ada.Strings.Fixed.Index (Text (Start .. Text'Last), Open_Tag);
      Last      : Natural;
   begin
      if First = 0 then
         return "";
      end if;
      Last := Ada.Strings.Fixed.Index
        (Text (First + Open_Tag'Length .. Text'Last), Close_Tag);
      if Last = 0 then
         return "";
      end if;
      return Text (First .. Last + Close_Tag'Length - 1);
   end XML_Block_Value;

   function Parse_XML_Natural (Text : String; Value : out Natural) return Boolean is
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
      end loop;
      Value := Natural'Value (Text);
      return True;
   exception
      when others =>
         Value := 0;
         return False;
   end Parse_XML_Natural;

   function Parse_XML_U64 (Text : String; Value : out Interfaces.Unsigned_64) return Boolean is
      Accumulated : Interfaces.Unsigned_64 := 0;
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
            Digit : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Character'Pos (Ch) - Character'Pos ('0'));
         begin
            if Accumulated > (Interfaces.Unsigned_64'Last - Digit) / 10 then
               Value := 0;
               return False;
            end if;
            Accumulated := Accumulated * 10 + Digit;
         end;
      end loop;
      Value := Accumulated;
      return True;
   end Parse_XML_U64;

   function Execute_S3_Request
     (Method       : Http_Client.Types.Method_Name;
      URL          : String;
      Options      : Remote_Options;
      Result       : out Http_Client.Clients.Client_Result;
      Diagnostic   : out Unbounded_String;
      Payload      : String := "";
      Content_Type : String := "";
      Include_SSE  : Boolean := False;
      Backup_Crc32 : String := "";
      Checksum_CRC32 : String := "";
      Request_Checksum_Mode : Boolean := False;
      Checksum_Algorithm : String := "") return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Status      : Remote_Status;
   begin
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok and then Content_Type'Length > 0 then
         HTTP_Status := Http_Client.Headers.Set (Headers, "Content-Type", Content_Type);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         Status := Add_S3_Auth_Headers
           (Method, URL, Options, Headers, Diagnostic, Include_SSE, Backup_Crc32,
            Checksum_CRC32, Request_Checksum_Mode, Checksum_Algorithm);
         if Status /= Remote_Ok then
            return Status;
         end if;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method  => Method,
            URI     => URI,
            Item    => Request,
            Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok and then Payload'Length > 0 then
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String (Payload));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("S3 request failed for " & URL);
         return HTTP_Error_Status (HTTP_Status);
      end if;
      return Remote_Ok;
   end Execute_S3_Request;

   function Initiate_S3_Multipart_Upload
     (Object_URL  : String;
      Options     : Remote_Options;
      Backup_Crc32 : String;
      Report      : in out Transfer_Report;
      Upload_Id   : out Unbounded_String;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status := Remote_Write_Failed;
      Code   : Natural := 0;
   begin
      Upload_Id := Null_Unbounded_String;
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Execute_S3_Request
           (Http_Client.Types.POST, Append_S3_Query (Object_URL, "uploads"),
            Options, Result, Diagnostic, Include_SSE => True,
            Backup_Crc32 => Backup_Crc32, Checksum_Algorithm => "CRC32");
         if Status = Remote_Ok then
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            if HTTP_Status_OK (Code, For_Upload => True) then
               Upload_Id := To_Unbounded_String
                 (XML_Tag_Value (Http_Client.Clients.Response_Text (Result), "UploadId"));
               if Ada.Strings.Unbounded.Length (Upload_Id) > 0 then
                  return Remote_Ok;
               end if;
               Diagnostic := To_Unbounded_String
                 ("S3 multipart initiate did not return UploadId");
               Status := Remote_Write_Failed;
            else
               Diagnostic := To_Unbounded_String
                 ("S3 multipart initiate returned status" & Natural'Image (Code));
               Status := Remote_Write_Failed;
            end if;
         end if;

         if Backup.Remote_Syntax.Retry_Available
           (Attempt, Options.Retry_Count)
         then
            Report.Retried := Report.Retried + 1;
         end if;
      end loop;
      return Status;
   end Initiate_S3_Multipart_Upload;

   procedure Abort_S3_Multipart_Upload
     (Object_URL : String;
      Options    : Remote_Options;
      Upload_Id  : String)
   is
      Result     : Http_Client.Clients.Client_Result;
      Diagnostic : Unbounded_String;
      Ignored    : Remote_Status;
   begin
      if Upload_Id'Length = 0 then
         return;
      end if;
      Ignored := Execute_S3_Request
        (Http_Client.Types.DELETE,
         Append_S3_Query
           (Object_URL, "uploadId=" & Percent_Encode_Query_Component (Upload_Id)),
         Options, Result, Diagnostic);
      pragma Unreferenced (Ignored);
   exception
      when others =>
         null;
   end Abort_S3_Multipart_Upload;

   function S3_Multipart_Complete_XML
     (ETags     : String_Vectors.Vector;
      Checksums : String_Vectors.Vector) return String
   is
      Result : Unbounded_String := To_Unbounded_String ("<CompleteMultipartUpload>");
      Part_Number : Positive := 1;
   begin
      for ETag of ETags loop
         Append (Result, "<Part><PartNumber>");
         Append (Result, Decimal_Natural (Part_Number));
         Append (Result, "</PartNumber><ETag>");
         Append (Result, ETag);
         Append (Result, "</ETag>");
         if Checksums.Length >= Ada.Containers.Count_Type (Part_Number)
           and then Checksums.Element (Part_Number)'Length > 0
         then
            Append (Result, "<ChecksumCRC32>");
            Append (Result, Checksums.Element (Part_Number));
            Append (Result, "</ChecksumCRC32>");
         end if;
         Append (Result, "</Part>");
         Part_Number := Part_Number + 1;
      end loop;
      Append (Result, "</CompleteMultipartUpload>");
      return To_String (Result);
   end S3_Multipart_Complete_XML;

   function Complete_S3_Multipart_Upload
     (Object_URL  : String;
      Options     : Remote_Options;
      Upload_Id   : String;
      ETags       : String_Vectors.Vector;
      Checksums   : String_Vectors.Vector;
      Report      : in out Transfer_Report;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status := Remote_Write_Failed;
      Code   : Natural := 0;
      URL    : constant String := Append_S3_Query
        (Object_URL, "uploadId=" & Percent_Encode_Query_Component (Upload_Id));
   begin
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Execute_S3_Request
           (Http_Client.Types.POST, URL, Options, Result, Diagnostic,
            Payload      => S3_Multipart_Complete_XML (ETags, Checksums),
            Content_Type => "application/xml");
         if Status = Remote_Ok then
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            if HTTP_Status_OK (Code, For_Upload => True) then
               return Remote_Ok;
            end if;
            Diagnostic := To_Unbounded_String
              ("S3 multipart complete returned status" & Natural'Image (Code));
            Status := Remote_Write_Failed;
         end if;

         if Backup.Remote_Syntax.Retry_Available
           (Attempt, Options.Retry_Count)
         then
            Report.Retried := Report.Retried + 1;
         end if;
      end loop;
      return Status;
   end Complete_S3_Multipart_Upload;

   function Upload_S3_Multipart_Part_With_Retry
     (Object_URL   : String;
      Local_Path   : String;
      Offset       : Interfaces.Unsigned_64;
      Length       : Natural;
      Part_Number  : Positive;
      Upload_Id    : String;
      Options      : Remote_Options;
      Report       : in out Transfer_Report;
      ETag         : out Unbounded_String;
      Checksum     : out Unbounded_String;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status := Remote_Copy_Failed;
      Code   : Natural := 0;
      URL    : constant String := Append_S3_Query
        (Object_URL,
         "partNumber=" & Decimal_Natural (Part_Number) &
         "&uploadId=" & Percent_Encode_Query_Component (Upload_Id));
      Part_Checksum : constant String := File_Slice_CRC32_Base64 (Local_Path, Offset, Length);
   begin
      ETag := Null_Unbounded_String;
      Checksum := To_Unbounded_String (Part_Checksum);
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         Status := Stream_HTTP_Put_Slice
           (URL, Local_Path, Offset, Length, Options, Result, Diagnostic,
            Sign_S3 => True, Checksum_CRC32 => Part_Checksum);
         if Status = Remote_Ok then
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            if HTTP_Status_OK (Code, For_Upload => True) then
               if Http_Client.Responses.Has_Header (Result.Response, "ETag") then
                  ETag := To_Unbounded_String
                    (Http_Client.Responses.Header (Result.Response, "ETag"));
                  return Remote_Ok;
               else
                  Diagnostic := To_Unbounded_String
                    ("S3 multipart part" & Natural'Image (Part_Number) &
                     " did not return ETag");
                  Status := Remote_Write_Failed;
               end if;
            else
               Diagnostic := To_Unbounded_String
                 ("S3 multipart part" & Natural'Image (Part_Number) &
                  " returned status" & Natural'Image (Code));
               Status := Remote_Write_Failed;
            end if;
         end if;

         if Backup.Remote_Syntax.Retry_Available
           (Attempt, Options.Retry_Count)
         then
            Report.Retried := Report.Retried + 1;
         end if;
      end loop;
      return Status;
   end Upload_S3_Multipart_Part_With_Retry;

   function Find_S3_Multipart_Upload
     (Location   : Remote_Location;
      Options    : Remote_Options;
      Upload_Id  : out Unbounded_String;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Result           : Http_Client.Clients.Client_Result;
      Status           : Remote_Status;
      Code             : Natural := 0;
      Key              : constant String := S3_Key (Location, To_String (Location.Object_Name));
      Bucket_URL       : constant String := S3_Bucket_URL (Location, Options);
      Encoded_Key      : constant String := Percent_Encode_Query_Component (Key);
      Key_Marker       : Unbounded_String;
      Upload_Id_Marker : Unbounded_String;
      Page_Count       : Natural := 0;
   begin
      Upload_Id := Null_Unbounded_String;
      loop
         Page_Count := Page_Count + 1;
         if Page_Count > S3_Maximum_Multipart_Parts then
            Diagnostic := To_Unbounded_String
              ("S3 multipart upload listing pagination did not terminate");
            return Remote_Read_Failed;
         end if;

         declare
            Query : constant String :=
              (if Ada.Strings.Unbounded.Length (Key_Marker) = 0 then "" else
               "key-marker=" & Percent_Encode_Query_Component (To_String (Key_Marker)) & "&") &
              "prefix=" & Encoded_Key & "&" &
              (if Ada.Strings.Unbounded.Length (Upload_Id_Marker) = 0 then "" else
               "upload-id-marker=" &
               Percent_Encode_Query_Component (To_String (Upload_Id_Marker)) & "&") &
              "uploads=";
            URL   : constant String := Append_S3_Query (Bucket_URL, Query);
         begin
            Status := Execute_S3_Request
              (Http_Client.Types.GET, URL, Options, Result, Diagnostic);
         end;
         if Status /= Remote_Ok then
            return Status;
         end if;
         Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
         if Code = 404 then
            return Remote_Ok;
         elsif Code /= 200 then
            Diagnostic := To_Unbounded_String
              ("S3 multipart upload listing returned status" & Natural'Image (Code));
            return Remote_Read_Failed;
         end if;

         declare
            Raw : constant String := Http_Client.Clients.Response_Text (Result);
            Pos : Positive := 1;
         begin
            while Pos <= Raw'Last loop
               declare
                  Block : constant String := XML_Block_Value (Raw, "Upload", Pos);
                  Stop  : Natural;
               begin
                  exit when Block'Length = 0;
                  if XML_Tag_Value (Block, "Key") = Key then
                     Upload_Id := To_Unbounded_String (XML_Tag_Value (Block, "UploadId"));
                     return Remote_Ok;
                  end if;
                  Stop := Ada.Strings.Fixed.Index (Raw (Pos .. Raw'Last), "</Upload>");
                  exit when Stop = 0;
                  Pos := Stop + 9;
               end;
            end loop;

            exit when XML_Tag_Value (Raw, "IsTruncated") /= "true";
            Key_Marker := To_Unbounded_String (XML_Tag_Value (Raw, "NextKeyMarker"));
            Upload_Id_Marker := To_Unbounded_String
              (XML_Tag_Value (Raw, "NextUploadIdMarker"));
            if Ada.Strings.Unbounded.Length (Key_Marker) = 0 then
               Diagnostic := To_Unbounded_String
                 ("S3 multipart upload listing is truncated without NextKeyMarker");
               return Remote_Read_Failed;
            end if;
         end;
      end loop;
      return Remote_Ok;
   end Find_S3_Multipart_Upload;

   function Load_S3_Multipart_Parts
     (Object_URL  : String;
      Options     : Remote_Options;
      Upload_Id   : String;
      Part_Size   : Natural;
      Length      : Interfaces.Unsigned_64;
      ETags       : in out String_Vectors.Vector;
      Checksums   : in out String_Vectors.Vector;
      Offset      : out Interfaces.Unsigned_64;
      Part_Number : out Positive;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Result      : Http_Client.Clients.Client_Result;
      Status      : Remote_Status;
      Code        : Natural := 0;
      Expected    : Positive := 1;
      Part_Marker : Natural := 0;
      Page_Count  : Natural := 0;
   begin
      Offset := 0;
      Part_Number := 1;
      ETags.Clear;
      Checksums.Clear;
      loop
         Page_Count := Page_Count + 1;
         if Page_Count > S3_Maximum_Multipart_Parts then
            Diagnostic := To_Unbounded_String
              ("S3 multipart part listing pagination did not terminate");
            return Remote_Read_Failed;
         end if;

         declare
            Query : constant String :=
              (if Part_Marker = 0 then "" else
               "part-number-marker=" & Decimal_Natural (Part_Marker) & "&") &
              "uploadId=" & Percent_Encode_Query_Component (Upload_Id);
            URL   : constant String := Append_S3_Query (Object_URL, Query);
         begin
            Status := Execute_S3_Request
              (Http_Client.Types.GET, URL, Options, Result, Diagnostic);
         end;
         if Status /= Remote_Ok then
            return Status;
         end if;
         Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
         if Code /= 200 then
            Diagnostic := To_Unbounded_String
              ("S3 multipart part listing returned status" & Natural'Image (Code));
            return Remote_Read_Failed;
         end if;

         declare
            Raw : constant String := Http_Client.Clients.Response_Text (Result);
            Pos : Positive := 1;
         begin
            while Pos <= Raw'Last loop
               declare
                  Block  : constant String := XML_Block_Value (Raw, "Part", Pos);
                  Number : Natural := 0;
                  Size   : Interfaces.Unsigned_64 := 0;
                  ETag   : constant String := XML_Tag_Value (Block, "ETag");
                  Checksum : constant String := XML_Tag_Value (Block, "ChecksumCRC32");
                  Stop   : Natural;
               begin
                  exit when Block'Length = 0;
                  if not Parse_XML_Natural (XML_Tag_Value (Block, "PartNumber"), Number)
                    or else Number /= Expected
                    or else ETag'Length = 0
                    or else not Parse_XML_U64 (XML_Tag_Value (Block, "Size"), Size)
                    or else Size = 0
                    or else Offset + Size > Length
                    or else (Offset + Size < Length and then Size /= Interfaces.Unsigned_64 (Part_Size))
                  then
                     Diagnostic := To_Unbounded_String
                       ("S3 multipart part listing is not resumable");
                     return Remote_Read_Failed;
                  end if;

                  ETags.Append (ETag);
                  Checksums.Append (Checksum);
                  Offset := Offset + Size;
                  Expected := Expected + 1;
                  Part_Marker := Number;
                  exit when Offset = Length;
                  Stop := Ada.Strings.Fixed.Index (Raw (Pos .. Raw'Last), "</Part>");
                  exit when Stop = 0;
                  Pos := Stop + 7;
               end;
            end loop;

            exit when Offset = Length;
            exit when XML_Tag_Value (Raw, "IsTruncated") /= "true";
            declare
               Marker : Natural := 0;
            begin
               if not Parse_XML_Natural
                   (XML_Tag_Value (Raw, "NextPartNumberMarker"), Marker)
                 or else Marker < Part_Marker
               then
                  Diagnostic := To_Unbounded_String
                    ("S3 multipart part listing is truncated without a valid NextPartNumberMarker");
                  return Remote_Read_Failed;
               end if;
               Part_Marker := Marker;
            end;
         end;
      end loop;
      Part_Number := Expected;
      return Remote_Ok;
   end Load_S3_Multipart_Parts;

   function Stream_S3_Multipart_Upload
     (Location    : Remote_Location;
      Object_URL  : String;
      Local_Path  : String;
      Length      : Interfaces.Unsigned_64;
      Backup_Crc32 : String;
      Options     : Remote_Options;
      Report      : in out Transfer_Report;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Upload_Id   : Unbounded_String;
      ETags       : String_Vectors.Vector;
      Checksums   : String_Vectors.Vector;
      Offset      : Interfaces.Unsigned_64 := 0;
      Part_Number : Positive := 1;
      Part_Size   : constant Natural := Natural'Max (1, Options.S3_Multipart_Part_Size);
      Status      : Remote_Status;
      Part_Count  : Interfaces.Unsigned_64;
      Preserve_On_Failure : constant Boolean := Resume_Upload_Enabled (Options.Upload_Behavior);
   begin
      if Length > Interfaces.Unsigned_64 (Part_Size)
        and then Part_Size < S3_Minimum_Nonfinal_Part_Size
      then
         Diagnostic := To_Unbounded_String
           ("S3 multipart part size must be at least 5242880 bytes when more than one part is needed");
         return Remote_Invalid_URL;
      end if;

      Part_Count := (Length + Interfaces.Unsigned_64 (Part_Size) - 1) /
        Interfaces.Unsigned_64 (Part_Size);
      if Part_Count > Interfaces.Unsigned_64 (S3_Maximum_Multipart_Parts) then
         Diagnostic := To_Unbounded_String
           ("S3 multipart upload would exceed 10000 parts; increase s3_multipart_part_size");
         return Remote_Invalid_URL;
      end if;

      if Resume_Upload_Enabled (Options.Upload_Behavior) then
         Status := Find_S3_Multipart_Upload
           (Location, Options, Upload_Id, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         elsif Ada.Strings.Unbounded.Length (Upload_Id) > 0 then
            Report.Resumed := True;
            Status := Load_S3_Multipart_Parts
              (Object_URL, Options, To_String (Upload_Id), Part_Size, Length,
               ETags, Checksums, Offset, Part_Number, Diagnostic);
            if Status /= Remote_Ok then
               return Status;
            end if;
         end if;
      end if;

      if Ada.Strings.Unbounded.Length (Upload_Id) = 0 then
         Status := Initiate_S3_Multipart_Upload
           (Object_URL, Options, Backup_Crc32, Report, Upload_Id, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
      end if;

      while Offset < Length loop
         declare
            Remaining : constant Interfaces.Unsigned_64 := Length - Offset;
            This_Size : constant Natural :=
              (if Remaining > Interfaces.Unsigned_64 (Part_Size)
               then Part_Size
               else Natural (Remaining));
            ETag      : Unbounded_String;
            Checksum  : Unbounded_String;
         begin
            Status := Upload_S3_Multipart_Part_With_Retry
              (Object_URL, Local_Path, Offset, This_Size, Part_Number,
               To_String (Upload_Id), Options, Report, ETag, Checksum, Diagnostic);
            if Status /= Remote_Ok then
               if not Preserve_On_Failure then
                  Abort_S3_Multipart_Upload (Object_URL, Options, To_String (Upload_Id));
               end if;
               return Status;
            end if;
            ETags.Append (To_String (ETag));
            Checksums.Append (To_String (Checksum));
            Offset := Offset + Interfaces.Unsigned_64 (This_Size);
            if Offset < Length then
               Part_Number := Part_Number + 1;
            end if;
         end;
      end loop;

      Status := Complete_S3_Multipart_Upload
        (Object_URL, Options, To_String (Upload_Id), ETags, Checksums, Report,
         Diagnostic);
      if Status /= Remote_Ok and then not Preserve_On_Failure then
         Abort_S3_Multipart_Upload (Object_URL, Options, To_String (Upload_Id));
      end if;
      return Status;
   exception
      when others =>
         if not Preserve_On_Failure then
            Abort_S3_Multipart_Upload (Object_URL, Options, To_String (Upload_Id));
         end if;
         Diagnostic := To_Unbounded_String ("S3 multipart upload failed for " & Object_URL);
         return Remote_Copy_Failed;
   end Stream_S3_Multipart_Upload;

   function Parse_U64
     (Text  : String;
      Value : out Interfaces.Unsigned_64) return Boolean
   is
      Accumulated : Interfaces.Unsigned_64 := 0;
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
            Digit : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64
                (Character'Pos (Ch) - Character'Pos ('0'));
         begin
            if Accumulated > (Interfaces.Unsigned_64'Last - Digit) / 10 then
               Value := 0;
               return False;
            end if;
            Accumulated := Accumulated * 10 + Digit;
         end;
      end loop;

      Value := Accumulated;
      return True;
   end Parse_U64;

   function Parse_U32
     (Text  : String;
      Value : out Interfaces.Unsigned_32) return Boolean
   is
      Wide : Interfaces.Unsigned_64;
   begin
      if not Parse_U64 (Text, Wide)
        or else Wide > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
      then
         Value := 0;
         return False;
      end if;

      Value := Interfaces.Unsigned_32 (Wide);
      return True;
   end Parse_U32;

   function Parse_Natural_Range
     (Text  : String;
      Low   : Natural;
      High  : Natural;
      Value : out Natural) return Boolean
   is
      Wide : Interfaces.Unsigned_64;
   begin
      if not Parse_U64 (Text, Wide)
        or else Wide < Interfaces.Unsigned_64 (Low)
        or else Wide > Interfaces.Unsigned_64 (High)
      then
         Value := 0;
         return False;
      end if;

      Value := Natural (Wide);
      return True;
   end Parse_Natural_Range;

   function Parse_Index_Timestamp
     (Text      : String;
      Has_Value : out Boolean;
      Value     : out Ada.Calendar.Time) return Boolean
   is
      Year   : Natural;
      Month  : Natural;
      Day    : Natural;
      Hour   : Natural;
      Minute : Natural;
      Second : Natural;
   begin
      Has_Value := False;
      Value := Ada.Calendar.Time_Of (2000, 1, 1);

      if Text = "-" then
         return True;
      end if;

      if Text'Length /= 20
        or else Text (Text'First + 4) /= '-'
        or else Text (Text'First + 7) /= '-'
        or else Text (Text'First + 10) /= 'T'
        or else Text (Text'First + 13) /= ':'
        or else Text (Text'First + 16) /= ':'
        or else Text (Text'First + 19) /= 'Z'
      then
         return False;
      end if;

      if not Parse_Natural_Range
          (Text (Text'First .. Text'First + 3), 1901, 2399, Year)
        or else not Parse_Natural_Range
          (Text (Text'First + 5 .. Text'First + 6), 1, 12, Month)
        or else not Parse_Natural_Range
          (Text (Text'First + 8 .. Text'First + 9), 1, 31, Day)
        or else not Parse_Natural_Range
          (Text (Text'First + 11 .. Text'First + 12), 0, 23, Hour)
        or else not Parse_Natural_Range
          (Text (Text'First + 14 .. Text'First + 15), 0, 59, Minute)
        or else not Parse_Natural_Range
          (Text (Text'First + 17 .. Text'First + 18), 0, 59, Second)
      then
         return False;
      end if;

      Value := Ada.Calendar.Time_Of
        (Year, Month, Day,
         Duration (Hour * 3_600 + Minute * 60 + Second));
      Has_Value := True;
      return True;
   exception
      when others =>
         Has_Value := False;
         Value := Ada.Calendar.Time_Of (2000, 1, 1);
         return False;
   end Parse_Index_Timestamp;

   function Split_Tab (Line : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      Start  : Integer := Line'First;
   begin
      for Index in Line'Range loop
         if Line (Index) = Ada.Characters.Latin_1.HT then
            Result.Append (Line (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      Result.Append (Line (Start .. Line'Last));
      return Result;
   end Split_Tab;

   function Read_HTTP_Inventory
     (Location   : Remote_Location;
      Inventory  : in out Archive_Metadata_Vectors.Vector;
      Validator  : out HTTP_Index_Validator;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status;

   function Publish_HTTP_Index
     (Location   : Remote_Location;
      Inventory  : Archive_Metadata_Vectors.Vector;
      Validator  : HTTP_Index_Validator;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return HTTP_Index_Publish_Result;

   procedure Upsert_HTTP_Index_Item
     (Inventory : in out Archive_Metadata_Vectors.Vector;
      Item      : Archive_Metadata);

   procedure Remove_HTTP_Index_Item
     (Inventory : in out Archive_Metadata_Vectors.Vector;
      Name      : String);

   function Upsert_HTTP_Index
     (Location   : Remote_Location;
      Item       : Archive_Metadata;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status;

   function Remove_HTTP_Index
     (Location    : Remote_Location;
      Object_Name : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status;

   function Parse_HTTP_Index
     (Text       : String;
      Inventory  : in out Archive_Metadata_Vectors.Vector;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Header_Seen : Boolean := False;
      Line_Number : Natural := 0;
      OK          : Boolean := True;

      procedure Parse_Line (Line : String) is
      begin
         Line_Number := Line_Number + 1;

         if Line_Number = 1 then
            if Line /= "backup-remote-index-v1" then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote index has unsupported format header");
               OK := False;
            else
               Header_Seen := True;
            end if;
            return;
         end if;

         if Line'Length = 0 or else Line (Line'First) = '#' then
            return;
         end if;

         declare
            Fields : constant String_Vectors.Vector := Split_Tab (Line);
            Name   : constant String := Fields.Element (1);
            Size   : Interfaces.Unsigned_64;
            Crc32  : Interfaces.Unsigned_32;
            Has_Timestamp : Boolean;
            Timestamp     : Ada.Calendar.Time;
            Partial       : constant Boolean := Ends_With (Name, ".partial");
         begin
            if Fields.Length /= 4 then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote index line" & Natural'Image (Line_Number) &
                  " must contain 4 tab-separated fields");
               OK := False;
               return;
            end if;

            if not Backup.Path_Syntax.Looks_Like_Managed_Object (Name) then
               return;
            end if;

            if not Backup.Path_Syntax.Safe_Object_Name (Name) then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote index line" & Natural'Image (Line_Number) &
                  " contains an unsafe object name");
               OK := False;
               return;
            end if;

            if not Parse_U64 (Fields.Element (2), Size)
              or else not Parse_U32 (Fields.Element (3), Crc32)
              or else not Parse_Index_Timestamp
                (Fields.Element (4), Has_Timestamp, Timestamp)
            then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote index line" & Natural'Image (Line_Number) &
                  " contains invalid metadata");
               OK := False;
               return;
            end if;

            Inventory.Append
              (Archive_Metadata'
                 (Archive_Id     => To_Unbounded_String (Name),
                  Size           => Size,
                  Crc32          => Crc32,
                  Has_Timestamp  => Has_Timestamp,
                  Timestamp      => Timestamp,
                  Managed        => True,
                  Partial        => Partial));
         end;
      end Parse_Line;

      Line_Start : Integer;
      Line_End   : Integer;
      Raw_End    : Integer;
   begin
      if Text'Length = 0 then
         Diagnostic := To_Unbounded_String ("HTTP remote index is empty");
         return Remote_Read_Failed;
      end if;

      Line_Start := Text'First;
      while OK and then Line_Start <= Text'Last loop
         Line_End := Line_Start;
         while Line_End <= Text'Last
           and then Text (Line_End) /= Ada.Characters.Latin_1.LF
         loop
            Line_End := Line_End + 1;
         end loop;

         Raw_End := Line_End - 1;
         if Raw_End >= Line_Start
           and then Text (Raw_End) = Ada.Characters.Latin_1.CR
         then
            Raw_End := Raw_End - 1;
         end if;

         declare
            Line : constant String :=
              (if Raw_End >= Line_Start
               then Text (Line_Start .. Raw_End)
               else "");
         begin
            Parse_Line (Line);
         end;

         Line_Start := Line_End + 1;
      end loop;

      if not OK then
         return Remote_Read_Failed;
      elsif not Header_Seen then
         Diagnostic := To_Unbounded_String ("HTTP remote index is empty");
         return Remote_Read_Failed;
      end if;

      return Remote_Ok;
   end Parse_HTTP_Index;

   function S3_List_Prefix (Location : Remote_Location) return String is
      Prefix : constant String := S3_Prefix (Location);
   begin
      if Prefix'Length = 0 then
         return "";
      elsif Ends_With (Prefix, "/") then
         return Prefix;
      else
         return Prefix & "/";
      end if;
   end S3_List_Prefix;

   function S3_Object_Name_From_Key
     (Location : Remote_Location;
      Key      : String) return String
   is
      Prefix : constant String := S3_List_Prefix (Location);
      Name_First : Natural;
   begin
      if Prefix'Length = 0 then
         Name_First := Key'First;
      elsif Key'Length > Prefix'Length
        and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix
      then
         Name_First := Key'First + Prefix'Length;
      else
         return "";
      end if;

      declare
         Name : constant String := Key (Name_First .. Key'Last);
      begin
         for Ch of Name loop
            if Ch = '/' or else Ch = '\' then
               return "";
            end if;
         end loop;
         return Name;
      end;
   exception
      when others =>
         return "";
   end S3_Object_Name_From_Key;

   function Parse_S3_Last_Modified
     (Text      : String;
      Has_Value : out Boolean;
      Value     : out Ada.Calendar.Time) return Boolean
   is
   begin
      if Text'Length >= 20
        and then Text (Text'First + 19) = 'Z'
      then
         return Parse_Index_Timestamp
           (Text (Text'First .. Text'First + 19), Has_Value, Value);
      elsif Text'Length > 20 then
         declare
            Trimmed : String (1 .. 20);
         begin
            Trimmed (1 .. 19) := Text (Text'First .. Text'First + 18);
            Trimmed (20) := 'Z';
            return Parse_Index_Timestamp (Trimmed, Has_Value, Value);
         end;
      else
         Has_Value := False;
         Value := Ada.Calendar.Time_Of (2000, 1, 1);
         return False;
      end if;
   exception
      when others =>
         Has_Value := False;
         Value := Ada.Calendar.Time_Of (2000, 1, 1);
         return False;
   end Parse_S3_Last_Modified;


   function Read_S3_Object_Metadata_Crc32
     (Location : Remote_Location;
      Options  : Remote_Options;
      Name     : String) return Interfaces.Unsigned_32
   is
      Result     : Http_Client.Clients.Client_Result;
      Diagnostic : Unbounded_String;
      Status     : Remote_Status;
      Code       : Natural := 0;
      Crc32      : Interfaces.Unsigned_32 := 0;
   begin
      Status := Execute_S3_Request
        (Http_Client.Types.HEAD, S3_Object_URL (Location, Options, Name),
         Options, Result, Diagnostic, Request_Checksum_Mode => True);
      if Status /= Remote_Ok then
         return 0;
      end if;

      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code /= 200 then
         return 0;
      end if;

      if Parse_U32
          (Http_Client.Responses.Header
             (Result.Response, "x-amz-meta-backup-crc32"),
           Crc32)
      then
         return Crc32;
      end if;
      return 0;
   exception
      when others =>
         return 0;
   end Read_S3_Object_Metadata_Crc32;

   function Read_S3_ListObjectsV2_Inventory
     (Location   : Remote_Location;
      Inventory  : in out Archive_Metadata_Vectors.Vector;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Result             : Http_Client.Clients.Client_Result;
      Status             : Remote_Status;
      Code               : Natural := 0;
      Bucket_URL         : constant String := S3_Bucket_URL (Location, Options);
      Prefix             : constant String := S3_List_Prefix (Location);
      Continuation_Token : Unbounded_String;
      Page_Count         : Natural := 0;
   begin
      loop
         Page_Count := Page_Count + 1;
         if Page_Count > 10_000 then
            Diagnostic := To_Unbounded_String
              ("S3 object listing pagination did not terminate");
            return Remote_Read_Failed;
         end if;

         declare
            Query : constant String :=
              "list-type=2" &
              (if Prefix'Length = 0 then "" else
               "&prefix=" & Percent_Encode_Query_Component (Prefix)) &
              (if Length (Continuation_Token) = 0 then "" else
               "&continuation-token=" &
               Percent_Encode_Query_Component (To_String (Continuation_Token)));
            URL   : constant String := Append_S3_Query (Bucket_URL, Query);
         begin
            Status := Execute_S3_Request
              (Http_Client.Types.GET, URL, Options, Result, Diagnostic);
         end;

         if Status /= Remote_Ok then
            return Status;
         end if;
         Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
         if Code = 404 then
            return Remote_Ok;
         elsif Code = 401 or else Code = 403 then
            Diagnostic := To_Unbounded_String
              ("S3 object listing authentication failed with status" &
               Natural'Image (Code));
            return Remote_Authentication_Failed;
         elsif Code /= 200 then
            Diagnostic := To_Unbounded_String
              ("S3 object listing returned status" & Natural'Image (Code));
            return Remote_Read_Failed;
         end if;

         declare
            Raw : constant String := Http_Client.Clients.Response_Text (Result);
            Pos : Positive := 1;
         begin
            while Pos <= Raw'Last loop
               declare
                  Block : constant String := XML_Block_Value (Raw, "Contents", Pos);
                  Stop  : Natural;
               begin
                  exit when Block'Length = 0;
                  declare
                     Key  : constant String := XML_Tag_Value (Block, "Key");
                     Name : constant String := S3_Object_Name_From_Key (Location, Key);
                     Size : Interfaces.Unsigned_64 := 0;
                     Has_Timestamp : Boolean := False;
                     Timestamp : Ada.Calendar.Time := Ada.Calendar.Time_Of (2000, 1, 1);
                     Partial : constant Boolean := Ends_With (Name, ".partial");
                  begin
                     if Name'Length > 0
                       and then Backup.Path_Syntax.Looks_Like_Managed_Object (Name)
                       and then Backup.Path_Syntax.Safe_Object_Name (Name)
                       and then Parse_XML_U64 (XML_Tag_Value (Block, "Size"), Size)
                     then
                        declare
                           Ignored : constant Boolean := Parse_S3_Last_Modified
                             (XML_Tag_Value (Block, "LastModified"),
                              Has_Timestamp, Timestamp);
                        begin
                           pragma Unreferenced (Ignored);
                        end;
                        Inventory.Append
                          (Archive_Metadata'
                             (Archive_Id     => To_Unbounded_String (Name),
                              Size           => Size,
                              Crc32          => Read_S3_Object_Metadata_Crc32
                                (Location, Options, Name),
                              Has_Timestamp  => Has_Timestamp,
                              Timestamp      => Timestamp,
                              Managed        => True,
                              Partial        => Partial));
                     end if;
                  end;
                  Stop := Ada.Strings.Fixed.Index (Raw (Pos .. Raw'Last), "</Contents>");
                  exit when Stop = 0;
                  Pos := Stop + 11;
               end;
            end loop;

            exit when XML_Tag_Value (Raw, "IsTruncated") /= "true";
            Continuation_Token := To_Unbounded_String
              (XML_Tag_Value (Raw, "NextContinuationToken"));
            if Length (Continuation_Token) = 0 then
               Diagnostic := To_Unbounded_String
                 ("S3 object listing is truncated without NextContinuationToken");
               return Remote_Read_Failed;
            end if;
         end;
      end loop;
      return Remote_Ok;
   end Read_S3_ListObjectsV2_Inventory;

   function Read_HTTP_Inventory
     (Location   : Remote_Location;
      Inventory  : in out Archive_Metadata_Vectors.Vector;
      Validator  : out HTTP_Index_Validator;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Result      : Http_Client.Clients.Client_Result;
      Code        : Natural := 0;
   begin
      Validator := (Found => False, Has_ETag => False, ETag => <>);
      if Location.Kind = Transport_Google_Drive then
         declare
            Id : constant String := Google_Drive_File_Id
              (Location, Options, "backup-remote-index-v1", Diagnostic);
            Fetch_Status : Remote_Status;
         begin
            if Id'Length = 0 then
               return Remote_Ok;
            end if;
            Fetch_Status := HTTP_Get
              (Google_Drive_API_Base (Options) & "/files/" &
               Percent_Encode_Query_Component (Id) & "?alt=media",
               Google_Drive_HTTP_Options (Options, Diagnostic), Result, Diagnostic);
            if Fetch_Status /= Remote_Ok then
               Diagnostic := To_Unbounded_String
                 ("Google Drive inventory fetch failed");
               return Fetch_Status;
            end if;
         end;
      elsif Location.Kind = Transport_PCloud then
         declare
            URL : constant String := PCloud_Download_URL
              (Location, "backup-remote-index-v1", Options, Diagnostic);
            Fetch_Status : Remote_Status;
         begin
            if URL'Length = 0 then
               if Length (Diagnostic) = 0
                 or else Ada.Strings.Fixed.Index
                   (To_String (Diagnostic), "was not found") > 0
               then
                  Diagnostic := Null_Unbounded_String;
                  return Remote_Ok;
               end if;
               return Remote_Read_Failed;
            end if;
            Fetch_Status := HTTP_Get (URL, Options, Result, Diagnostic);
            if Fetch_Status /= Remote_Ok then
               Diagnostic := To_Unbounded_String ("pCloud inventory fetch failed");
               return Fetch_Status;
            end if;
         end;
      else
         declare
            Fetch_Status : constant Remote_Status :=
              HTTP_Get
                (Remote_Index_URL (Location, Options), Options, Result, Diagnostic,
                 Location.Kind = Transport_S3);
         begin
            if Fetch_Status /= Remote_Ok then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote inventory fetch failed for " &
                  Remote_Index_URL (Location, Options));
               return Fetch_Status;
            end if;
         end;
      end if;

      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code = 404 then
         if Location.Kind = Transport_S3 then
            return Read_S3_ListObjectsV2_Inventory
              (Location, Inventory, Options, Diagnostic);
         end if;
         return Remote_Ok;
      elsif Code = 401 or else Code = 403 then
         Diagnostic := To_Unbounded_String
           ("HTTP remote inventory authentication failed with status" &
            Natural'Image (Code));
         return Remote_Authentication_Failed;
      elsif Code /= 200 then
         Diagnostic := To_Unbounded_String
           ("HTTP remote inventory returned status" & Natural'Image (Code));
         return Remote_Read_Failed;
      end if;

      Validator.Found := True;
      if Http_Client.Responses.Has_Header (Result.Response, "ETag") then
         Validator.Has_ETag := True;
         Validator.ETag := To_Unbounded_String
           (Http_Client.Responses.Header (Result.Response, "ETag"));
      end if;

      return Parse_HTTP_Index
        (Http_Client.Clients.Response_Text (Result), Inventory, Diagnostic);
   end Read_HTTP_Inventory;

   function Read_HTTP_Inventory
     (Location   : Remote_Location;
      Inventory  : in out Archive_Metadata_Vectors.Vector;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Validator : HTTP_Index_Validator;
   begin
      return Read_HTTP_Inventory
        (Location, Inventory, Validator, Options, Diagnostic);
   end Read_HTTP_Inventory;

   function Archive_Id_For_Path (Path : String) return String is
   begin
      return Basename (Path);
   end Archive_Id_For_Path;

   function Parse_URL
     (URL        : String;
      Local_Path : String;
      Location   : out Remote_Location;
      Diagnostic : out Unbounded_String)
      return Remote_Status
   is
      Remainder : Unbounded_String;
      Name      : Unbounded_String;
      Slash     : Natural := 0;
      Is_Dir    : Boolean := False;
   begin
      Diagnostic := Null_Unbounded_String;
      Location := (Original_URL => To_Unbounded_String (URL),
                   Kind         => Transport_Unsupported,
                   Namespace    => Null_Unbounded_String,
                   Object_Name  => Null_Unbounded_String);

      if URL'Length = 0 then
         Diagnostic := To_Unbounded_String ("remote URL must not be empty");
         return Remote_Invalid_URL;
      elsif Starts_With (URL, "file://") then
         Location.Kind := Transport_File;
         Remainder := To_Unbounded_String (URL (URL'First + 7 .. URL'Last));
      elsif Starts_With (URL, "http://") then
         Location.Kind := Transport_HTTP;
         Remainder := To_Unbounded_String (URL);
      elsif Starts_With (URL, "https://") then
         Location.Kind := Transport_HTTPS;
         Remainder := To_Unbounded_String (URL);
      elsif Starts_With (URL, "s3://") then
         Location.Kind := Transport_S3;
         Remainder := To_Unbounded_String (URL);
      elsif Starts_With (URL, "gdrive://") or else Starts_With (URL, "google-drive://") then
         Location.Kind := Transport_Google_Drive;
         Remainder := To_Unbounded_String (URL);
      elsif Starts_With (URL, "pcloud://") then
         Location.Kind := Transport_PCloud;
         Remainder := To_Unbounded_String (URL);
      elsif Starts_With (URL, "protondrive://") or else Starts_With (URL, "proton-drive://") then
         Location.Kind := Transport_Proton_Drive;
         Remainder := To_Unbounded_String (URL);
      elsif Starts_With (URL, "ssh://") or else Ada.Strings.Fixed.Index (URL, ":") > 0 then
         Location.Kind := Transport_SSH;
         Remainder := To_Unbounded_String (URL);
      else
         Diagnostic := To_Unbounded_String ("unsupported remote URL: " & URL);
         return Remote_Unsupported_Transport;
      end if;

      declare
         Text : constant String := To_String (Remainder);
      begin
         Is_Dir := Text'Length > 0 and then (Text (Text'Last) = '/' or else Text (Text'Last) = '\');
         if Is_Dir then
            Location.Namespace := Remainder;
            Name := To_Unbounded_String (Basename (Local_Path));
         else
            for Index in reverse Text'Range loop
               if Text (Index) = '/' or else Text (Index) = '\' then
                  Slash := Index;
                  exit;
               end if;
            end loop;
            if Slash = 0 then
               Location.Namespace := To_Unbounded_String (".");
               Name := To_Unbounded_String (Text);
            else
               Location.Namespace := To_Unbounded_String (Text (Text'First .. Slash - 1));
               Name := To_Unbounded_String (Text (Slash + 1 .. Text'Last));
            end if;
         end if;
      end;

      if not Backup.Path_Syntax.Safe_Object_Name (To_String (Name)) then
         Diagnostic := To_Unbounded_String
           ("remote archive object name is unsafe: '" & To_String (Name) & "'");
         return Remote_Unsafe_Namespace;
      end if;
      Location.Object_Name := Name;
      return Remote_Ok;
   end Parse_URL;

   function File_Metadata
     (Path       : String;
      Managed    : Boolean;
      Partial    : Boolean;
      Metadata   : out Archive_Metadata;
      Diagnostic : out Unbounded_String)
      return Remote_Status
   is
      Crc  : Interfaces.Unsigned_32 := 0;
      Size : Interfaces.Unsigned_64 := 0;
      Result : constant Backup.Zip.Write_Result :=
        Backup.Zip.Analyze_File
          (Backup.Paths.Normalize_File_System_Path (Path), Crc, Size);
   begin
      if Result /= Backup.Zip.Write_Ok then
         Diagnostic := To_Unbounded_String ("could not analyze archive metadata: " & Path);
         return Remote_Read_Failed;
      end if;
      Metadata := (Archive_Id     => To_Unbounded_String (Archive_Id_For_Path (Path)),
                   Size           => Size,
                   Crc32          => Crc,
                   Has_Timestamp  => Ada.Directories.Exists (Path),
                   Timestamp      => (if Ada.Directories.Exists (Path)
                                      then Ada.Directories.Modification_Time (Path)
                                      else Ada.Calendar.Time_Of (2000, 1, 1)),
                   Managed        => Managed,
                   Partial        => Partial);
      return Remote_Ok;
   end File_Metadata;

   procedure Ensure_Namespace (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Namespace;

   procedure Delete_If_Exists (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Delete_If_Exists;


   function SSH_Status
     (Status   : CryptoLib.Errors.Status;
      Fallback : Remote_Status) return Remote_Status
   is
   begin
      case Status is
         when CryptoLib.Errors.Ok =>
            return Remote_Ok;
         when CryptoLib.Errors.Invalid_Host
            | CryptoLib.Errors.Invalid_Port
            | CryptoLib.Errors.Invalid_User
            | CryptoLib.Errors.Invalid_Command =>
            return Remote_Invalid_URL;
         when CryptoLib.Errors.DNS_Failed
            | CryptoLib.Errors.Connection_Failed
            | CryptoLib.Errors.Handshake_Failed
            | CryptoLib.Errors.Channel_Open_Failed
            | CryptoLib.Errors.Channel_Request_Failed =>
            return Remote_Open_Failed;
         when CryptoLib.Errors.Host_Key_Unknown
            | CryptoLib.Errors.Host_Key_Mismatch
            | CryptoLib.Errors.Authentication_Failed =>
            return Remote_Authentication_Failed;
         when CryptoLib.Errors.Timeout =>
            return Remote_Timeout;
         when CryptoLib.Errors.Cancelled =>
            return Remote_Interrupted;
         when CryptoLib.Errors.No_Such_File =>
            return Remote_Not_Found;
         when CryptoLib.Errors.Read_Failed
            | CryptoLib.Errors.End_Of_Stream =>
            return Remote_Read_Failed;
         when CryptoLib.Errors.Write_Failed =>
            return Remote_Write_Failed;
         when CryptoLib.Errors.Unsupported_Feature =>
            return Remote_Unsupported_Transport;
         when CryptoLib.Errors.Permission_Denied
            | CryptoLib.Errors.Remote_Failure
            | CryptoLib.Errors.Remote_Exit_Nonzero
            | CryptoLib.Errors.Internal_Error =>
            return Fallback;
      end case;
   end SSH_Status;

   function SSH_Status_Image (Status : CryptoLib.Errors.Status) return String is
   begin
      return CryptoLib.Errors.Status'Image (Status);
   end SSH_Status_Image;

   function SSH_Timeout_Milliseconds (Timeout_Seconds : Natural) return Natural is
   begin
      if Timeout_Seconds > Natural'Last / 1_000 then
         return Natural'Last;
      end if;
      return Timeout_Seconds * 1_000;
   end SSH_Timeout_Milliseconds;

   function SSH_Transfer_Options
     (Options           : Remote_Options;
      Use_Atomic_Upload : Boolean := False)
      return SSH_Lib.SFTP.Transfer_Options
   is
   begin
      return SSH_Lib.File_Transfer.SFTP_Transfer_Options
        (Retry_Count   => Options.Retry_Count,
         Atomic_Upload => Use_Atomic_Upload);
   end SSH_Transfer_Options;

   function Open_SSH_Session
     (Remote_Text : String;
      Options     : Remote_Options;
      Session     : out SSH_Lib.Sessions.Session;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Config          : constant SSH_Lib.Config.Host_Config :=
        SSH_Lib.Config.Load_Default;
      Session_Options : SSH_Lib.Sessions.Session_Options;
      Status_Value    : CryptoLib.Errors.Status;
      Timeout_MS      : constant Natural :=
        SSH_Timeout_Milliseconds (Options.Timeout_Seconds);
   begin
      Status_Value := SSH_Lib.Config.Resolve_Remote
        (Config, Remote_Text, "", Session_Options);
      if Status_Value /= CryptoLib.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("SSH remote configuration failed for " & Remote_Text & ": " &
            SSH_Status_Image (Status_Value));
         return SSH_Status (Status_Value, Remote_Open_Failed);
      end if;

      Session_Options.Connect_Timeout_MS := Timeout_MS;
      Session_Options.Read_Timeout_MS := Timeout_MS;
      Session_Options.Write_Timeout_MS := Timeout_MS;

      Status_Value := SSH_Lib.Sessions.Open (Session_Options, Session);
      if Status_Value /= CryptoLib.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("SSH session open failed for " & Remote_Text & ": " &
            SSH_Status_Image (Status_Value));
         return SSH_Status (Status_Value, Remote_Open_Failed);
      end if;

      return Remote_Ok;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("SSH session open failed for " & Remote_Text);
         return Remote_Open_Failed;
   end Open_SSH_Session;

   function SSH_Repository_Path
     (Remote_Text : String;
      Remote_Path : out Unbounded_String;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Parsed       : SSH_Lib.Remote_Names.Parsed_Remote;
      Status_Value : CryptoLib.Errors.Status;
   begin
      Remote_Path := Null_Unbounded_String;
      Status_Value := SSH_Lib.Remote_Names.Parse (Remote_Text, Parsed);
      if Status_Value /= CryptoLib.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("invalid SSH remote name " & Remote_Text & ": " &
            SSH_Status_Image (Status_Value));
         return SSH_Status (Status_Value, Remote_Invalid_URL);
      end if;

      Remote_Path := To_Unbounded_String
        (SSH_Lib.Remote_Names.Repository_Path (Parsed));
      return Remote_Ok;
   exception
      when others =>
         Remote_Path := Null_Unbounded_String;
         Diagnostic := To_Unbounded_String
           ("invalid SSH remote name " & Remote_Text);
         return Remote_Invalid_URL;
   end SSH_Repository_Path;

   function SSH_URL_Is_Directory (URL : String) return Boolean is
   begin
      return URL'Length > 0
        and then (URL (URL'Last) = '/' or else URL (URL'Last) = '\');
   end SSH_URL_Is_Directory;

   function SSH_Object_Path
     (Location    : Remote_Location;
      Remote_Path : out Unbounded_String;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Status : Remote_Status;
   begin
      Status := SSH_Repository_Path
        (To_String (Location.Original_URL), Remote_Path, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      if SSH_URL_Is_Directory (To_String (Location.Original_URL)) then
         Remote_Path := To_Unbounded_String
           (Join (To_String (Remote_Path), To_String (Location.Object_Name)));
      end if;
      return Remote_Ok;
   end SSH_Object_Path;

   function SSH_Namespace_Path
     (Location    : Remote_Location;
      Remote_Path : out Unbounded_String;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
   begin
      return SSH_Repository_Path
        (To_String (Location.Namespace), Remote_Path, Diagnostic);
   end SSH_Namespace_Path;

   function SSH_Namespace_Object_Path
     (Location    : Remote_Location;
      Object_Name : String;
      Remote_Path : out Unbounded_String;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Namespace_Path : Unbounded_String;
      Status         : Remote_Status;
   begin
      Status := SSH_Namespace_Path (Location, Namespace_Path, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Remote_Path := To_Unbounded_String
        (Join (To_String (Namespace_Path), Object_Name));
      return Remote_Ok;
   end SSH_Namespace_Object_Path;

   function SSH_Restore_Metadata
     (Session     : in out SSH_Lib.Sessions.Session;
      Remote_Path : String;
      Temp_Path   : String;
      Archive_Id  : String;
      Partial     : Boolean;
      Options     : Remote_Options;
      Metadata    : out Archive_Metadata;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Result : SSH_Lib.File_Transfer.Workflow_Result;
      Status : Remote_Status;
   begin
      Delete_If_Exists (Temp_Path);
      Result := SSH_Lib.File_Transfer.Restore
        (Session, Remote_Path, Temp_Path,
         Recursive => False,
         Policy    => SSH_Lib.File_Transfer.Overwrite_Existing,
         Transfer  => SSH_Transfer_Options (Options));
      if Result.Status /= CryptoLib.Errors.Ok then
         Delete_If_Exists (Temp_Path);
         Diagnostic := To_Unbounded_String
           ("SSH remote download failed for " & Remote_Path & ": " &
            SSH_Status_Image (Result.Status));
         return SSH_Status (Result.Status, Remote_Read_Failed);
      end if;

      Status := File_Metadata (Temp_Path, True, Partial, Metadata, Diagnostic);
      Delete_If_Exists (Temp_Path);
      if Status = Remote_Ok then
         Metadata.Archive_Id := To_Unbounded_String (Archive_Id);
         Metadata.Managed := True;
         Metadata.Partial := Partial;
      end if;
      return Status;
   exception
      when others =>
         Delete_If_Exists (Temp_Path);
         Diagnostic := To_Unbounded_String
           ("SSH remote download failed for " & Remote_Path);
         return Remote_Read_Failed;
   end SSH_Restore_Metadata;

   function SSH_Read_Remote_Metadata
     (Location    : Remote_Location;
      Remote_Path : String;
      Temp_Path   : String;
      Archive_Id  : String;
      Partial     : Boolean;
      Options     : Remote_Options;
      Metadata    : out Archive_Metadata;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Session      : SSH_Lib.Sessions.Session;
      Status       : Remote_Status;
      Close_Status : CryptoLib.Errors.Status;
   begin
      Status := Open_SSH_Session
        (To_String (Location.Original_URL), Options, Session, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Status := SSH_Restore_Metadata
        (Session, Remote_Path, Temp_Path, Archive_Id, Partial,
         Options, Metadata, Diagnostic);
      Close_Status := SSH_Lib.Sessions.Close (Session);
      if Status = Remote_Ok and then Close_Status /= CryptoLib.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("SSH session close failed after download for " & Remote_Path & ": " &
            SSH_Status_Image (Close_Status));
         return SSH_Status (Close_Status, Remote_Read_Failed);
      end if;
      return Status;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("SSH remote metadata read failed for " & Remote_Path);
         return Remote_Read_Failed;
   end SSH_Read_Remote_Metadata;

   function Read_SSH_Inventory
     (Location   : Remote_Location;
      Local_Path : String;
      Options    : Remote_Options;
      Inventory  : in out Archive_Metadata_Vectors.Vector;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Namespace_Path : Unbounded_String;
      Session        : SSH_Lib.Sessions.Session;
      Entries        : SSH_Lib.SFTP.Directory_Entry_Vectors.Vector;
      Status         : Remote_Status;
      Status_Value   : CryptoLib.Errors.Status;
      Close_Status   : CryptoLib.Errors.Status;
      Metadata       : Archive_Metadata;
   begin
      Status := SSH_Namespace_Path (Location, Namespace_Path, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Status := Open_SSH_Session
        (To_String (Location.Original_URL), Options, Session, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Status_Value := SSH_Lib.File_Transfer.List_Directory
        (Session, To_String (Namespace_Path), Entries);
      if Status_Value /= CryptoLib.Errors.Ok then
         declare
            Ignored_Close_Status : constant CryptoLib.Errors.Status :=
              SSH_Lib.Sessions.Close (Session);
            pragma Unreferenced (Ignored_Close_Status);
         begin
            null;
         end;
         if Status_Value = CryptoLib.Errors.No_Such_File then
            return Remote_Ok;
         end if;
         Diagnostic := To_Unbounded_String
           ("SSH remote inventory failed for " & To_String (Namespace_Path) &
            ": " & SSH_Status_Image (Status_Value));
         return SSH_Status (Status_Value, Remote_Read_Failed);
      end if;

      for Directory_Item of Entries loop
         declare
            Name        : constant String := To_String (Directory_Item.Name);
            Remote_Path : constant String := Join (To_String (Namespace_Path), Name);
            Partial     : constant Boolean := Ends_With (Name, ".partial");
            Remote_Time : Ada.Calendar.Time;
         begin
            if Backup.Path_Syntax.Looks_Like_Managed_Object (Name)
              and then Backup.Path_Syntax.Safe_Object_Name (Name)
              and then
                (not Directory_Item.Attributes.Permissions_Known
                 or else SSH_Lib.SFTP.Is_Regular_File (Directory_Item.Attributes))
            then
               Status := SSH_Restore_Metadata
                 (Session, Remote_Path, Local_Path & ".ssh-inventory.tmp",
                  Name, Partial, Options, Metadata, Diagnostic);
               if Status /= Remote_Ok then
                  declare
                     Ignored_Close_Status : constant CryptoLib.Errors.Status :=
                       SSH_Lib.Sessions.Close (Session);
                     pragma Unreferenced (Ignored_Close_Status);
                  begin
                     null;
                  end;
                  return Status;
               end if;

               if SSH_Lib.SFTP.Modify_Time_Value
                    (Directory_Item.Attributes, Remote_Time)
               then
                  Metadata.Has_Timestamp := True;
                  Metadata.Timestamp := Remote_Time;
               end if;
               Inventory.Append (Metadata);
            end if;
         end;
      end loop;

      Close_Status := SSH_Lib.Sessions.Close (Session);
      if Close_Status /= CryptoLib.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("SSH session close failed after inventory for " &
            To_String (Namespace_Path) & ": " &
            SSH_Status_Image (Close_Status));
         return SSH_Status (Close_Status, Remote_Read_Failed);
      end if;

      return Remote_Ok;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("could not read SSH remote inventory: " &
            To_String (Location.Namespace));
         return Remote_Read_Failed;
   end Read_SSH_Inventory;

   procedure End_Search_Quietly (Search : in out Ada.Directories.Search_Type) is
   begin
      Ada.Directories.End_Search (Search);
   exception
      when others =>
         null;
   end End_Search_Quietly;

   function Environment_Value (Name : String) return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         return Ada.Environment_Variables.Value (Name);
      end if;
      return "";
   exception
      when others =>
         return "";
   end Environment_Value;

   function JSON_Field (Text : String; Name : String) return String is
      Pattern : constant String := '"' & Name & '"';
      Start   : constant Natural := Ada.Strings.Fixed.Index (Text, Pattern);
      Colon   : Natural;
      First_Q : Natural;
      Last_Q  : Natural;
   begin
      if Start = 0 then
         return "";
      end if;
      Colon := Ada.Strings.Fixed.Index (Text (Start + Pattern'Length .. Text'Last), ":");
      if Colon = 0 then
         return "";
      end if;
      First_Q := Ada.Strings.Fixed.Index (Text (Colon + 1 .. Text'Last), """");
      if First_Q = 0 then
         return "";
      end if;
      Last_Q := Ada.Strings.Fixed.Index (Text (First_Q + 1 .. Text'Last), """");
      if Last_Q = 0 then
         return "";
      end if;
      return Text (First_Q + 1 .. Last_Q - 1);
   exception
      when others =>
         return "";
   end JSON_Field;

   function JSON_First_Field
     (Text : String;
      Primary : String;
      Fallback : String) return String
   is
      Value : constant String := JSON_Field (Text, Primary);
   begin
      if Value'Length > 0 then
         return Value;
      else
         return JSON_Field (Text, Fallback);
      end if;
   end JSON_First_Field;

   procedure Apply_AWS_JSON_Credentials
     (Options : in out Remote_Options;
      Text    : String)
   is
      Access_Key : constant String := JSON_First_Field
        (Text, "AccessKeyId", "accessKeyId");
      Secret_Key : constant String := JSON_First_Field
        (Text, "SecretAccessKey", "secretAccessKey");
      Token      : constant String := JSON_First_Field
        (Text, "SessionToken", "sessionToken");
   begin
      if Length (Options.S3_Access_Key) = 0 and then Access_Key'Length > 0 then
         Options.S3_Access_Key := To_Unbounded_String (Access_Key);
      end if;
      if Length (Options.S3_Secret_Key) = 0 and then Secret_Key'Length > 0 then
         Options.S3_Secret_Key := To_Unbounded_String (Secret_Key);
      end if;
      if Length (Options.S3_Session_Token) = 0 and then Token'Length > 0 then
         Options.S3_Session_Token := To_Unbounded_String (Token);
      end if;
   end Apply_AWS_JSON_Credentials;

   function HTTP_Text
     (URL        : String;
      Options    : Remote_Options;
      Text       : out Unbounded_String;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Result : Http_Client.Clients.Client_Result;
      Status : Remote_Status;
      Code   : Natural := 0;
   begin
      Text := Null_Unbounded_String;
      Status := HTTP_Get (URL, Options, Result, Diagnostic, False);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code /= 200 then
         Diagnostic := To_Unbounded_String
           ("HTTP credential provider returned status" & Natural'Image (Code));
         return Remote_Read_Failed;
      end if;
      Text := To_Unbounded_String (Http_Client.Clients.Response_Text (Result));
      return Remote_Ok;
   end HTTP_Text;

   function HTTP_Text_With_Header
     (URL          : String;
      Header_Name  : String;
      Header_Value : String;
      Options      : Remote_Options;
      Text         : out Unbounded_String;
      Diagnostic   : out Unbounded_String) return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      Result      : Http_Client.Clients.Client_Result;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Status      : Remote_Status;
      Code        : Natural := 0;
   begin
      Text := Null_Unbounded_String;
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set (Headers, Header_Name, Header_Value);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method  => Http_Client.Types.GET,
            URI     => URI,
            Item    => Request,
            Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("HTTP credential provider GET failed");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code /= 200 then
         Diagnostic := To_Unbounded_String
           ("HTTP credential provider GET returned status" & Natural'Image (Code));
         return Remote_Read_Failed;
      end if;
      Text := To_Unbounded_String (Http_Client.Clients.Response_Text (Result));
      return Remote_Ok;
   end HTTP_Text_With_Header;

   function AWS_Profile_Name (Options : Remote_Options) return String is
      Explicit : constant String := To_String (Options.S3_Profile);
      Profile  : constant String := Environment_Value ("AWS_PROFILE");
      Default_Profile : constant String := Environment_Value ("AWS_DEFAULT_PROFILE");
   begin
      if Explicit'Length > 0 then
         return Explicit;
      elsif Profile'Length > 0 then
         return Profile;
      elsif Default_Profile'Length > 0 then
         return Default_Profile;
      else
         return "default";
      end if;
   end AWS_Profile_Name;

   function AWS_Credentials_File (Options : Remote_Options) return String is
      Explicit : constant String := To_String (Options.S3_Credentials_File);
      From_Env : constant String := Environment_Value ("AWS_SHARED_CREDENTIALS_FILE");
      Home     : constant String := Environment_Value ("HOME");
   begin
      if Explicit'Length > 0 then
         return Explicit;
      elsif From_Env'Length > 0 then
         return From_Env;
      elsif Home'Length > 0 then
         return Join (Join (Home, ".aws"), "credentials");
      else
         return "";
      end if;
   end AWS_Credentials_File;

   function AWS_Config_File (Options : Remote_Options) return String is
      Explicit : constant String := To_String (Options.S3_Config_File);
      From_Env : constant String := Environment_Value ("AWS_CONFIG_FILE");
      Home     : constant String := Environment_Value ("HOME");
   begin
      if Explicit'Length > 0 then
         return Explicit;
      elsif From_Env'Length > 0 then
         return From_Env;
      elsif Home'Length > 0 then
         return Join (Join (Home, ".aws"), "config");
      else
         return "";
      end if;
   end AWS_Config_File;

   procedure Load_AWS_Environment_Credentials (Options : in out Remote_Options) is
      Access_Key : constant String := Environment_Value ("AWS_ACCESS_KEY_ID");
      Secret_Key : constant String := Environment_Value ("AWS_SECRET_ACCESS_KEY");
      Token      : constant String := Environment_Value ("AWS_SESSION_TOKEN");
   begin
      if Length (Options.S3_Access_Key) = 0 and then Access_Key'Length > 0 then
         Options.S3_Access_Key := To_Unbounded_String (Access_Key);
      end if;
      if Length (Options.S3_Secret_Key) = 0 and then Secret_Key'Length > 0 then
         Options.S3_Secret_Key := To_Unbounded_String (Secret_Key);
      end if;
      if Length (Options.S3_Session_Token) = 0 and then Token'Length > 0 then
         Options.S3_Session_Token := To_Unbounded_String (Token);
      end if;
   end Load_AWS_Environment_Credentials;

   procedure Load_AWS_Profile_File
     (Options   : in out Remote_Options;
      Path      : String;
      Is_Config : Boolean)
   is
      Profile : constant String := AWS_Profile_Name (Options);
      File    : Ada.Text_IO.File_Type;
      Active  : Boolean := False;

      function Section_Matches (Section : String) return Boolean is
      begin
         if Is_Config then
            return (Profile = "default" and then Section = "default")
              or else Section = "profile " & Profile
              or else (Length (Options.S3_SSO_Session) > 0
                       and then Section = "sso-session " &
                         To_String (Options.S3_SSO_Session));
         else
            return Section = Profile;
         end if;
      end Section_Matches;

      procedure Apply_Field (Key : String; Value : String) is
      begin
         if Key = "aws_access_key_id" and then Length (Options.S3_Access_Key) = 0 then
            Options.S3_Access_Key := To_Unbounded_String (Value);
         elsif Key = "aws_secret_access_key" and then Length (Options.S3_Secret_Key) = 0 then
            Options.S3_Secret_Key := To_Unbounded_String (Value);
         elsif Key = "aws_session_token" and then Length (Options.S3_Session_Token) = 0 then
            Options.S3_Session_Token := To_Unbounded_String (Value);
         elsif Key = "web_identity_token_file"
           and then Length (Options.S3_Web_Identity_Token_File) = 0
         then
            Options.S3_Web_Identity_Token_File := To_Unbounded_String (Value);
         elsif Key = "role_arn" and then Length (Options.S3_Role_Arn) = 0 then
            Options.S3_Role_Arn := To_Unbounded_String (Value);
         elsif Key = "credential_process"
           and then Length (Options.S3_Credential_Process) = 0
         then
            Options.S3_Credential_Process := To_Unbounded_String (Value);
         elsif Key = "sso_session" and then Length (Options.S3_SSO_Session) = 0 then
            Options.S3_SSO_Session := To_Unbounded_String (Value);
         elsif Key = "sso_start_url" and then Length (Options.S3_SSO_Start_URL) = 0 then
            Options.S3_SSO_Start_URL := To_Unbounded_String (Value);
         elsif Key = "sso_region" and then Length (Options.S3_SSO_Region) = 0 then
            Options.S3_SSO_Region := To_Unbounded_String (Value);
         elsif Key = "sso_account_id" and then Length (Options.S3_SSO_Account_Id) = 0 then
            Options.S3_SSO_Account_Id := To_Unbounded_String (Value);
         elsif Key = "sso_role_name" and then Length (Options.S3_SSO_Role_Name) = 0 then
            Options.S3_SSO_Role_Name := To_Unbounded_String (Value);
         elsif Key = "region" and then Length (Options.S3_Region) = 0 then
            Options.S3_Region := To_Unbounded_String (Value);
         end if;
      end Apply_Field;
   begin
      if Path'Length = 0 or else not Ada.Directories.Exists (Path) then
         return;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Raw : constant String := Ada.Text_IO.Get_Line (File);
            Line : constant String := Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both);
            Eq   : Natural;
         begin
            if Line'Length = 0 or else Line (Line'First) = '#' or else Line (Line'First) = ';' then
               null;
            elsif Line (Line'First) = '[' and then Line (Line'Last) = ']' then
               declare
                  Section : constant String := Ada.Strings.Fixed.Trim
                    (Line (Line'First + 1 .. Line'Last - 1), Ada.Strings.Both);
               begin
                  Active := Section_Matches (Section);
               end;
            elsif Active then
               Eq := Ada.Strings.Fixed.Index (Line, "=");
               if Eq > Line'First then
                  Apply_Field
                    (Ada.Strings.Fixed.Trim (Line (Line'First .. Eq - 1), Ada.Strings.Both),
                     Ada.Strings.Fixed.Trim (Line (Eq + 1 .. Line'Last), Ada.Strings.Both));
               end if;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Load_AWS_Profile_File;

   procedure Load_AWS_Shared_Credentials (Options : in out Remote_Options) is
   begin
      Load_AWS_Profile_File (Options, AWS_Credentials_File (Options), False);
      Load_AWS_Profile_File (Options, AWS_Config_File (Options), True);
      if Length (Options.S3_SSO_Session) > 0 then
         Load_AWS_Profile_File (Options, AWS_Config_File (Options), True);
      end if;
   end Load_AWS_Shared_Credentials;

   function Shell_Words (Command : String) return String_Vectors.Vector is
      Result     : String_Vectors.Vector;
      Current    : Unbounded_String;
      In_Single  : Boolean := False;
      In_Double  : Boolean := False;
      Escaped    : Boolean := False;

      procedure Finish_Word is
      begin
         if Length (Current) > 0 then
            Result.Append (To_String (Current));
            Current := Null_Unbounded_String;
         end if;
      end Finish_Word;
   begin
      for Ch of Command loop
         if Escaped then
            Append (Current, Ch);
            Escaped := False;
         elsif Ch = '\' and then not In_Single then
            Escaped := True;
         elsif Ch = ''' and then not In_Double then
            In_Single := not In_Single;
         elsif Ch = '"' and then not In_Single then
            In_Double := not In_Double;
         elsif (Ch = ' ' or else Ch = ASCII.HT) and then not In_Single and then not In_Double then
            Finish_Word;
         else
            Append (Current, Ch);
         end if;
      end loop;

      if Escaped then
         Append (Current, '\');
      end if;
      Finish_Word;
      return Result;
   exception
      when others =>
         Result.Clear;
         return Result;
   end Shell_Words;

   function Cache_Timestamp_Valid (Text : String) return Boolean is
      Has_Value : Boolean := False;
      Value     : Ada.Calendar.Time := Ada.Calendar.Time_Of (2000, 1, 1);
   begin
      if Text'Length < 19 then
         return False;
      end if;

      declare
         Normalized : constant String := Text (Text'First .. Text'First + 18) & "Z";
      begin
         if not Parse_Index_Timestamp (Normalized, Has_Value, Value) then
            return False;
         end if;
      end;

      return Has_Value and then Ada.Calendar."-" (Value, Ada.Calendar.Clock) > 60.0;
   exception
      when others =>
         return False;
   end Cache_Timestamp_Valid;

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
      return Ada.Strings.Fixed.Trim (To_String (Text), Ada.Strings.Both);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Read_Text_File;

   procedure Write_Text_File (Path : String; Text : String) is
      File        : Ada.Text_IO.File_Type;
      Temp_Path   : constant String :=
        Path & ".tmp-" &
        Natural'Image
          (Natural
             (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)));
      Backup_Path : constant String := Path & ".bak";
      Have_Backup : Boolean := False;
   begin
      if Path'Length = 0 then
         return;
      end if;

      if Ada.Directories.Exists (Temp_Path) then
         Ada.Directories.Delete_File (Temp_Path);
      end if;
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Temp_Path);
      Ada.Text_IO.Put_Line (File, Text);
      Ada.Text_IO.Close (File);
      declare
         Ignored : constant Boolean :=
           Backup.Platform.Set_Permissions (Temp_Path, 8#600#);
      begin
         pragma Unreferenced (Ignored);
      end;

      if Ada.Directories.Exists (Backup_Path) then
         Ada.Directories.Delete_File (Backup_Path);
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Rename (Path, Backup_Path);
         Have_Backup := True;
      end if;
      Ada.Directories.Rename (Temp_Path, Path);
      if Have_Backup and then Ada.Directories.Exists (Backup_Path) then
         Ada.Directories.Delete_File (Backup_Path);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         begin
            if Ada.Directories.Exists (Temp_Path) then
               Ada.Directories.Delete_File (Temp_Path);
            end if;
            if Have_Backup and then not Ada.Directories.Exists (Path)
              and then Ada.Directories.Exists (Backup_Path)
            then
               Ada.Directories.Rename (Backup_Path, Path);
            end if;
         exception
            when others =>
               null;
         end;
   end Write_Text_File;

   function HTTP_Post_Form_Text
     (URL        : String;
      Form       : String;
      Options    : Remote_Options;
      Text       : out Unbounded_String;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Request     : Http_Client.Requests.Request;
      Result      : Http_Client.Clients.Client_Result;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Status      : Remote_Status;
      Code        : Natural := 0;
   begin
      Text := Null_Unbounded_String;
      Status := Configure_HTTP_Client (URL, Options, Client, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      HTTP_Status := Http_Client.URI.Parse (URL, URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Type", "application/x-www-form-urlencoded");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method  => Http_Client.Types.POST,
            URI     => URI,
            Item    => Request,
            Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String (Form));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
      end if;
      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String ("HTTP credential provider POST failed");
         return HTTP_Error_Status (HTTP_Status);
      end if;
      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code /= 200 then
         Diagnostic := To_Unbounded_String
           ("HTTP credential provider POST returned status" & Natural'Image (Code));
         return Remote_Read_Failed;
      end if;
      Text := To_Unbounded_String (Http_Client.Clients.Response_Text (Result));
      return Remote_Ok;
   end HTTP_Post_Form_Text;

   function AWS_SSO_Cache_Directory return String is
      Explicit : constant String := Environment_Value ("AWS_SSO_CACHE_DIR");
      Home     : constant String := Environment_Value ("HOME");
   begin
      if Explicit'Length > 0 then
         return Explicit;
      elsif Home'Length > 0 then
         return Join (Join (Join (Home, ".aws"), "sso"), "cache");
      else
         return "";
      end if;
   end AWS_SSO_Cache_Directory;

   function AWS_SSO_Access_Token (Options : Remote_Options) return String is
      Cache_Dir : constant String := AWS_SSO_Cache_Directory;
      Start_URL : constant String := To_String (Options.S3_SSO_Start_URL);
      Session   : constant String := To_String (Options.S3_SSO_Session);
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Fallback  : Unbounded_String;
   begin
      if Cache_Dir'Length = 0 or else not Ada.Directories.Exists (Cache_Dir) then
         return "";
      end if;
      Ada.Directories.Start_Search (Search, Cache_Dir, "*.json");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Path : constant String := Ada.Directories.Compose
              (Cache_Dir, Ada.Directories.Simple_Name (Dir_Entry));
            Text : constant String := Read_Text_File (Path);
            Token : constant String := JSON_Field (Text, "accessToken");
            Cached_Start : constant String := JSON_Field (Text, "startUrl");
            Cached_Session : constant String := JSON_Field (Text, "sessionName");
            Expires_At : constant String := JSON_Field (Text, "expiresAt");
            Fresh : constant Boolean :=
              Expires_At'Length = 0 or else Cache_Timestamp_Valid (Expires_At);
            Session_Match : constant Boolean :=
              Session'Length > 0 and then Cached_Session = Session;
            Start_Match : constant Boolean :=
              Start_URL'Length > 0 and then Cached_Start = Start_URL;
         begin
            if Token'Length > 0 and then Fresh then
               if Session_Match then
                  End_Search_Quietly (Search);
                  return Token;
               elsif Start_Match and then Length (Fallback) = 0 then
                  Fallback := To_Unbounded_String (Token);
               end if;
            end if;
         end;
      end loop;
      End_Search_Quietly (Search);
      return To_String (Fallback);
   exception
      when others =>
         End_Search_Quietly (Search);
         return "";
   end AWS_SSO_Access_Token;

   procedure Load_AWS_SSO (Options : in out Remote_Options) is
      Region : constant String := To_String (Options.S3_SSO_Region);
      Account_Id : constant String := To_String (Options.S3_SSO_Account_Id);
      Role_Name : constant String := To_String (Options.S3_SSO_Role_Name);
      Token : constant String := AWS_SSO_Access_Token (Options);
      URL : constant String :=
        "https://portal.sso." & Region & ".amazonaws.com/federation/credentials" &
        "?role_name=" & Percent_Encode_Query_Component (Role_Name) &
        "&account_id=" & Percent_Encode_Query_Component (Account_Id);
      Text : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status : Remote_Status;
   begin
      if Region'Length = 0
        or else Account_Id'Length = 0
        or else Role_Name'Length = 0
        or else Token'Length = 0
      then
         return;
      end if;
      Status := HTTP_Text_With_Header
        (URL, "x-amz-sso_bearer_token", Token,
         (Timeout_Seconds => 10, others => <>), Text, Diagnostic);
      if Status = Remote_Ok then
         Apply_AWS_JSON_Credentials (Options, To_String (Text));
      end if;
   exception
      when others =>
         null;
   end Load_AWS_SSO;

   procedure Load_AWS_Web_Identity (Options : in out Remote_Options) is
      Token_File : constant String :=
        (if Length (Options.S3_Web_Identity_Token_File) > 0 then
         To_String (Options.S3_Web_Identity_Token_File)
         else Environment_Value ("AWS_WEB_IDENTITY_TOKEN_FILE"));
      Role_Arn : constant String :=
        (if Length (Options.S3_Role_Arn) > 0 then
         To_String (Options.S3_Role_Arn)
         else Environment_Value ("AWS_ROLE_ARN"));
      Session_Name : constant String :=
        (if Environment_Value ("AWS_ROLE_SESSION_NAME")'Length > 0 then
         Environment_Value ("AWS_ROLE_SESSION_NAME")
         else "backup");
      Token : constant String := Read_Text_File (Token_File);
      Form_Response_Text : constant String :=
        "Action=AssumeRoleWithWebIdentity" &
        "&Version=2011-06-15" &
        "&RoleArn=" & Percent_Encode_Query_Component (Role_Arn) &
        "&RoleSessionName=" & Percent_Encode_Query_Component (Session_Name) &
        "&WebIdentityToken=" & Percent_Encode_Query_Component (Token);
      Text : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status : Remote_Status;
   begin
      if Token'Length = 0 or else Role_Arn'Length = 0 then
         return;
      end if;
      Status := HTTP_Post_Form_Text
        ("https://sts.amazonaws.com/", Form_Response_Text, (Timeout_Seconds => 10, others => <>),
         Text, Diagnostic);
      if Status = Remote_Ok then
         if Length (Options.S3_Access_Key) = 0 then
            Options.S3_Access_Key := To_Unbounded_String
              (XML_Tag_Value (To_String (Text), "AccessKeyId"));
         end if;
         if Length (Options.S3_Secret_Key) = 0 then
            Options.S3_Secret_Key := To_Unbounded_String
              (XML_Tag_Value (To_String (Text), "SecretAccessKey"));
         end if;
         if Length (Options.S3_Session_Token) = 0 then
            Options.S3_Session_Token := To_Unbounded_String
              (XML_Tag_Value (To_String (Text), "SessionToken"));
         end if;
      end if;
   exception
      when others =>
         null;
   end Load_AWS_Web_Identity;

   --  The host's temporary directory. Hardcoding "/tmp" was wrong twice: Windows has no
   --  /tmp, and a fixed name there for a credentials file is a shared-directory hazard --
   --  another user could pre-create the path, or read what we wrote. Ask the host, and let
   --  the caller build a per-run name under it.
   function Host_Temp_Dir return String is
      Tmpdir : constant String := Environment_Value ("TMPDIR");
      Temp   : constant String := Environment_Value ("TEMP");
      Tmp    : constant String := Environment_Value ("TMP");
   begin
      if Tmpdir'Length > 0 then
         return Tmpdir;
      elsif Temp'Length > 0 then
         return Temp;
      elsif Tmp'Length > 0 then
         return Tmp;
      else
         return "/tmp";
      end if;
   end Host_Temp_Dir;

   function Unique_Temp_File (Base : String; Suffix : String) return String is
   begin
      for Counter in Natural range 0 .. 10_000 loop
         declare
            Candidate : constant String :=
              Base & Integer'Image (Counter) (2 .. Integer'Image (Counter)'Last) & Suffix;
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;

      return Base & "overflow" & Suffix;
   end Unique_Temp_File;

   procedure Load_AWS_Credential_Process (Options : in out Remote_Options) is
      Command : constant String := To_String (Options.S3_Credential_Process);
      Words   : constant String_Vectors.Vector := Shell_Words (Command);
      Output  : constant String :=
        Unique_Temp_File
          (Ada.Directories.Compose (Host_Temp_Dir, "backup-aws-credential-process"), ".json");
      Success : Boolean := False;
      Code    : Integer := 0;
      File    : Ada.Text_IO.File_Type;
      Text    : Unbounded_String;
   begin
      if Words.Is_Empty then
         return;
      end if;

      declare
         Program : constant String := Words.Element (Words.First_Index);
         Args    : GNAT.OS_Lib.Argument_List
           (1 .. Natural (Words.Length) - 1);
      begin
         if Words.Length > 1 then
            for Index in 2 .. Natural (Words.Length) loop
               Args (Index - 1) := new String'(Words.Element (Index));
            end loop;
         end if;

         GNAT.OS_Lib.Spawn (Program, Args, Output, Success, Code);

         if Words.Length > 1 then
            for Index in Args'Range loop
               GNAT.OS_Lib.Free (Args (Index));
            end loop;
         end if;
      end;

      if not Success or else Code /= 0 or else not Ada.Directories.Exists (Output) then
         return;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Output);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Text, Ada.Text_IO.Get_Line (File));
      end loop;
      Ada.Text_IO.Close (File);
      Apply_AWS_JSON_Credentials (Options, To_String (Text));

      --  The file holds the credentials the process just printed; do not leave it lying
      --  in the temp directory once they are read.
      if Ada.Directories.Exists (Output) then
         Ada.Directories.Delete_File (Output);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         if Ada.Directories.Exists (Output) then
            begin
               Ada.Directories.Delete_File (Output);
            exception
               when others =>
                  null;
            end;
         end if;
   end Load_AWS_Credential_Process;

   procedure Load_AWS_Container_Credentials (Options : in out Remote_Options) is
      Full_URI : constant String := Environment_Value ("AWS_CONTAINER_CREDENTIALS_FULL_URI");
      Relative : constant String := Environment_Value ("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI");
      URL : constant String :=
        (if Full_URI'Length > 0 then Full_URI
         elsif Relative'Length > 0 then "http://169.254.170.2" & Relative
         else "");
      Text : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status : Remote_Status;
   begin
      if URL'Length = 0 then
         return;
      end if;
      Status := HTTP_Text (URL, (Timeout_Seconds => 2, others => <>), Text, Diagnostic);
      if Status = Remote_Ok then
         Apply_AWS_JSON_Credentials (Options, To_String (Text));
      end if;
   exception
      when others =>
         null;
   end Load_AWS_Container_Credentials;

   procedure Load_AWS_Instance_Metadata (Options : in out Remote_Options) is
      Role_URL : constant String :=
        "http://169.254.169.254/latest/meta-data/iam/security-credentials/";
      Role_Text : Unbounded_String;
      Cred_Text : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status : Remote_Status;
      Role : Unbounded_String;
   begin
      Status := HTTP_Text (Role_URL, (Timeout_Seconds => 2, others => <>), Role_Text, Diagnostic);
      if Status /= Remote_Ok or else Length (Role_Text) = 0 then
         return;
      end if;
      declare
         Raw : constant String := To_String (Role_Text);
         Stop : Natural := Raw'Last;
      begin
         for Index in Raw'Range loop
            if Raw (Index) = ASCII.LF or else Raw (Index) = ASCII.CR then
               Stop := Index - 1;
               exit;
            end if;
         end loop;
         if Stop >= Raw'First then
            Role := To_Unbounded_String (Raw (Raw'First .. Stop));
         end if;
      end;
      if Length (Role) = 0 then
         return;
      end if;
      Status := HTTP_Text (Role_URL & Percent_Encode_Path (To_String (Role)),
                           (Timeout_Seconds => 2, others => <>), Cred_Text, Diagnostic);
      if Status = Remote_Ok then
         Apply_AWS_JSON_Credentials (Options, To_String (Cred_Text));
      end if;
   exception
      when others =>
         null;
   end Load_AWS_Instance_Metadata;

   function Resolved_S3_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Options
   is
      Result : Remote_Options := Options;
   begin
      Diagnostic := Null_Unbounded_String;
      Load_AWS_Environment_Credentials (Result);
      if Length (Result.S3_Access_Key) = 0 or else Length (Result.S3_Secret_Key) = 0 then
         Load_AWS_Shared_Credentials (Result);
      end if;
      if Length (Result.S3_Access_Key) = 0 or else Length (Result.S3_Secret_Key) = 0 then
         Load_AWS_SSO (Result);
      end if;
      if Length (Result.S3_Access_Key) = 0 or else Length (Result.S3_Secret_Key) = 0 then
         Load_AWS_Web_Identity (Result);
      end if;
      if Length (Result.S3_Access_Key) = 0 or else Length (Result.S3_Secret_Key) = 0 then
         Load_AWS_Credential_Process (Result);
      end if;
      if Length (Result.S3_Access_Key) = 0 or else Length (Result.S3_Secret_Key) = 0 then
         Load_AWS_Container_Credentials (Result);
      end if;
      if Length (Result.S3_Access_Key) = 0 or else Length (Result.S3_Secret_Key) = 0 then
         Load_AWS_Instance_Metadata (Result);
      end if;
      return Result;
   end Resolved_S3_Options;

   function Validate_Options
     (Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
   begin
      declare
         Status : constant Remote_Status :=
           Backup.Remote_Syntax.Timeout_Precheck_Status (Options.Timeout_Seconds);
      begin
         if Status = Remote_Timeout then
            Diagnostic := To_Unbounded_String
              ("remote operation timed out before it could start");
         end if;
         if Status /= Remote_Ok then
            return Status;
         end if;
      end;

      return Remote_Ok;
   end Validate_Options;


   function Validate_Transport_Options
     (Location   : Remote_Location;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Status : constant Remote_Status := Validate_Options (Options, Diagnostic);
      Resolved : Remote_Options := Options;
   begin
      if Status /= Remote_Ok then
         return Status;
      end if;
      if Location.Kind = Transport_S3 then
         Resolved := Resolved_S3_Options (Options, Diagnostic);
         if not Is_Valid_S3_Bucket (S3_Bucket (Location)) then
            Diagnostic := To_Unbounded_String
              ("S3 remote URL must include a valid bucket name");
            return Remote_Invalid_URL;
         elsif not Is_Valid_S3_Endpoint (S3_Endpoint (Options)) then
            Diagnostic := To_Unbounded_String
              ("S3 endpoint must be an http:// or https:// URL without query or fragment");
            return Remote_Invalid_URL;
         elsif Options.S3_Virtual_Hosted_Style
           and then Endpoint_Path_Prefix (S3_Endpoint (Options))'Length > 0
         then
            Diagnostic := To_Unbounded_String
              ("S3 virtual-hosted style requires an endpoint without a path prefix");
            return Remote_Invalid_URL;
         elsif Length (Options.S3_Server_Side_Encryption) > 0
           and then To_String (Options.S3_Server_Side_Encryption) /= "AES256"
           and then To_String (Options.S3_Server_Side_Encryption) /= "aws:kms"
         then
            Diagnostic := To_Unbounded_String
              ("S3 server-side encryption must be AES256 or aws:kms");
            return Remote_Invalid_URL;
         elsif Length (Options.S3_SSE_KMS_Key_Id) > 0
           and then To_String (Options.S3_Server_Side_Encryption) /= "aws:kms"
         then
            Diagnostic := To_Unbounded_String
              ("S3 KMS key id requires s3_server_side_encryption=aws:kms");
            return Remote_Invalid_URL;
         elsif (Length (Options.S3_Metadata_Name) = 0) /=
           (Length (Options.S3_Metadata_Value) = 0)
         then
            Diagnostic := To_Unbounded_String
              ("S3 metadata requires both s3_metadata_name and s3_metadata_value");
            return Remote_Invalid_URL;
         elsif Length (Options.S3_Metadata_Name) > 0
           and then not Is_S3_Metadata_Name (To_String (Options.S3_Metadata_Name))
         then
            Diagnostic := To_Unbounded_String
              ("S3 metadata name may contain only letters, digits, '-' or '_'");
            return Remote_Invalid_URL;
         elsif Length (Options.S3_Object_Lock_Mode) > 0
           and then To_String (Options.S3_Object_Lock_Mode) /= "GOVERNANCE"
           and then To_String (Options.S3_Object_Lock_Mode) /= "COMPLIANCE"
         then
            Diagnostic := To_Unbounded_String
              ("S3 Object Lock mode must be GOVERNANCE or COMPLIANCE");
            return Remote_Invalid_URL;
         elsif Length (Options.S3_Object_Lock_Retain_Until) > 0
           and then Length (Options.S3_Object_Lock_Mode) = 0
         then
            Diagnostic := To_Unbounded_String
              ("S3 Object Lock retain-until date requires s3_object_lock_mode");
            return Remote_Invalid_URL;
         elsif Length (Options.S3_Object_Lock_Retain_Until) > 0
         then
            declare
               Has_Timestamp : Boolean;
               Timestamp     : Ada.Calendar.Time;
            begin
               if not Parse_Index_Timestamp
                   (To_String (Options.S3_Object_Lock_Retain_Until),
                    Has_Timestamp, Timestamp)
                 or else not Has_Timestamp
               then
                  Diagnostic := To_Unbounded_String
                    ("S3 Object Lock retain-until date must be YYYY-MM-DDTHH:MM:SSZ");
                  return Remote_Invalid_URL;
               end if;
            end;
         elsif Length (Options.S3_Object_Lock_Legal_Hold) > 0
           and then To_String (Options.S3_Object_Lock_Legal_Hold) /= "ON"
           and then To_String (Options.S3_Object_Lock_Legal_Hold) /= "OFF"
         then
            Diagnostic := To_Unbounded_String
              ("S3 Object Lock legal hold must be ON or OFF");
            return Remote_Invalid_URL;
         elsif Ada.Strings.Unbounded.Length (Resolved.S3_Access_Key) = 0 then
            Diagnostic := To_Unbounded_String
              ("S3 access key is required for s3:// remotes");
            return Remote_Authentication_Failed;
         elsif Ada.Strings.Unbounded.Length (Resolved.S3_Secret_Key) = 0 then
            Diagnostic := To_Unbounded_String
              ("S3 secret key is required for s3:// remotes");
            return Remote_Authentication_Failed;
         end if;
      elsif Location.Kind = Transport_Google_Drive then
         if Google_Drive_Folder_Id (Location)'Length = 0 then
            Diagnostic := To_Unbounded_String
              ("Google Drive remote URL must include a folder id");
            return Remote_Invalid_URL;
         elsif not Is_Valid_S3_Endpoint (Google_Drive_API_Base (Options))
           or else not Is_Valid_S3_Endpoint (Google_Drive_Upload_Base (Options))
         then
            Diagnostic := To_Unbounded_String
              ("Google Drive API base URLs must be http:// or https:// URLs without query or fragment");
            return Remote_Invalid_URL;
         else
            declare
               Resolved : constant Remote_Options :=
                 Resolved_Google_Drive_Options (Options, Diagnostic);
            begin
               if Length (Resolved.Google_Drive_Access_Token) = 0 then
                  if Length (Diagnostic) = 0 then
                     Diagnostic := To_Unbounded_String
                       ("Google Drive access token is required for gdrive:// remotes");
                  end if;
                  return Remote_Authentication_Failed;
               end if;
            end;
         end if;
      elsif Location.Kind = Transport_PCloud then
         if PCloud_Folder_Id (Location)'Length = 0 then
            Diagnostic := To_Unbounded_String
              ("pCloud remote URL must include a folder id or folder path");
            return Remote_Invalid_URL;
         elsif not Is_Valid_S3_Endpoint (PCloud_API_Base (Options)) then
            Diagnostic := To_Unbounded_String
              ("pCloud API base URL must be an http:// or https:// URL without query or fragment");
            return Remote_Invalid_URL;
         else
            declare
               Resolved : constant Remote_Options :=
                 Resolved_PCloud_Options (Options, Diagnostic);
            begin
               if Length (Resolved.PCloud_Access_Token) = 0 then
                  if Length (Diagnostic) = 0 then
                     Diagnostic := To_Unbounded_String
                       ("pCloud access token is required for pcloud:// remotes");
                  end if;
                  return Remote_Authentication_Failed;
               end if;
            end;
         end if;
      elsif Location.Kind = Transport_Proton_Drive then
         if Proton_Drive_Share_Id (Location)'Length = 0 then
            Diagnostic := To_Unbounded_String
              ("Proton Drive remote URL must include a share id");
            return Remote_Invalid_URL;
         else
            declare
               SDK_Diagnostic : Unbounded_String;
               Client : constant Proton_Drive.Client := Proton_Drive.Create
                 (Proton_Drive_Config (Location, Options), SDK_Diagnostic);
               SDK_Status : constant Proton_Drive.SDK_Status :=
                 Proton_Drive.Status (Client);
            begin
               if Proton_Drive.Ready (Client) then
                  null;
               elsif SDK_Status = Proton_Drive.SDK_Invalid_Config then
                  Diagnostic := SDK_Diagnostic;
                  return Remote_Invalid_URL;
               elsif SDK_Status = Proton_Drive.SDK_Provider_Missing then
                  Diagnostic := SDK_Diagnostic;
                  return Remote_Authentication_Failed;
               else
                  Diagnostic := SDK_Diagnostic;
                  return Remote_Unsupported_Transport;
               end if;
            end;
         end if;
      end if;
      return Remote_Ok;
   end Validate_Transport_Options;

   function Copy_With_Retry
     (Source     : String;
      Target     : String;
      Options    : Remote_Options;
      Report     : in out Transfer_Report;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
   begin
      for Attempt in Natural range 0 .. Options.Retry_Count loop
         begin
            Ada.Directories.Copy_File (Source, Target);
            return Remote_Ok;
         exception
            when others =>
               Delete_If_Exists (Target);
               if Backup.Remote_Syntax.Attempts_Exhausted
                 (Attempt, Options.Retry_Count)
               then
                  Diagnostic := To_Unbounded_String
                    ("could not copy remote payload after" &
                     Natural'Image (Attempt + 1) & " attempt(s)");
                  return Remote_Copy_Failed;
               else
                  Report.Retried := Report.Retried + 1;
               end if;
         end;
      end loop;
      Diagnostic := To_Unbounded_String ("remote copy retry loop did not run");
      return Remote_Copy_Failed;
   end Copy_With_Retry;

   function Move_Temp_To_Final
     (Temp_Path  : String;
      Final_Path : String) return Boolean
   is
      Backup_Path : constant String := Final_Path & ".replace-old";
      Old_Moved   : Boolean := False;
   begin
      Delete_If_Exists (Backup_Path);
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
                  when others => null;
               end;
            end if;
            return False;
      end;
      if Old_Moved then
         Delete_If_Exists (Backup_Path);
      end if;
      return True;
   end Move_Temp_To_Final;

   function Verify_Remote_Archive
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Report     : out Transfer_Report;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
      Local    : Archive_Metadata;
      Remote   : Archive_Metadata;
   begin
      Report := (Status        => Remote_Invalid_URL,
                 Transport     => Transport_Unsupported,
                 Remote_URL    => To_Unbounded_String (URL),
                 Local_Path    => To_Unbounded_String (Local_Path),
                 Remote_Object => Null_Unbounded_String,
                 Size          => 0,
                 Crc32         => 0,
                 Atomic        => False,
                 Resumed       => False,
                 Verified      => False,
                 Retried       => 0,
                 PCloud_Progress_Samples => 0);
      Status := Parse_URL (URL, Local_Path, Location, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      Report.Transport := Location.Kind;
      Report.Remote_Object := Location.Object_Name;
      if Is_Unsupported_Transfer_Transport (Location.Kind) then
         Diagnostic := To_Unbounded_String ("unsupported remote verification transport");
         Report.Status := Remote_Unsupported_Transport;
         return Remote_Unsupported_Transport;
      end if;
      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      if not Ada.Directories.Exists (Local_Path) then
         Diagnostic := To_Unbounded_String ("local archive does not exist: " & Local_Path);
         Report.Status := Remote_Not_Found;
         return Remote_Not_Found;
      end if;
      Status := File_Metadata (Local_Path, True, False, Local, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      if Location.Kind = Transport_S3 then
         declare
            Head_Result : Http_Client.Clients.Client_Result;
            Head_Diagnostic : Unbounded_String;
            Head_Status : constant Remote_Status := Execute_S3_Request
              (Http_Client.Types.HEAD, Remote_Object_URL (Location, Options),
               Options, Head_Result, Head_Diagnostic,
               Request_Checksum_Mode => True);
            Native_CRC32 : constant String :=
              (if Head_Status = Remote_Ok
                 and then Natural
                   (Http_Client.Responses.Status_Code (Head_Result.Response)) = 200
               then Http_Client.Responses.Header
                 (Head_Result.Response, "x-amz-checksum-crc32")
               else "");
         begin
            if Native_CRC32'Length > 0
              and then Native_CRC32 /= S3_CRC32_Base64 (Local.Crc32)
            then
               Diagnostic := To_Unbounded_String
                 ("S3 native CRC32 checksum mismatch for " &
                  To_String (Location.Object_Name));
               Report.Status := Remote_Metadata_Mismatch;
               return Remote_Metadata_Mismatch;
            end if;
         end;
      end if;

      if Location.Kind = Transport_Google_Drive then
         declare
            Temp_Path : constant String := Local_Path & ".gdrive-verify.tmp";
         begin
            Status := Download_Google_Drive_Object
              (Location, To_String (Location.Object_Name), Temp_Path,
               Options, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Status := File_Metadata (Temp_Path, True, False, Remote, Diagnostic);
            Delete_If_Exists (Temp_Path);
         end;
      elsif Location.Kind = Transport_Proton_Drive then
         declare
            Temp_Path : constant String := Local_Path & ".proton-verify.tmp";
            SDK_Diagnostic : Unbounded_String;
            Client : constant Proton_Drive.Client :=
              Proton_Drive_Client (Location, Options, SDK_Diagnostic);
         begin
            Status := Proton_Drive_Status
              (Proton_Drive.Download_File
                 (Client, Proton_Drive_Remote_Path
                    (Location, To_String (Location.Object_Name)),
                  Temp_Path, Diagnostic));
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Status := File_Metadata (Temp_Path, True, False, Remote, Diagnostic);
            Delete_If_Exists (Temp_Path);
         end;
      elsif Location.Kind = Transport_PCloud then
         declare
            Remote_Size : Interfaces.Unsigned_64 := 0;
            Has_SHA256  : Boolean := False;
            Remote_SHA256 : Unbounded_String;
            Has_SHA1  : Boolean := False;
            Remote_SHA1 : Unbounded_String;
            Metadata_Status : Remote_Status;
         begin
            Metadata_Status := PCloud_Checksum_Metadata
              (Location, Options, To_String (Location.Object_Name),
               Remote_Size, Has_SHA256, Remote_SHA256, Has_SHA1, Remote_SHA1,
               Diagnostic);
            if Metadata_Status /= Remote_Ok then
               Report.Status := Metadata_Status;
               return Metadata_Status;
            elsif Remote_Size /= Local.Size then
               Diagnostic := To_Unbounded_String
                 ("pCloud remote archive size mismatch for " &
                  To_String (Location.Object_Name));
               Report.Status := Remote_Metadata_Mismatch;
               return Remote_Metadata_Mismatch;
            elsif Has_SHA256 then
               declare
                  Local_SHA256 : constant String :=
                    Http_Client.Crypto.Digest_File_SHA256_Hex (Local_Path);
               begin
                  if Equal_Hex_Case_Insensitive
                    (To_String (Remote_SHA256), Local_SHA256)
                  then
                     Report.Size := Local.Size;
                     Report.Crc32 := Local.Crc32;
                     Report.Verified := True;
                     Report.Status := Remote_Ok;
                     return Remote_Ok;
                  end if;
                  Diagnostic := To_Unbounded_String
                    ("pCloud remote archive SHA-256 mismatch for " &
                     To_String (Location.Object_Name));
                  Report.Status := Remote_Metadata_Mismatch;
                  return Remote_Metadata_Mismatch;
               end;
            elsif Has_SHA1 then
               declare
                  Local_SHA1 : constant String := Digest_File_SHA1_Hex (Local_Path);
               begin
                  if Local_SHA1'Length > 0
                    and then Equal_Hex_Case_Insensitive
                      (To_String (Remote_SHA1), Local_SHA1)
                  then
                     Report.Size := Local.Size;
                     Report.Crc32 := Local.Crc32;
                     Report.Verified := True;
                     Report.Status := Remote_Ok;
                     return Remote_Ok;
                  elsif Local_SHA1'Length > 0 then
                     Diagnostic := To_Unbounded_String
                       ("pCloud remote archive SHA-1 mismatch for " &
                        To_String (Location.Object_Name) &
                        " (remote " & To_String (Remote_SHA1) &
                        ", local " & Local_SHA1 & ")");
                     Report.Status := Remote_Metadata_Mismatch;
                     return Remote_Metadata_Mismatch;
                  end if;
               end;
            end if;
         end;
         declare
            Temp_Path : constant String := Local_Path & ".pcloud-verify.tmp";
         begin
            Status := Download_PCloud_Object
              (Location, To_String (Location.Object_Name), Temp_Path,
               Options, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Status := File_Metadata (Temp_Path, True, False, Remote, Diagnostic);
            Delete_If_Exists (Temp_Path);
         end;
      elsif Location.Kind = Transport_SSH then
         declare
            Remote_Path : Unbounded_String;
         begin
            Status := SSH_Object_Path (Location, Remote_Path, Diagnostic);
            if Status = Remote_Ok then
               Status := SSH_Read_Remote_Metadata
                 (Location, To_String (Remote_Path),
                  Local_Path & ".ssh-verify.tmp",
                  To_String (Location.Object_Name), False,
                  Options, Remote, Diagnostic);
            end if;
         end;
      elsif Location.Kind = Transport_File then
         if not Ada.Directories.Exists (Remote_Object_Path (Location)) then
            Diagnostic := To_Unbounded_String ("remote archive does not exist: " & Remote_Object_Path (Location));
            Report.Status := Remote_Not_Found;
            return Remote_Not_Found;
         end if;
         Status := File_Metadata (Remote_Object_Path (Location), True, False, Remote, Diagnostic);
      else
         declare
            Temp_Path : constant String := Local_Path & ".http-verify.tmp";
            Download  : Http_Client.Clients.Download_Result;
            Code      : Natural := 0;
         begin
            Status := HTTP_Download_To_File
              (Remote_Object_URL (Location, Options), Temp_Path, Options, Download,
               Diagnostic, Location.Kind = Transport_S3);
            if Status /= Remote_Ok then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote verification failed for " & Remote_Object_URL (Location, Options));
               Report.Status := Status;
               return Status;
            end if;
            Code := Download.HTTP_Status_Code;
            if not HTTP_Status_OK (Code) then
               Delete_If_Exists (Temp_Path);
               Diagnostic := To_Unbounded_String
                 ("HTTP remote verification returned status" & Natural'Image (Code));
               Report.Status := Remote_Not_Found;
               return Remote_Not_Found;
            end if;
            Status := File_Metadata (Temp_Path, True, False, Remote, Diagnostic);
            Delete_If_Exists (Temp_Path);
         end;
      end if;
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      Report.Size := Remote.Size;
      Report.Crc32 := Remote.Crc32;
      if Local.Size = Remote.Size and then Local.Crc32 = Remote.Crc32 then
         Report.Verified := True;
         Report.Status := Remote_Ok;
         return Remote_Ok;
      end if;
      Diagnostic := To_Unbounded_String
        ("remote archive metadata mismatch for " & To_String (Location.Object_Name));
      Report.Status := Remote_Metadata_Mismatch;
      return Remote_Metadata_Mismatch;
   end Verify_Remote_Archive;

   function Verify_Remote_Archive
     (URL        : String;
      Local_Path : String;
      Report     : out Transfer_Report;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
   begin
      return Verify_Remote_Archive
        (URL, Local_Path, (others => <>), Report, Diagnostic);
   end Verify_Remote_Archive;

   function Delete_Remote_Object
     (URL        : String;
      Local_Path : String;
      Object_Name : String;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
      Target   : Unbounded_String;
   begin
      Status := Parse_URL (URL, Local_Path, Location, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      if Is_Unsupported_Transfer_Transport (Location.Kind) then
         Diagnostic := To_Unbounded_String ("unsupported remote deletion transport");
         return Remote_Unsupported_Transport;
      end if;
      if not Backup.Path_Syntax.Safe_Object_Name (Object_Name) then
         Diagnostic := To_Unbounded_String
           ("remote object deletion refused for unsafe object name: '" & Object_Name & "'");
         return Remote_Delete_Refused;
      elsif not Backup.Path_Syntax.Looks_Like_Managed_Object (Object_Name) then
         Diagnostic := To_Unbounded_String
           ("remote object deletion refused outside backup namespace: '" & Object_Name & "'");
         return Remote_Delete_Refused;
      end if;
      if Location.Kind = Transport_File then
         Target := To_Unbounded_String (Join (To_String (Location.Namespace), Object_Name));
         if Ada.Directories.Exists (To_String (Target)) then
            Ada.Directories.Delete_File (To_String (Target));
         end if;
         return Remote_Ok;
      elsif Location.Kind = Transport_Google_Drive then
         Status := Delete_Google_Drive_Object
           (Location, Object_Name, Options, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
         return Remove_HTTP_Index (Location, Object_Name, Options, Diagnostic);
      elsif Location.Kind = Transport_PCloud then
         Status := Delete_PCloud_Object
           (Location, Object_Name, Options, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;
         return Remove_HTTP_Index (Location, Object_Name, Options, Diagnostic);
      elsif Location.Kind = Transport_Proton_Drive then
         declare
            SDK_Diagnostic : Unbounded_String;
            Client : constant Proton_Drive.Client :=
              Proton_Drive_Client (Location, Options, SDK_Diagnostic);
         begin
            Status := Proton_Drive_Status
              (Proton_Drive.Delete_Node
                 (Client, Proton_Drive_Remote_Path (Location, Object_Name), Diagnostic));
            if Status /= Remote_Ok then
               return Status;
            end if;
            return Remove_HTTP_Index (Location, Object_Name, Options, Diagnostic);
         end;
      elsif Location.Kind = Transport_SSH then
         declare
            Session      : SSH_Lib.Sessions.Session;
            Result       : SSH_Lib.File_Transfer.Workflow_Result;
            Close_Status : CryptoLib.Errors.Status;
         begin
            Status := SSH_Namespace_Object_Path
              (Location, Object_Name, Target, Diagnostic);
            if Status /= Remote_Ok then
               return Status;
            end if;

            Status := Open_SSH_Session
              (To_String (Location.Original_URL), Options, Session, Diagnostic);
            if Status /= Remote_Ok then
               return Status;
            end if;

            Result := SSH_Lib.File_Transfer.Delete
              (Session, To_String (Target),
               Target => SSH_Lib.File_Transfer.Delete_File);
            Close_Status := SSH_Lib.Sessions.Close (Session);
            if Result.Status = CryptoLib.Errors.No_Such_File then
               return Remote_Ok;
            elsif Result.Status /= CryptoLib.Errors.Ok then
               Diagnostic := To_Unbounded_String
                 ("SSH remote deletion failed for " & To_String (Target) &
                  ": " & SSH_Status_Image (Result.Status));
               return SSH_Status (Result.Status, Remote_Delete_Refused);
            elsif Close_Status /= CryptoLib.Errors.Ok then
               Diagnostic := To_Unbounded_String
                 ("SSH session close failed after deletion for " &
                  To_String (Target) & ": " & SSH_Status_Image (Close_Status));
               return SSH_Status (Close_Status, Remote_Delete_Refused);
            end if;
            return Remote_Ok;
         end;
      else
         declare
            Client : Http_Client.Clients.Client := Http_Client.Clients.Create;
            Request : Http_Client.Requests.Request;
            Result  : Http_Client.Clients.Client_Result;
            Target_URL : constant String := Remote_Object_URL
              ((Original_URL => Location.Original_URL,
                Kind => Location.Kind,
                Namespace => Location.Namespace,
                Object_Name => To_Unbounded_String (Object_Name)),
               Options);
            HTTP_Status : Http_Client.Errors.Result_Status;
            Code : Natural;
         begin
            Status := Configure_HTTP_Client
              (Target_URL, Options, Client, Diagnostic);
            if Status /= Remote_Ok then
               return Status;
            end if;
            Status := Prepare_HTTP_Request
              (Http_Client.Types.DELETE, Target_URL, Options, Request,
               Diagnostic, Location.Kind = Transport_S3);
            if Status /= Remote_Ok then
               return Status;
            end if;
            HTTP_Status := Http_Client.Clients.Execute (Client, Request, Result);
            if HTTP_Status /= Http_Client.Errors.Ok then
               Diagnostic := To_Unbounded_String ("HTTP remote deletion failed");
               return HTTP_Error_Status (HTTP_Status);
            end if;
            Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
            if Code /= 200 and then Code /= 202 and then Code /= 204 and then Code /= 404 then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote deletion returned status" & Natural'Image (Code));
               return Remote_Delete_Refused;
            end if;
            if Code /= 404 then
               Status := Remove_HTTP_Index (Location, Object_Name, Options, Diagnostic);
               if Status /= Remote_Ok then
                  return Status;
               end if;
            end if;
            return Remote_Ok;
         end;
      end if;
   exception
      when others =>
         Diagnostic := To_Unbounded_String ("could not delete managed remote object: '" & Object_Name & "'");
         return Remote_Delete_Refused;
   end Delete_Remote_Object;

   function Delete_Remote_Object
     (URL        : String;
      Local_Path : String;
      Object_Name : String;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
   begin
      return Delete_Remote_Object
        (URL, Local_Path, Object_Name, (others => <>), Diagnostic);
   end Delete_Remote_Object;

   function Check_PCloud_Remote
     (URL        : String;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
      HTTP_Options : Remote_Options;
      Result   : Http_Client.Clients.Client_Result;
      Code     : Natural := 0;
      Folder_Id : Unbounded_String;
      Quota_Text : Unbounded_String;
      Used_Text  : Unbounded_String;
      Free_Text  : Unbounded_String;
   begin
      Status := Parse_URL (URL, "backup-pcloud-check.zip", Location, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      if Location.Kind /= Transport_PCloud then
         Diagnostic := To_Unbounded_String
           ("pCloud preflight is only supported for pCloud remotes");
         return Remote_Unsupported_Transport;
      end if;

      HTTP_Options := PCloud_HTTP_Options (Options, Diagnostic);
      if Length (HTTP_Options.PCloud_Access_Token) = 0 then
         Diagnostic := To_Unbounded_String ("pCloud access token is required");
         return Remote_Authentication_Failed;
      end if;

      Status := HTTP_Get
        (PCloud_API_URL (HTTP_Options, "userinfo"), HTTP_Options, Result, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      declare
         Response_Body : constant String := Http_Client.Clients.Response_Text (Result);
         Result_Code : constant Natural := PCloud_Result_Code (Response_Body);
      begin
         if Code = 401 or else Code = 403
           or else PCloud_Authentication_Result (Result_Code)
         then
            Diagnostic := To_Unbounded_String
              (PCloud_Error_Diagnostic ("userinfo", Code, Response_Body));
            return Remote_Authentication_Failed;
         elsif Code /= 200 or else Result_Code /= 0 then
            Diagnostic := To_Unbounded_String
              (PCloud_Error_Diagnostic ("userinfo", Code, Response_Body));
            return Remote_Read_Failed;
         end if;

         Quota_Text := To_Unbounded_String
           (PCloud_JSON_Field_Value (Response_Body, "quota"));
         Used_Text := To_Unbounded_String
           (PCloud_JSON_Field_Value (Response_Body, "usedquota"));
         Free_Text := To_Unbounded_String
           (PCloud_JSON_Field_Value (Response_Body, "freequota"));
      end;

      Folder_Id := To_Unbounded_String
        (PCloud_Target_Folder_Id (Location, HTTP_Options, False, Diagnostic));
      if Length (Folder_Id) = 0 then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String ("pCloud namespace was not found");
         end if;
         return Remote_Not_Found;
      end if;

      Diagnostic := To_Unbounded_String
        ("pCloud preflight ok" & ASCII.LF &
         "api_base=" & PCloud_API_Base (HTTP_Options) & ASCII.LF &
         "folderid=" & To_String (Folder_Id) &
         (if Length (Quota_Text) > 0 then
            ASCII.LF & "quota=" & To_String (Quota_Text)
          else "") &
         (if Length (Used_Text) > 0 then
            ASCII.LF & "usedquota=" & To_String (Used_Text)
          else "") &
         (if Length (Free_Text) > 0 then
            ASCII.LF & "freequota=" & To_String (Free_Text)
          else "") & ASCII.LF);
      return Remote_Ok;
   end Check_PCloud_Remote;

   function Cleanup_Remote_Temporary_Objects
     (URL        : String;
      Options    : Remote_Options;
      Deleted    : out Natural;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
   begin
      Deleted := 0;
      Status := Parse_URL (URL, "backup-pcloud-clean-temp.zip", Location, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      if Location.Kind /= Transport_PCloud then
         Diagnostic := To_Unbounded_String
           ("temporary remote cleanup is only supported for pCloud remotes");
         return Remote_Unsupported_Transport;
      end if;
      return Cleanup_PCloud_Temporary_Objects
        (Location, Options, Deleted, Diagnostic);
   end Cleanup_Remote_Temporary_Objects;

   function Upload_Archive
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Report     : out Transfer_Report;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
      Local_Metadata : Archive_Metadata;
      Partial_Metadata : Archive_Metadata;
      Temp_Path : Unbounded_String;
   begin
      Status := Parse_URL (URL, Local_Path, Location, Diagnostic);
      Report := (Status        => Status,
                 Transport     => Location.Kind,
                 Remote_URL    => To_Unbounded_String (URL),
                 Local_Path    => To_Unbounded_String (Local_Path),
                 Remote_Object => Location.Object_Name,
                 Size          => 0,
                 Crc32         => 0,
                 Atomic        => False,
                 Resumed       => False,
                 Verified      => False,
                 Retried       => 0,
                 PCloud_Progress_Samples => 0);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      if Is_Unsupported_Transfer_Transport (Location.Kind) then
         Diagnostic := To_Unbounded_String ("unsupported remote upload transport");
         Report.Status := Remote_Unsupported_Transport;
         return Remote_Unsupported_Transport;
      end if;
      if not Ada.Directories.Exists (Local_Path) then
         Diagnostic := To_Unbounded_String ("local archive does not exist: " & Local_Path);
         Report.Status := Remote_Not_Found;
         return Remote_Not_Found;
      end if;
      if Options.Require_Encrypted and then not Backup.Encryption.Is_Encrypted (Local_Path) then
         Diagnostic := To_Unbounded_String
           ("remote upload requires an encrypted archive, but local archive is plaintext: " & Local_Path);
         Report.Status := Remote_Encryption_Required;
         return Remote_Encryption_Required;
      end if;
      Status := File_Metadata (Local_Path, True, False, Local_Metadata, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      Report.Size := Local_Metadata.Size;
      Report.Crc32 := Local_Metadata.Crc32;

      if Location.Kind = Transport_Google_Drive then
         declare
            Retry_Total : Natural;
            Index_Status : Remote_Status;
            Index_Item : constant Archive_Metadata :=
              (Archive_Id     => Location.Object_Name,
               Size           => Local_Metadata.Size,
               Crc32          => Local_Metadata.Crc32,
               Has_Timestamp  => Local_Metadata.Has_Timestamp,
               Timestamp      => Local_Metadata.Timestamp,
               Managed        => True,
               Partial        => False);
         begin
            Status := Upload_Google_Drive_File
              (Location, To_String (Location.Object_Name), Local_Path,
               Local_Metadata.Size, Local_Metadata.Crc32, "application/zip",
               Options, Report, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Retry_Total := Report.Retried;
            Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
            Report.Atomic := False;
            Report.Retried := Retry_Total;
            if Status /= Remote_Ok then
               return Status;
            end if;
            Index_Status := Upsert_HTTP_Index (Location, Index_Item, Options, Diagnostic);
            if Index_Status /= Remote_Ok then
               Report.Status := Index_Status;
               return Index_Status;
            end if;
            Report.Status := Remote_Ok;
            return Remote_Ok;
         end;
      elsif Location.Kind = Transport_PCloud then
         declare
            Retry_Total : Natural;
            Was_Resumed : Boolean;
            Progress_Samples : Natural;
            Index_Status : Remote_Status;
            Index_Item : constant Archive_Metadata :=
              (Archive_Id     => Location.Object_Name,
               Size           => Local_Metadata.Size,
               Crc32          => Local_Metadata.Crc32,
               Has_Timestamp  => Local_Metadata.Has_Timestamp,
               Timestamp      => Local_Metadata.Timestamp,
               Managed        => True,
               Partial        => False);
         begin
            Status := Upload_PCloud_File
              (Location, To_String (Location.Object_Name), Local_Path,
               Local_Metadata.Size, Options, Report, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Retry_Total := Report.Retried;
            Was_Resumed := Report.Resumed;
            Progress_Samples := Report.PCloud_Progress_Samples;
            Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
            Report.Atomic := False;
            Report.Retried := Retry_Total;
            Report.Resumed := Was_Resumed;
            Report.PCloud_Progress_Samples := Progress_Samples;
            if Status /= Remote_Ok then
               return Status;
            end if;
            Index_Status := Upsert_HTTP_Index (Location, Index_Item, Options, Diagnostic);
            if Index_Status /= Remote_Ok then
               Report.Status := Index_Status;
               return Index_Status;
            end if;
            Report.Status := Remote_Ok;
            return Remote_Ok;
         end;
      elsif Location.Kind = Transport_Proton_Drive then
         declare
            Retry_Total : constant Natural := Report.Retried;
            Index_Status : Remote_Status;
            SDK_Diagnostic : Unbounded_String;
            Client : constant Proton_Drive.Client :=
              Proton_Drive_Client (Location, Options, SDK_Diagnostic);
            Index_Item : constant Archive_Metadata :=
              (Archive_Id     => Location.Object_Name,
               Size           => Local_Metadata.Size,
               Crc32          => Local_Metadata.Crc32,
               Has_Timestamp  => Local_Metadata.Has_Timestamp,
               Timestamp      => Local_Metadata.Timestamp,
               Managed        => True,
               Partial        => False);
         begin
            Status := Proton_Drive_Status
              (Proton_Drive.Upload_File
                 (Client, To_String (Location.Namespace), Local_Path,
                  To_String (Location.Object_Name), Diagnostic));
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
            Report.Atomic := False;
            Report.Retried := Retry_Total;
            if Status /= Remote_Ok then
               return Status;
            end if;
            Index_Status := Upsert_HTTP_Index (Location, Index_Item, Options, Diagnostic);
            if Index_Status /= Remote_Ok then
               Report.Status := Index_Status;
               return Index_Status;
            end if;
            Report.Status := Remote_Ok;
            return Remote_Ok;
         end;
      elsif Location.Kind = Transport_SSH then
         declare
            Remote_Path     : Unbounded_String;
            Remote_Metadata : Archive_Metadata;
            Session         : SSH_Lib.Sessions.Session;
            Probe          : SSH_Lib.File_Transfer.Workflow_Result;
            Result         : SSH_Lib.File_Transfer.Workflow_Result;
            Resume_Result  : CryptoLib.Errors.Status := CryptoLib.Errors.Ok;
            Close_Status   : CryptoLib.Errors.Status;
            Retry_Total    : Natural := 0;
            Was_Resumed    : Boolean := False;
            Was_Atomic     : Boolean := False;
            Need_Full_Upload : Boolean := True;
         begin
            Status := SSH_Object_Path (Location, Remote_Path, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;

            Status := Open_SSH_Session
              (To_String (Location.Original_URL), Options, Session, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;

            if Resume_Upload_Enabled (Options.Upload_Behavior) then
               Probe := SSH_Lib.File_Transfer.Verify
                 (Session, To_String (Remote_Path));
               if Probe.Status = CryptoLib.Errors.No_Such_File then
                  Need_Full_Upload := True;
               elsif Probe.Status /= CryptoLib.Errors.Ok then
                  declare
                     Ignored_Close_Status : constant CryptoLib.Errors.Status :=
                       SSH_Lib.Sessions.Close (Session);
                     pragma Unreferenced (Ignored_Close_Status);
                  begin
                     null;
                  end;
                  Diagnostic := To_Unbounded_String
                    ("SSH remote resume probe failed for " &
                     To_String (Remote_Path) & ": " &
                     SSH_Status_Image (Probe.Status));
                  Report.Status := SSH_Status (Probe.Status, Remote_Write_Failed);
                  return Report.Status;
               elsif Probe.Bytes_Processed = Local_Metadata.Size then
                  Status := SSH_Restore_Metadata
                    (Session, To_String (Remote_Path),
                     Local_Path & ".ssh-resume.tmp",
                     To_String (Location.Object_Name), False,
                     Options, Remote_Metadata, Diagnostic);
                  if Status = Remote_Ok
                    and then Remote_Metadata.Size = Local_Metadata.Size
                    and then Remote_Metadata.Crc32 = Local_Metadata.Crc32
                  then
                     Report.Resumed := True;
                     Need_Full_Upload := False;
                  else
                     Need_Full_Upload := True;
                     Diagnostic := Null_Unbounded_String;
                  end if;
               elsif Probe.Bytes_Processed < Local_Metadata.Size then
                  Resume_Result := SSH_Lib.File_Transfer.Resume_Upload_File
                    (Session, To_String (Remote_Path), Local_Path,
                     Options => SSH_Transfer_Options (Options));
                  if Resume_Result /= CryptoLib.Errors.Ok then
                     declare
                        Ignored_Close_Status : constant CryptoLib.Errors.Status :=
                          SSH_Lib.Sessions.Close (Session);
                        pragma Unreferenced (Ignored_Close_Status);
                     begin
                        null;
                     end;
                     Diagnostic := To_Unbounded_String
                       ("SSH remote resume upload failed for " &
                        To_String (Remote_Path) & ": " &
                        SSH_Status_Image (Resume_Result));
                     Report.Status := SSH_Status
                       (Resume_Result, Remote_Write_Failed);
                     return Report.Status;
                  end if;
                  Report.Resumed := True;
                  Need_Full_Upload := False;
               else
                  Need_Full_Upload := True;
               end if;
            end if;

            if Need_Full_Upload then
               Result := SSH_Lib.File_Transfer.Upload
                 (Session, Local_Path, To_String (Remote_Path),
                  Transfer => SSH_Transfer_Options
                    (Options, Use_Atomic_Upload => True));
               if Result.Status /= CryptoLib.Errors.Ok then
                  declare
                     Ignored_Close_Status : constant CryptoLib.Errors.Status :=
                       SSH_Lib.Sessions.Close (Session);
                     pragma Unreferenced (Ignored_Close_Status);
                  begin
                     null;
                  end;
                  Diagnostic := To_Unbounded_String
                    ("SSH remote upload failed for " & To_String (Remote_Path) &
                     ": " & SSH_Status_Image (Result.Status));
                  Report.Status := SSH_Status (Result.Status, Remote_Write_Failed);
                  return Report.Status;
               end if;
               Was_Atomic := True;
            end if;

            Close_Status := SSH_Lib.Sessions.Close (Session);
            if Close_Status /= CryptoLib.Errors.Ok then
               Diagnostic := To_Unbounded_String
                 ("SSH session close failed after upload for " &
                  To_String (Remote_Path) & ": " &
                  SSH_Status_Image (Close_Status));
               Report.Status := SSH_Status (Close_Status, Remote_Write_Failed);
               return Report.Status;
            end if;

            Was_Resumed := Report.Resumed;
            Retry_Total := Report.Retried;
            Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
            Report.Atomic := Was_Atomic;
            Report.Resumed := Was_Resumed;
            Report.Retried := Retry_Total;
            return Status;
         end;
      end if;

      if Is_HTTP_Transport (Location.Kind) then
         declare
            Result : Http_Client.Clients.Client_Result;
            Retry_Total : Natural;
            Index_Status : Remote_Status;
            Index_Item : constant Archive_Metadata :=
              (Archive_Id     => Location.Object_Name,
               Size           => Local_Metadata.Size,
               Crc32          => Local_Metadata.Crc32,
               Has_Timestamp  => Local_Metadata.Has_Timestamp,
               Timestamp      => Local_Metadata.Timestamp,
               Managed        => True,
               Partial        => False);
         begin
            if Location.Kind = Transport_S3
              and then Options.S3_Multipart_Threshold > 0
              and then Local_Metadata.Size >= Interfaces.Unsigned_64 (Options.S3_Multipart_Threshold)
            then
               Status := Stream_S3_Multipart_Upload
                 (Location, Remote_Object_URL (Location, Options), Local_Path,
                  Local_Metadata.Size, Decimal_32 (Local_Metadata.Crc32), Options,
                  Report, Diagnostic);
            else
               Status := Stream_HTTP_Put_With_Retry
                 (Remote_Object_URL (Location, Options), Local_Path, Local_Metadata.Size,
                  (if Location.Kind = Transport_S3 then Decimal_32 (Local_Metadata.Crc32) else ""),
                  Local_Metadata.Crc32, Options, Report, Result, Diagnostic,
                  Location.Kind = Transport_S3);
            end if;
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            Retry_Total := Report.Retried;
            Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
            Report.Atomic := False;
            Report.Retried := Retry_Total;
            if Status /= Remote_Ok then
               return Status;
            end if;
            Index_Status := Upsert_HTTP_Index (Location, Index_Item, Options, Diagnostic);
            if Index_Status /= Remote_Ok then
               Report.Status := Index_Status;
               return Index_Status;
            end if;
            Report.Status := Remote_Ok;
            return Remote_Ok;
         end;
      end if;

      begin
         Ensure_Namespace (To_String (Location.Namespace));
         Temp_Path := To_Unbounded_String (Remote_Object_Path (Location) & ".partial");
         if Ada.Directories.Exists (To_String (Temp_Path)) then
            if Resume_Upload_Enabled (Options.Upload_Behavior) then
               Status := File_Metadata
                 (To_String (Temp_Path), True, True, Partial_Metadata, Diagnostic);
               if Status = Remote_Ok
                 and then Partial_Metadata.Size = Local_Metadata.Size
                 and then Partial_Metadata.Crc32 = Local_Metadata.Crc32
               then
                  if not Move_Temp_To_Final (To_String (Temp_Path), Remote_Object_Path (Location)) then
                     raise Program_Error;
                  end if;
                  Report.Resumed := True;
               else
                  Delete_If_Exists (To_String (Temp_Path));
               end if;
            else
               Delete_If_Exists (To_String (Temp_Path));
            end if;
         end if;
         if not Report.Resumed then
            Status := Copy_With_Retry
              (Local_Path, To_String (Temp_Path), Options, Report, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
            if not Move_Temp_To_Final (To_String (Temp_Path), Remote_Object_Path (Location)) then
               raise Program_Error;
            end if;
         end if;
         Report.Atomic := True;
      exception
         when others =>
            Delete_If_Exists (To_String (Temp_Path));
            Diagnostic := To_Unbounded_String
              ("could not upload archive to remote object: " & Remote_Object_Path (Location));
            Report.Status := Remote_Copy_Failed;
            return Remote_Copy_Failed;
      end;

      declare
         Was_Resumed : constant Boolean := Report.Resumed;
         Retry_Total : constant Natural := Report.Retried;
      begin
         Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
         Report.Atomic := True;
         Report.Resumed := Was_Resumed;
         Report.Retried := Retry_Total;
         return Status;
      end;
   end Upload_Archive;

   function Download_Archive
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Report     : out Transfer_Report;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
      Downloaded_Metadata : Archive_Metadata;
      Temp_Path : constant String := Local_Path & ".partial";
   begin
      Status := Parse_URL (URL, Local_Path, Location, Diagnostic);
      Report := (Status        => Status,
                 Transport     => Location.Kind,
                 Remote_URL    => To_Unbounded_String (URL),
                 Local_Path    => To_Unbounded_String (Local_Path),
                 Remote_Object => Location.Object_Name,
                 Size          => 0,
                 Crc32         => 0,
                 Atomic        => False,
                 Resumed       => False,
                 Verified      => False,
                 Retried       => 0,
                 PCloud_Progress_Samples => 0);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      if Is_Unsupported_Transfer_Transport (Location.Kind) then
         Diagnostic := To_Unbounded_String ("unsupported remote restore transport");
         Report.Status := Remote_Unsupported_Transport;
         return Remote_Unsupported_Transport;
      end if;
      if Location.Kind = Transport_Google_Drive then
         Status := Download_Google_Drive_Object
           (Location, To_String (Location.Object_Name), Local_Path,
            Options, Diagnostic);
         if Status /= Remote_Ok then
            Report.Status := Status;
            return Status;
         end if;
      elsif Location.Kind = Transport_PCloud then
         Status := Download_PCloud_Object
           (Location, To_String (Location.Object_Name), Local_Path,
            Options, Diagnostic);
         if Status /= Remote_Ok then
            Report.Status := Status;
            return Status;
         end if;
      elsif Location.Kind = Transport_Proton_Drive then
         declare
            SDK_Diagnostic : Unbounded_String;
            Client : constant Proton_Drive.Client :=
              Proton_Drive_Client (Location, Options, SDK_Diagnostic);
         begin
            Status := Proton_Drive_Status
              (Proton_Drive.Download_File
                 (Client, Proton_Drive_Remote_Path
                    (Location, To_String (Location.Object_Name)),
                  Local_Path, Diagnostic));
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;
         end;
      elsif Location.Kind = Transport_SSH then
         declare
            Remote_Path  : Unbounded_String;
            Session      : SSH_Lib.Sessions.Session;
            Result       : SSH_Lib.File_Transfer.Workflow_Result;
            Close_Status : CryptoLib.Errors.Status;
         begin
            Status := SSH_Object_Path (Location, Remote_Path, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;

            Status := Open_SSH_Session
              (To_String (Location.Original_URL), Options, Session, Diagnostic);
            if Status /= Remote_Ok then
               Report.Status := Status;
               return Status;
            end if;

            Delete_If_Exists (Temp_Path);
            Result := SSH_Lib.File_Transfer.Restore
              (Session, To_String (Remote_Path), Temp_Path,
               Recursive => False,
               Policy    => SSH_Lib.File_Transfer.Overwrite_Existing,
               Transfer  => SSH_Transfer_Options (Options));
            Close_Status := SSH_Lib.Sessions.Close (Session);
            if Result.Status /= CryptoLib.Errors.Ok then
               Delete_If_Exists (Temp_Path);
               Diagnostic := To_Unbounded_String
                 ("SSH remote restore failed for " & To_String (Remote_Path) &
                  ": " & SSH_Status_Image (Result.Status));
               Report.Status := SSH_Status (Result.Status, Remote_Read_Failed);
               return Report.Status;
            elsif Close_Status /= CryptoLib.Errors.Ok then
               Delete_If_Exists (Temp_Path);
               Diagnostic := To_Unbounded_String
                 ("SSH session close failed after restore for " &
                  To_String (Remote_Path) & ": " &
                  SSH_Status_Image (Close_Status));
               Report.Status := SSH_Status (Close_Status, Remote_Read_Failed);
               return Report.Status;
            elsif not Move_Temp_To_Final (Temp_Path, Local_Path) then
               Delete_If_Exists (Temp_Path);
               Diagnostic := To_Unbounded_String
                 ("could not restore SSH remote archive to local path: " &
                  Local_Path);
               Report.Status := Remote_Copy_Failed;
               return Remote_Copy_Failed;
            end if;
            Report.Atomic := True;
         end;
      elsif Is_HTTP_Transport (Location.Kind) then
         declare
            Download : Http_Client.Clients.Download_Result;
            Code     : Natural := 0;
         begin
            Status := HTTP_Download_To_File
              (Remote_Object_URL (Location, Options), Local_Path, Options, Download,
               Diagnostic, Location.Kind = Transport_S3);
            if Status /= Remote_Ok then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("HTTP remote download failed for " & Remote_Object_URL (Location, Options));
               else
                  Diagnostic := To_Unbounded_String
                    ("HTTP remote download failed for " &
                     Remote_Object_URL (Location, Options) & ": " & To_String (Diagnostic));
               end if;
               Report.Status := Status;
               return Status;
            end if;
            Code := Download.HTTP_Status_Code;
            if not HTTP_Status_OK (Code) then
               Diagnostic := To_Unbounded_String
                 ("HTTP remote download returned status" & Natural'Image (Code));
               Report.Status := Remote_Not_Found;
               return Remote_Not_Found;
            end if;
         end;
      else
         if not Ada.Directories.Exists (Remote_Object_Path (Location)) then
            Diagnostic := To_Unbounded_String
              ("remote archive does not exist: " & Remote_Object_Path (Location));
            Report.Status := Remote_Not_Found;
            return Remote_Not_Found;
         end if;
         Delete_If_Exists (Temp_Path);
         Status := Copy_With_Retry
           (Remote_Object_Path (Location), Temp_Path, Options, Report, Diagnostic);
         if Status /= Remote_Ok then
            Report.Status := Status;
            return Status;
         end if;
         if not Move_Temp_To_Final (Temp_Path, Local_Path) then
            Diagnostic := To_Unbounded_String
              ("could not restore remote archive to local path: " & Local_Path);
            Report.Status := Remote_Copy_Failed;
            return Remote_Copy_Failed;
         end if;
         Report.Atomic := True;
      end if;
      Status := File_Metadata (Local_Path, True, False, Downloaded_Metadata, Diagnostic);
      if Status /= Remote_Ok then
         Report.Status := Status;
         return Status;
      end if;
      Report.Size := Downloaded_Metadata.Size;
      Report.Crc32 := Downloaded_Metadata.Crc32;
      declare
         Retry_Total : constant Natural := Report.Retried;
      begin
         Status := Verify_Remote_Archive (URL, Local_Path, Options, Report, Diagnostic);
         Report.Retried := Retry_Total;
         return Status;
      end;
   end Download_Archive;

   function Read_Inventory
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Inventory  : out Archive_Metadata_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Remote_Status
   is
      Location : Remote_Location;
      Status   : Remote_Status;
      Search         : Ada.Directories.Search_Type;
      Search_Started : Boolean := False;
      Dir_Entry      : Ada.Directories.Directory_Entry_Type;
      Pattern        : constant String := "*";
      Metadata       : Archive_Metadata;
   begin
      Inventory.Clear;
      Status := Parse_URL (URL, Local_Path, Location, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      if Is_Unsupported_Transfer_Transport (Location.Kind) then
         Diagnostic := To_Unbounded_String
           ("unsupported remote inventory transport");
         return Remote_Unsupported_Transport;
      end if;

      if Location.Kind = Transport_SSH then
         return Read_SSH_Inventory
           (Location, Local_Path, Options, Inventory, Diagnostic);
      elsif Is_HTTP_Transport (Location.Kind) then
         return Read_HTTP_Inventory (Location, Inventory, Options, Diagnostic);
      end if;

      if not Ada.Directories.Exists (To_String (Location.Namespace)) then
         return Remote_Ok;
      end if;

      begin
         Ada.Directories.Start_Search
           (Search, To_String (Location.Namespace), Pattern,
            [Ada.Directories.Ordinary_File => True, others => False]);
         Search_Started := True;

         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
            declare
               Full : constant String := Ada.Directories.Full_Name (Dir_Entry);
               Name : constant String :=
                 Ada.Directories.Simple_Name (Dir_Entry);
               Partial : constant Boolean := Ends_With (Name, ".partial");
            begin
               if Backup.Path_Syntax.Looks_Like_Managed_Object (Name)
                 and then Backup.Path_Syntax.Safe_Object_Name (Name)
               then
                  Status := File_Metadata (Full, True, Partial, Metadata, Diagnostic);
                  if Status /= Remote_Ok then
                     End_Search_Quietly (Search);
                     Search_Started := False;
                     return Status;
                  end if;
                  Inventory.Append (Metadata);
               end if;
            end;
         end loop;
         End_Search_Quietly (Search);
         Search_Started := False;
      exception
         when others =>
            if Search_Started then
               End_Search_Quietly (Search);
            end if;
            Diagnostic := To_Unbounded_String
              ("could not read remote inventory: " &
               Remote_Index_URL (Location, Options));
            return Remote_Read_Failed;
      end;

      return Remote_Ok;
   end Read_Inventory;

   procedure Sort_Inventory (Set : in out Archive_Metadata_Vectors.Vector) is
      Swapped : Boolean;
   begin
      if Set.Length < 2 then
         return;
      end if;

      loop
         Swapped := False;
         for Index in Set.First_Index .. Set.Last_Index - 1 loop
            if To_String (Set.Element (Index).Archive_Id)
              > To_String (Set.Element (Index + 1).Archive_Id)
            then
               declare
                  Left  : constant Archive_Metadata := Set.Element (Index);
                  Right : constant Archive_Metadata := Set.Element (Index + 1);
               begin
                  Set.Replace_Element (Index, Right);
                  Set.Replace_Element (Index + 1, Left);
               end;
               Swapped := True;
            end if;
         end loop;
         exit when not Swapped;
      end loop;
   end Sort_Inventory;

   function Index_Timestamp_Image (Item : Archive_Metadata) return String is
      Year    : Ada.Calendar.Year_Number;
      Month   : Ada.Calendar.Month_Number;
      Day     : Ada.Calendar.Day_Number;
      Seconds : Ada.Calendar.Day_Duration;
      Total   : Natural;
      Hour    : Natural;
      Minute  : Natural;
      Second  : Natural;

      function Two_Digits (Value : Natural) return String is
      begin
         return String'
           (1 => Character'Val (Character'Pos ('0') + (Value / 10) mod 10),
            2 => Character'Val (Character'Pos ('0') + Value mod 10));
      end Two_Digits;

      function Four_Digits (Value : Natural) return String is
      begin
         return String'
           (1 => Character'Val (Character'Pos ('0') + (Value / 1_000) mod 10),
            2 => Character'Val (Character'Pos ('0') + (Value / 100) mod 10),
            3 => Character'Val (Character'Pos ('0') + (Value / 10) mod 10),
            4 => Character'Val (Character'Pos ('0') + Value mod 10));
      end Four_Digits;
   begin
      if not Item.Has_Timestamp then
         return "-";
      end if;

      Ada.Calendar.Split (Item.Timestamp, Year, Month, Day, Seconds);
      Total := Natural (Seconds);
      Hour := Total / 3_600;
      Minute := (Total mod 3_600) / 60;
      Second := Total mod 60;

      return Four_Digits (Natural (Year)) & "-" &
        Two_Digits (Natural (Month)) & "-" &
        Two_Digits (Natural (Day)) & "T" &
        Two_Digits (Hour) & ":" & Two_Digits (Minute) & ":" &
        Two_Digits (Second) & "Z";
   end Index_Timestamp_Image;

   function Build_HTTP_Index
     (Inventory : Archive_Metadata_Vectors.Vector) return String
   is
      Sorted : Archive_Metadata_Vectors.Vector := Inventory;
      Text   : Unbounded_String := To_Unbounded_String
        ("backup-remote-index-v1" & Ada.Characters.Latin_1.LF);
   begin
      Sort_Inventory (Sorted);
      for Item of Sorted loop
         if Item.Managed
           and then Backup.Path_Syntax.Looks_Like_Managed_Object (To_String (Item.Archive_Id))
           and then Backup.Path_Syntax.Safe_Object_Name (To_String (Item.Archive_Id))
         then
            Append (Text, To_String (Item.Archive_Id));
            Append (Text, Ada.Characters.Latin_1.HT);
            Append (Text, Decimal (Item.Size));
            Append (Text, Ada.Characters.Latin_1.HT);
            Append (Text, Decimal_32 (Item.Crc32));
            Append (Text, Ada.Characters.Latin_1.HT);
            Append (Text, Index_Timestamp_Image (Item));
            Append (Text, Ada.Characters.Latin_1.LF);
         end if;
      end loop;
      return To_String (Text);
   end Build_HTTP_Index;

   procedure Upsert_HTTP_Index_Item
     (Inventory : in out Archive_Metadata_Vectors.Vector;
      Item      : Archive_Metadata)
   is
   begin
      if Inventory.Is_Empty then
         Inventory.Append (Item);
         return;
      end if;

      for Index in Inventory.First_Index .. Inventory.Last_Index loop
         if To_String (Inventory.Element (Index).Archive_Id) =
           To_String (Item.Archive_Id)
         then
            Inventory.Replace_Element (Index, Item);
            return;
         end if;
      end loop;

      Inventory.Append (Item);
   end Upsert_HTTP_Index_Item;

   procedure Remove_HTTP_Index_Item
     (Inventory : in out Archive_Metadata_Vectors.Vector;
      Name      : String)
   is
   begin
      if Inventory.Is_Empty then
         return;
      end if;

      for Index in reverse Inventory.First_Index .. Inventory.Last_Index loop
         if To_String (Inventory.Element (Index).Archive_Id) = Name then
            Inventory.Delete (Index);
         end if;
      end loop;
   end Remove_HTTP_Index_Item;

   function Publish_HTTP_Index
     (Location   : Remote_Location;
      Inventory  : Archive_Metadata_Vectors.Vector;
      Validator  : HTTP_Index_Validator;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return HTTP_Index_Publish_Result
   is
      Result      : Http_Client.Clients.Client_Result;
      HTTP_Status : Http_Client.Errors.Result_Status;
      Code        : Natural := 0;
      URI         : Http_Client.URI.URI_Reference;
      Headers     : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
      Request     : Http_Client.Requests.Request;
      Client      : Http_Client.Clients.Client := Http_Client.Clients.Create;
      Client_Status : Remote_Status;
      Payload     : constant String := Build_HTTP_Index (Inventory);
   begin
      if Location.Kind = Transport_Google_Drive then
         declare
            Status : constant Remote_Status := Upload_Google_Drive_Object
              (Location, "backup-remote-index-v1", Payload, "text/plain",
               Options, Diagnostic);
         begin
            if Status = Remote_Ok then
               return HTTP_Index_Published;
            else
               return HTTP_Index_Failed;
            end if;
         end;
      elsif Location.Kind = Transport_PCloud then
         declare
            Status : constant Remote_Status := Upload_PCloud_Object
              (Location, "backup-remote-index-v1", Payload, "text/plain",
               Options, Diagnostic);
         begin
            if Status = Remote_Ok then
               return HTTP_Index_Published;
            else
               return HTTP_Index_Failed;
            end if;
         end;
      end if;

      Client_Status := Configure_HTTP_Client
        (Remote_Index_URL (Location, Options), Options, Client, Diagnostic);
      if Client_Status /= Remote_Ok then
         return HTTP_Index_Failed;
      end if;

      HTTP_Status := Http_Client.URI.Parse (Remote_Index_URL (Location, Options), URI);
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Headers.Set
           (Headers, "Content-Type", "text/plain");
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         declare
            Auth_Status : Remote_Status;
         begin
            if Location.Kind = Transport_S3 then
               Auth_Status := Add_S3_Auth_Headers
                 (Http_Client.Types.PUT, Remote_Index_URL (Location, Options),
                  Options, Headers, Diagnostic, True);
            else
               Auth_Status := Add_HTTP_Auth_Headers
                 (Options, Headers, Diagnostic);
            end if;
            if Auth_Status /= Remote_Ok then
               Diagnostic := To_Unbounded_String ("HTTP remote index auth failed");
               return HTTP_Index_Failed;
            end if;
         end;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         if Validator.Has_ETag then
            HTTP_Status := Http_Client.Headers.Set
              (Headers, "If-Match", To_String (Validator.ETag));
         elsif not Validator.Found then
            HTTP_Status := Http_Client.Headers.Set
              (Headers, "If-None-Match", "*");
         end if;
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Create
           (Method  => Http_Client.Types.PUT,
            URI     => URI,
            Item    => Request,
            Headers => Headers);
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Requests.Set_Body
           (Request, Http_Client.Request_Bodies.From_String (Payload));
      end if;
      if HTTP_Status = Http_Client.Errors.Ok then
         HTTP_Status := Http_Client.Clients.Execute
           (Client, Request, Result);
      end if;

      if HTTP_Status /= Http_Client.Errors.Ok then
         Diagnostic := To_Unbounded_String
           ("HTTP remote index publish failed for " &
            Remote_Index_URL (Location, Options));
         return HTTP_Index_Failed;
      end if;

      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code = 409 or else Code = 412 then
         Diagnostic := To_Unbounded_String
           ("HTTP remote index changed before conditional publish");
         return HTTP_Index_Conflict;
      elsif not HTTP_Status_OK (Code, For_Upload => True) then
         Diagnostic := To_Unbounded_String
           ("HTTP remote index publish returned status" & Natural'Image (Code));
         return HTTP_Index_Failed;
      end if;

      return HTTP_Index_Published;
   end Publish_HTTP_Index;

   function Upsert_HTTP_Index
     (Location   : Remote_Location;
      Item       : Archive_Metadata;
      Options    : Remote_Options;
      Diagnostic : out Unbounded_String) return Remote_Status
   is
      Inventory : Archive_Metadata_Vectors.Vector;
      Validator : HTTP_Index_Validator;
      Status    : Remote_Status;
      Publish   : HTTP_Index_Publish_Result;
   begin
      for Attempt in Natural range 0 .. HTTP_Index_Conflict_Retry_Limit loop
         Inventory.Clear;
         Status := Read_HTTP_Inventory
           (Location, Inventory, Validator, Options, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;

         Upsert_HTTP_Index_Item (Inventory, Item);
         Publish := Publish_HTTP_Index
           (Location, Inventory, Validator, Options, Diagnostic);
         case Publish is
            when HTTP_Index_Published =>
               return Remote_Ok;
            when HTTP_Index_Conflict =>
               if Attempt = HTTP_Index_Conflict_Retry_Limit then
                  Diagnostic := To_Unbounded_String
                    ("HTTP remote index changed before conditional publish after" &
                     Natural'Image (Attempt + 1) & " attempt(s)");
                  return Remote_Write_Failed;
               end if;
            when HTTP_Index_Failed =>
               return Remote_Write_Failed;
         end case;
      end loop;

      Diagnostic := To_Unbounded_String ("HTTP remote index retry loop did not run");
      return Remote_Write_Failed;
   end Upsert_HTTP_Index;

   function Remove_HTTP_Index
     (Location    : Remote_Location;
      Object_Name : String;
      Options     : Remote_Options;
      Diagnostic  : out Unbounded_String) return Remote_Status
   is
      Inventory : Archive_Metadata_Vectors.Vector;
      Validator : HTTP_Index_Validator;
      Status    : Remote_Status;
      Publish   : HTTP_Index_Publish_Result;
   begin
      for Attempt in Natural range 0 .. HTTP_Index_Conflict_Retry_Limit loop
         Inventory.Clear;
         Status := Read_HTTP_Inventory
           (Location, Inventory, Validator, Options, Diagnostic);
         if Status /= Remote_Ok then
            return Status;
         end if;

         Remove_HTTP_Index_Item (Inventory, Object_Name);
         Publish := Publish_HTTP_Index
           (Location, Inventory, Validator, Options, Diagnostic);
         case Publish is
            when HTTP_Index_Published =>
               return Remote_Ok;
            when HTTP_Index_Conflict =>
               if Attempt = HTTP_Index_Conflict_Retry_Limit then
                  Diagnostic := To_Unbounded_String
                    ("HTTP remote index changed before conditional publish after" &
                     Natural'Image (Attempt + 1) & " attempt(s)");
                  return Remote_Write_Failed;
               end if;
            when HTTP_Index_Failed =>
               return Remote_Write_Failed;
         end case;
      end loop;

      Diagnostic := To_Unbounded_String ("HTTP remote index retry loop did not run");
      return Remote_Write_Failed;
   end Remove_HTTP_Index;

   function Read_Inventory
     (URL        : String;
      Local_Path : String;
      Inventory  : out Archive_Metadata_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Remote_Status
   is
   begin
      return Read_Inventory
        (URL, Local_Path, (others => <>), Inventory, Diagnostic);
   end Read_Inventory;

   function Presign_S3_URL
     (URL             : String;
      Local_Path      : String;
      Options         : Remote_Options;
      Method          : S3_Presign_Method;
      Expires_Seconds : Natural;
      Presigned_URL   : out Unbounded_String;
      Diagnostic      : out Unbounded_String) return Remote_Status
   is
      Location   : Remote_Location;
      Resolved   : Remote_Options := Options;
      Status     : Remote_Status;
      Amz_Date   : String (1 .. 16);
      Date_Stamp : String (1 .. 8);
      Object_URL : Unbounded_String;
      Query      : Unbounded_String;
   begin
      Presigned_URL := Null_Unbounded_String;
      Status := Parse_URL (URL, Local_Path, Location, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      elsif Location.Kind /= Transport_S3 then
         Diagnostic := To_Unbounded_String ("presigned URLs are only supported for s3:// remotes");
         return Remote_Unsupported_Transport;
      elsif Expires_Seconds = 0 or else Expires_Seconds > 604_800 then
         Diagnostic := To_Unbounded_String
           ("S3 presigned URL expiry must be between 1 and 604800 seconds");
         return Remote_Invalid_URL;
      end if;

      Status := Validate_Transport_Options (Location, Options, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;
      Resolved := Resolved_S3_Options (Options, Diagnostic);
      if Length (Resolved.S3_Access_Key) = 0 or else Length (Resolved.S3_Secret_Key) = 0 then
         Diagnostic := To_Unbounded_String ("S3 credentials are required for presigning");
         return Remote_Authentication_Failed;
      end if;

      S3_Timestamps (Amz_Date, Date_Stamp);
      Object_URL := To_Unbounded_String (Remote_Object_URL (Location, Resolved));
      Query := To_Unbounded_String
        (S3_Presign_Query
           (To_String (Object_URL), Resolved, Method, Amz_Date, Date_Stamp,
            Expires_Seconds));
      if URL_Query (To_String (Object_URL))'Length = 0 then
         Presigned_URL := Object_URL & "?" & Query;
      else
         Presigned_URL := Object_URL & "&" & Query;
      end if;
      return Remote_Ok;
   end Presign_S3_URL;

   function Build_Sync_Plan
     (Local_Path : String;
      Remote_Set : Archive_Metadata_Vectors.Vector;
      Plan        : out Sync_Step_Vectors.Vector;
      Diagnostic  : out Unbounded_String)
      return Remote_Status
   is
      Local_Metadata : Archive_Metadata;
      Sorted         : Archive_Metadata_Vectors.Vector := Remote_Set;
      Found          : Boolean := False;
      Status         : Remote_Status;
   begin
      Plan.Clear;
      Diagnostic := Null_Unbounded_String;

      if not Ada.Directories.Exists (Local_Path) then
         Diagnostic := To_Unbounded_String ("local archive does not exist: " & Local_Path);
         return Remote_Not_Found;
      end if;

      Status := File_Metadata
        (Local_Path, True, False, Local_Metadata, Diagnostic);
      if Status /= Remote_Ok then
         return Status;
      end if;

      Sort_Inventory (Sorted);
      for Item of Sorted loop
         declare
            Same_Archive : constant Boolean :=
              To_String (Item.Archive_Id) = To_String (Local_Metadata.Archive_Id);
            Same_Metadata : constant Boolean :=
              Item.Size = Local_Metadata.Size and then Item.Crc32 = Local_Metadata.Crc32;
            Action : constant Sync_Action :=
              Backup.Remote_Sync_Syntax.Inventory_Item_Action
                (Item.Partial, Same_Archive, Same_Metadata);
         begin
            if Same_Archive then
               Found := True;
            end if;

            case Action is
               when Sync_Delete_Remote =>
                  Plan.Append
                    (Sync_Step'(Action  => Action,
                      Archive => Item,
                      Reason  => To_Unbounded_String ("partial upload marker")));
               when Sync_Upload =>
                  Plan.Append
                    (Sync_Step'(Action  => Action,
                      Archive => Local_Metadata,
                      Reason  => To_Unbounded_String ("remote archive metadata differs")));
               when Sync_Keep =>
                  if Same_Archive then
                     Plan.Append
                       (Sync_Step'(Action  => Action,
                         Archive => Item,
                         Reason  => To_Unbounded_String
                           ("remote archive already matches local archive")));
                  else
                     Plan.Append
                       (Sync_Step'(Action  => Action,
                         Archive => Item,
                         Reason  => To_Unbounded_String
                           ("managed remote archive outside current upload")));
                  end if;
               when Sync_Download =>
                  null;
            end case;
         end;
      end loop;

      if not Found then
         Plan.Append
           (Sync_Step'(Action  => Backup.Remote_Sync_Syntax.Missing_Local_Action,
             Archive => Local_Metadata,
             Reason  => To_Unbounded_String ("remote archive is missing")));
      end if;

      return Remote_Ok;
   end Build_Sync_Plan;

   procedure Build_JSON_Report
     (Report : Transfer_Report;
      Text   : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String ("{" & Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("format") & ": " &
         Q ("backup-remote-v1") & "," & Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("status") & ": " &
         Q (Status_Text (Report.Status)) & "," &
         Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("transport") & ": " &
         Q (Transport_Name (Report.Transport)) & "," &
         Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("remote_url") & ": " &
         Q (To_String (Report.Remote_URL)) & "," &
         Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("remote_object") & ": " &
         Q (To_String (Report.Remote_Object)) & "," &
         Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("local_path") & ": " &
         Q (To_String (Report.Local_Path)) & "," &
         Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("size") & ": " & Decimal (Report.Size) &
         "," & Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("crc32") & ": " & Decimal_32 (Report.Crc32) &
         "," & Ada.Characters.Latin_1.LF);
      Append (Text, "  " & Q ("atomic") & ": ");
      if Report.Atomic then
         Append (Text, "true");
      else
         Append (Text, "false");
      end if;
      Append
        (Text, "," & Ada.Characters.Latin_1.LF &
         "  " & Q ("resumed") & ": ");
      if Report.Resumed then
         Append (Text, "true");
      else
         Append (Text, "false");
      end if;
      Append
        (Text, "," & Ada.Characters.Latin_1.LF &
         "  " & Q ("verified") & ": ");
      if Report.Verified then
         Append (Text, "true");
      else
         Append (Text, "false");
      end if;
      Append
        (Text, "," & Ada.Characters.Latin_1.LF &
         "  " & Q ("retried") & ": " &
         Decimal_Natural (Report.Retried));
      if Report.PCloud_Progress_Samples > 0 then
         Append
           (Text, "," & Ada.Characters.Latin_1.LF &
            "  " & Q ("pcloud_progress_samples") & ": " &
            Decimal_Natural (Report.PCloud_Progress_Samples));
      end if;
      Append
        (Text, Ada.Characters.Latin_1.LF & "}" &
         Ada.Characters.Latin_1.LF);
   end Build_JSON_Report;

   procedure Build_Sync_JSON_Report
     (Plan : Sync_Step_Vectors.Vector;
      Text : out Unbounded_String)
   is
      First : Boolean := True;
   begin
      Text := To_Unbounded_String ("{" & Ada.Characters.Latin_1.LF);
      Append
        (Text, "  " & Q ("format") & ": " &
         Q ("backup-remote-sync-v1") & "," &
         Ada.Characters.Latin_1.LF);
      Append (Text, "  " & Q ("steps") & ": [" & Ada.Characters.Latin_1.LF);
      for Step of Plan loop
         if First then
            First := False;
         else
            Append (Text, "," & Ada.Characters.Latin_1.LF);
         end if;
         Append
           (Text, "    {" & Q ("action") & ": " &
            Q (Action_Name (Step.Action)));
         Append
           (Text, ", " & Q ("archive_id") & ": " &
            Q (To_String (Step.Archive.Archive_Id)));
         Append (Text, ", " & Q ("size") & ": " & Decimal (Step.Archive.Size));
         Append
           (Text, ", " & Q ("crc32") & ": " &
            Decimal_32 (Step.Archive.Crc32));
         Append (Text, ", " & Q ("has_timestamp") & ": ");
         Append (Text, (if Step.Archive.Has_Timestamp then "true" else "false"));
         if Step.Archive.Has_Timestamp then
            Append
              (Text, ", " & Q ("timestamp") & ": " &
               Q (Ada.Calendar.Formatting.Image
                    (Step.Archive.Timestamp, Include_Time_Fraction => False)));
         end if;
         Append (Text, ", " & Q ("partial") & ": ");
         if Step.Archive.Partial then
            Append (Text, "true");
         else
            Append (Text, "false");
         end if;
         Append
           (Text, ", " & Q ("reason") & ": " &
            Q (To_String (Step.Reason)) & "}");
      end loop;
      Append
        (Text, Ada.Characters.Latin_1.LF & "  ]" &
         Ada.Characters.Latin_1.LF & "}" & Ada.Characters.Latin_1.LF);
   end Build_Sync_JSON_Report;

   procedure Build_Sync_Human_Report
     (Plan : Sync_Step_Vectors.Vector;
      Text : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String
        ("Remote synchronization plan" & Ada.Characters.Latin_1.LF);
      if Plan.Is_Empty then
         Append (Text, "  no remote changes" & Ada.Characters.Latin_1.LF);
         return;
      end if;

      for Step of Plan loop
         Append
           (Text,
            "  " & Action_Name (Step.Action) & " " &
            To_String (Step.Archive.Archive_Id) & " - " &
            To_String (Step.Reason) & Ada.Characters.Latin_1.LF);
      end loop;
   end Build_Sync_Human_Report;

end Backup.Remote;
