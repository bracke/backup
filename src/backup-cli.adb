with Ada.Command_Line;
with Ada.Containers;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Backup_Config;
with Proton_Drive;

with Backup.Catalog;
with Backup.Paths;
with Backup.Workflow;
with Backup.Jobs;
with Backup.Messages;
with Backup.CLI_Syntax;
with Backup.CLI_Surface;

with Terminal_Styles;

package body Backup.CLI is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Backup.Workflow.Execution_Status;
   use type Backup.Remote.Remote_Status;
   use type Backup.Encryption.Password_Source_Kind;
   use type Backup.Jobs.Job_Status;
   use type Backup.Catalog.Catalog_Status;
   use type Proton_Drive.SDK_Status;
   use type Backup.Paths.Validation_Status;
   use type Backup.CLI_Surface.Help_Line;
   use type Ada.Directories.File_Kind;

   procedure Put_Styled_Line
     (Text : String;
      Role : Terminal_Styles.Style_Role := Terminal_Styles.Role_Info)
   is
   begin
      Ada.Text_IO.Put_Line (Terminal_Styles.Line (Text, Role));
   end Put_Styled_Line;

   procedure Put_Styled_Error (Text : String) is
   begin
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Terminal_Styles.Line (Text, Terminal_Styles.Role_Error));
   end Put_Styled_Error;

   function Localized (Key : String) return String is
   begin
      return Backup.Messages.Text (Key);
   end Localized;

   function Localized
     (Key       : String;
      Arg_Key   : String;
      Arg_Value : String) return String
   is
   begin
      return Backup.Messages.Text (Key, Arg_Key, Arg_Value);
   end Localized;


   function To_Terminal_Role
     (Role : Backup.CLI_Surface.Help_Role) return Terminal_Styles.Style_Role
   is
   begin
      case Role is
         when Backup.CLI_Surface.Role_Header =>
            return Terminal_Styles.Role_Header;
         when Backup.CLI_Surface.Role_Info =>
            return Terminal_Styles.Role_Info;
         when Backup.CLI_Surface.Role_Muted =>
            return Terminal_Styles.Role_Muted;
      end case;
   end To_Terminal_Role;

   procedure Emit_Help_Line (Line : Backup.CLI_Surface.Help_Line) is
      Key  : constant String := Backup.CLI_Surface.Message_Key (Line);
      Role : constant Terminal_Styles.Style_Role :=
        To_Terminal_Role (Backup.CLI_Surface.Display_Role (Line));
   begin
      if Line = Backup.CLI_Surface.Title then
         Put_Styled_Line
           (Localized (Key, "version", Backup_Config.Crate_Version), Role);
      else
         Put_Styled_Line (Localized (Key), Role);
      end if;
   end Emit_Help_Line;

   procedure Print_Help is
   begin
      for Line in Backup.CLI_Surface.Basic_Help_Line loop
         Emit_Help_Line (Line);
      end loop;
   end Print_Help;

   procedure Print_Advanced_Help is
   begin
      Print_Help;
      for Line in Backup.CLI_Surface.Advanced_Help_Line loop
         Emit_Help_Line (Line);
      end loop;
   end Print_Advanced_Help;

   procedure Print_Version is
   begin
      Ada.Text_IO.Put_Line
        (Backup_Config.Crate_Name & " " & Backup_Config.Crate_Version);
   end Print_Version;

   function Percent_Encode_Query_Component (Text : String) return String is
      Hex : constant String := "0123456789ABCDEF";
      Result : Unbounded_String;
      Code : Natural;
   begin
      for Ch of Text loop
         if Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z'
           or else Ch in '0' .. '9' or else Ch in '-' | '_' | '.' | '~'
         then
            Append (Result, Ch);
         else
            Code := Character'Pos (Ch);
            Append (Result, '%');
            Append (Result, Hex (Hex'First + Code / 16));
            Append (Result, Hex (Hex'First + Code mod 16));
         end if;
      end loop;
      return To_String (Result);
   end Percent_Encode_Query_Component;

   procedure Print_PCloud_OAuth_URL (Client_Id : String; Redirect_URI : String) is
   begin
      Ada.Text_IO.Put_Line
        ("https://my.pcloud.com/oauth2/authorize?client_id=" &
         Percent_Encode_Query_Component (Client_Id) &
         "&response_type=code&redirect_uri=" &
         Percent_Encode_Query_Component (Redirect_URI));
   end Print_PCloud_OAuth_URL;

   function OAuth_JSON_Field (Text : String; Name : String) return String is
      Pattern : constant String := '"' & Name & '"';
      Start   : constant Natural := Ada.Strings.Fixed.Index (Text, Pattern);
      Colon   : Natural;
      Pos     : Natural;
      Result  : Unbounded_String;
   begin
      if Start = 0 then
         return "";
      end if;
      Colon := Ada.Strings.Fixed.Index (Text (Start + Pattern'Length .. Text'Last), ":");
      if Colon = 0 then
         return "";
      end if;
      Pos := Colon + 1;
      while Pos <= Text'Last
        and then Text (Pos) in ' ' | ASCII.HT | ASCII.CR | ASCII.LF
      loop
         Pos := Pos + 1;
      end loop;
      if Pos > Text'Last or else Text (Pos) /= '"' then
         return "";
      end if;
      Pos := Pos + 1;
      while Pos <= Text'Last loop
         if Text (Pos) = '"' then
            return To_String (Result);
         elsif Text (Pos) = '\' then
            Pos := Pos + 1;
            exit when Pos > Text'Last;
            case Text (Pos) is
               when '"' | '\' | '/' =>
                  Append (Result, Text (Pos));
               when 'b' =>
                  Append (Result, Character'Val (8));
               when 't' =>
                  Append (Result, Character'Val (9));
               when 'n' =>
                  Append (Result, Character'Val (10));
               when 'f' =>
                  Append (Result, Character'Val (12));
               when 'r' =>
                  Append (Result, Character'Val (13));
               when others =>
                  Append (Result, Text (Pos));
            end case;
         else
            Append (Result, Text (Pos));
         end if;
         Pos := Pos + 1;
      end loop;
      return To_String (Result);
   exception
      when others =>
         return "";
   end OAuth_JSON_Field;

   procedure Print_PCloud_Token_Config_Hints
     (Token_JSON    : String;
      Client_Id     : String;
      Client_Secret : String)
   is
      Access_Token  : constant String := OAuth_JSON_Field (Token_JSON, "access_token");
      Refresh_Token : constant String := OAuth_JSON_Field (Token_JSON, "refresh_token");
   begin
      Ada.Text_IO.Put_Line ("pCloud OAuth token JSON:");
      Ada.Text_IO.Put_Line (Token_JSON);
      if Access_Token'Length > 0 then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line ("Access-token config:");
         Ada.Text_IO.Put_Line ("pcloud_access_token=" & Access_Token);
      end if;
      if Refresh_Token'Length > 0 then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line ("Refresh-token config:");
         Ada.Text_IO.Put_Line ("pcloud_refresh_token=" & Refresh_Token);
         Ada.Text_IO.Put_Line ("pcloud_client_id=" & Client_Id);
         if Client_Secret'Length > 0 then
            Ada.Text_IO.Put_Line
              ("pcloud_client_secret=<same client secret supplied to --pcloud-oauth-token>");
         end if;
      end if;
   end Print_PCloud_Token_Config_Hints;

   function Print_PCloud_OAuth_Token
     (Client_Id     : String;
      Client_Secret : String;
      Code          : String;
      Redirect_URI  : String;
      API_Base      : String) return Boolean
   is
      Token_JSON : Unbounded_String;
      Diagnostic : Unbounded_String;
      Status     : Backup.Remote.Remote_Status;
   begin
      Status := Backup.Remote.Exchange_PCloud_Authorization_Code
        (Client_Id, Client_Secret, Code, Redirect_URI, API_Base,
         Token_JSON, Diagnostic);
      if Status = Backup.Remote.Remote_Ok then
         Print_PCloud_Token_Config_Hints
           (To_String (Token_JSON), Client_Id, Client_Secret);
         return True;
      else
         Put_Styled_Error (To_String (Diagnostic));
         return False;
      end if;
   end Print_PCloud_OAuth_Token;

   function Proton_Default_App_Version return String is
   begin
      return "external-drive-backup@0.1.0-alpha";
   end Proton_Default_App_Version;

   function Run_Proton_Drive_Login
     (Session_File   : String;
      User_Address   : String;
      Username       : String;
      Password_Proof : String;
      MFA_Code       : String;
      Session_Label  : String;
      App_Version    : String;
      API_Base       : String) return Boolean
   is
      Config : constant Proton_Drive.Client_Config :=
        (App_Version  => To_Unbounded_String
           ((if App_Version'Length > 0 then App_Version else Proton_Default_App_Version)),
         API_Base     => To_Unbounded_String
           ((if API_Base'Length > 0 then API_Base else Proton_Drive.Default_API_Base)),
         Session_File => To_Unbounded_String (Session_File),
         User_Address => To_Unbounded_String (User_Address),
         Share_Id     => To_Unbounded_String ("login-bootstrap"));
      Request : constant Proton_Drive.Auth_Request :=
        (Username       => To_Unbounded_String (Username),
         Password_Proof => To_Unbounded_String (Password_Proof),
         MFA_Code       => To_Unbounded_String (MFA_Code),
         Session_Label  => To_Unbounded_String
           ((if Session_Label'Length > 0 then Session_Label else "backup")));
      Diagnostic : Unbounded_String;
      Status     : constant Proton_Drive.SDK_Status :=
        Proton_Drive.Login_And_Save_Session (Config, Request, Diagnostic);
   begin
      if Status = Proton_Drive.SDK_Ok then
         Ada.Text_IO.Put_Line (To_String (Diagnostic));
         return True;
      end if;
      Put_Styled_Error
        (Proton_Drive.Status_Text (Status) & ": " & To_String (Diagnostic));
      return False;
   end Run_Proton_Drive_Login;

   function JSON_Escape (Text : String) return String is
      Result : Unbounded_String;
      Hex    : constant array (Natural range 0 .. 15) of Character :=
        "0123456789abcdef";
      Code   : Natural;

      procedure Append_Escape (Escaped : Character) is
      begin
         Append (Result, Character'Val (16#5C#));
         Append (Result, Escaped);
      end Append_Escape;
   begin
      for Ch of Text loop
         case Ch is
            when '"' =>
               Append_Escape ('"');
            when Character'Val (16#5C#) =>
               Append_Escape (Character'Val (16#5C#));
            when Character'Val (8) =>
               Append_Escape ('b');
            when Character'Val (9) =>
               Append_Escape ('t');
            when Character'Val (10) =>
               Append_Escape ('n');
            when Character'Val (12) =>
               Append_Escape ('f');
            when Character'Val (13) =>
               Append_Escape ('r');
            when others =>
               Code := Character'Pos (Ch);
               if Code < 32 then
                  Append_Escape ('u');
                  Append (Result, '0');
                  Append (Result, '0');
                  Append (Result, Hex (Code / 16));
                  Append (Result, Hex (Code mod 16));
               else
                  Append (Result, Ch);
               end if;
         end case;
      end loop;

      return To_String (Result);
   end JSON_Escape;

   function Error_JSON (Message : String) return String is
   begin
      return "{""format"":""backup-error-v1""," &
        """status"":""error""," &
        """message"":""" & JSON_Escape (Message) & """}";
   end Error_JSON;

   procedure Emit_Error
     (Message     : String;
      JSON_Errors : Boolean)
   is
   begin
      if JSON_Errors then
         Ada.Text_IO.Put_Line (Error_JSON (Message));
      else
         Put_Styled_Error (Localized ("error.prefix", "message", Message));
      end if;
   end Emit_Error;

   function Wants_JSON_Errors
     (Arguments : String_Vectors.Vector) return Boolean
   is
   begin
      for Arg of Arguments loop
         if Arg = "--json-errors" then
            return True;
         end if;
      end loop;

      return False;
   end Wants_JSON_Errors;

   function Starts_With
     (Value  : String;
      Prefix : String)
      return Boolean
   is
   begin
      return Value'Length >= Prefix'Length
        and then
          Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Is_Option (Value : String) return Boolean is
   begin
      return Value'Length >= 2
        and then Value (Value'First) = '-'
        and then Value (Value'First + 1) = '-';
   end Is_Option;

   function Normalize_Path (Path : String) return String is
   begin
      return Backup.Paths.To_String
        (Backup.Paths.Normalize_File_System_Path (Path));
   end Normalize_Path;

   function Prefix_Is_Valid (Value : String) return Boolean is
   begin
      return Backup.Paths.Validate_Prefix (Value) = Backup.Paths.Valid;
   end Prefix_Is_Valid;

   function Parse_Size
     (Value      : String;
      Limit      : out Size_Limit;
      Diagnostic : out Unbounded_String;
      Option     : String)
      return Boolean
   is
      Accumulated : Interfaces.Unsigned_64 := 0;
   begin
      Limit := (Is_Set => False, Value => 0);

      if Value'Length = 0 then
         Diagnostic := To_Unbounded_String
           (Option & " requires a non-empty byte count");
         return False;
      end if;

      for Ch of Value loop
         if not Backup.CLI_Syntax.Is_Digit (Ch) then
            Diagnostic := To_Unbounded_String
              (Option & " requires a decimal byte count, got '" & Value & "'");
            return False;
         end if;

         if not Backup.CLI_Syntax.Can_Accumulate_Decimal
           (Accumulated, Ch)
         then
            Diagnostic := To_Unbounded_String
              (Option & " byte count is too large: '" & Value & "'");
            return False;
         end if;

         Accumulated := Backup.CLI_Syntax.Accumulate_Decimal
           (Accumulated, Ch);
      end loop;

      Limit := (Is_Set => True, Value => Accumulated);
      return True;
   end Parse_Size;

   function Consume_Value
     (Arguments  : String_Vectors.Vector;
      Index      : in out Positive;
      Option     : String;
      Value      : out Unbounded_String;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Index = Positive (Arguments.Last_Index) then
         Diagnostic := To_Unbounded_String (Option & " requires a value");
         return False;
      end if;

      Index := Index + 1;
      Value := To_Unbounded_String (Arguments.Element (Index));
      return True;
   end Consume_Value;

   function Parse_Compression
     (Value      : String;
      Mode       : out Compression_Mode;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Value = "auto" then
         Mode := Compression_Auto;
      elsif Value = "store" then
         Mode := Compression_Store;
      elsif Value = "deflate" then
         Mode := Compression_Deflate;
      elsif Value = "bzip2" then
         Mode := Compression_BZip2;
      elsif Value = "lzma" then
         Mode := Compression_LZMA;
      elsif Value = "zstd" then
         Mode := Compression_Zstd;
      else
         Diagnostic := To_Unbounded_String
           ("invalid --compression value '" & Value &
            "'; expected auto, store, deflate, bzip2, lzma, or zstd");
         return False;
      end if;

      return True;
   end Parse_Compression;

   function Parse_Symlinks
     (Value      : String;
      Mode       : out Symlink_Mode;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Value = "skip" then
         Mode := Symlinks_Skip;
      elsif Value = "store-link" then
         Mode := Symlinks_Store_Link;
      elsif Value = "follow" then
         Mode := Symlinks_Follow;
      else
         Diagnostic := To_Unbounded_String
           ("invalid --symlinks value '" & Value &
            "'; expected skip, store-link, or follow");
         return False;
      end if;

      return True;
   end Parse_Symlinks;


   function Environment_Config_Value
     (Name       : String;
      Field      : String;
      Diagnostic : out Unbounded_String) return Unbounded_String
   is
   begin
      if Name'Length = 0 then
         Diagnostic := To_Unbounded_String (Field & " requires an environment variable name");
         return Null_Unbounded_String;
      elsif not Ada.Environment_Variables.Exists (Name) then
         Diagnostic := To_Unbounded_String
           (Field & " references unset environment variable '" & Name & "'");
         return Null_Unbounded_String;
      else
         declare
            Value : constant String := Ada.Environment_Variables.Value (Name);
         begin
            if Value'Length = 0 then
               Diagnostic := To_Unbounded_String
                 (Field & " references empty environment variable '" & Name & "'");
               return Null_Unbounded_String;
            end if;
            return To_Unbounded_String (Value);
         end;
      end if;
   end Environment_Config_Value;

   function Parse_Boolean_Text
     (Value      : String;
      Result     : out Boolean;
      Diagnostic : out Unbounded_String;
      Field      : String)
      return Boolean
   is
   begin
      if Value = "true" or else Value = "yes" or else Value = "1" then
         Result := True;
         return True;
      elsif Value = "false" or else Value = "no" or else Value = "0" then
         Result := False;
         return True;
      else
         Diagnostic := To_Unbounded_String
           (Field & " requires true/false, yes/no, or 1/0");
         return False;
      end if;
   end Parse_Boolean_Text;

   function Parse_Natural_Text
     (Value      : String;
      Result     : out Natural;
      Diagnostic : out Unbounded_String;
      Field      : String)
      return Boolean
   is
      Accumulated : Natural := 0;
   begin
      if Value'Length = 0 then
         Diagnostic := To_Unbounded_String (Field & " requires a decimal value");
         return False;
      end if;

      for Ch of Value loop
         if not Backup.CLI_Syntax.Is_Digit (Ch) then
            Diagnostic := To_Unbounded_String
              (Field & " requires a decimal value, got '" & Value & "'");
            return False;
         end if;

         declare
            Digit : constant Natural :=
              Character'Pos (Ch) - Character'Pos ('0');
         begin
            if Accumulated > (Natural'Last - Digit) / 10 then
               Diagnostic := To_Unbounded_String
                 (Field & " value is too large: '" & Value & "'");
               return False;
            end if;
            Accumulated := Accumulated * 10 + Digit;
         end;
      end loop;

      Result := Accumulated;
      return True;
   end Parse_Natural_Text;

   function Load_Remote_Config
     (Path       : String;
      Config     : in out Configuration;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      File : Ada.Text_IO.File_Type;
      Line_Buffer : String (1 .. 4096);
      Last : Natural;
      Line_No : Natural := 0;
      Flag : Boolean;
      Count : Natural;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line_Buffer, Last);
         Line_No := Line_No + 1;
         declare
            Raw : constant String := Line_Buffer (Line_Buffer'First .. Last);
            Hash : constant Natural := Ada.Strings.Fixed.Index (Raw, "#");
            Without_Comment : Unbounded_String;
            Line : Unbounded_String;
            Eq : Natural;
         begin
            if Hash = 0 then
               Without_Comment := To_Unbounded_String (Raw);
            else
               Without_Comment := To_Unbounded_String
                 (Raw (Raw'First .. Hash - 1));
            end if;

            Line := To_Unbounded_String
              (Ada.Strings.Fixed.Trim
                 (To_String (Without_Comment), Ada.Strings.Both));
            Eq := Ada.Strings.Fixed.Index (To_String (Line), "=");

            if Length (Line) = 0 then
               null;
            elsif Eq = 0 then
               Diagnostic := To_Unbounded_String
                 ("remote config line" & Natural'Image (Line_No) &
                  ": expected key=value");
               Ada.Text_IO.Close (File);
               return False;
            else
               declare
                  Line_Text : constant String := To_String (Line);
                  Key : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Line_Text (Line_Text'First .. Eq - 1),
                       Ada.Strings.Both);
                  Value : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Line_Text (Eq + 1 .. Line_Text'Last),
                       Ada.Strings.Both);
               begin
                  if Key = "remote" or else Key = "url" then
                     if Value'Length = 0 then
                        Diagnostic := To_Unbounded_String
                          ("remote config line" & Natural'Image (Line_No) &
                           ": remote URL must not be empty");
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     if Length (Config.Remote_URL) = 0 then
                        Config.Remote_URL := To_Unbounded_String (Value);
                     end if;
                  elsif Key = "require_encrypted" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "require_encrypted")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.Require_Encrypted := Flag;
                  elsif Key = "resume" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "resume")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     if Flag then
                        Config.Remote_Options.Upload_Behavior :=
                          Backup.Remote.Upload_Resume_If_Supported;
                     else
                        Config.Remote_Options.Upload_Behavior :=
                          Backup.Remote.Upload_Atomic;
                     end if;
                  elsif Key = "retry_count" then
                     if not Parse_Natural_Text
                       (Value, Count, Diagnostic, "retry_count")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.Retry_Count := Count;
                  elsif Key = "timeout_seconds" then
                     if not Parse_Natural_Text
                       (Value, Count, Diagnostic, "timeout_seconds")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.Timeout_Seconds := Count;
                  elsif Key = "http_bearer_token" then
                     Config.Remote_Options.HTTP_Auth :=
                       Backup.Remote.HTTP_Auth_Bearer;
                     Config.Remote_Options.HTTP_Bearer_Token :=
                       To_Unbounded_String (Value);
                  elsif Key = "http_basic_user" then
                     Config.Remote_Options.HTTP_Auth :=
                       Backup.Remote.HTTP_Auth_Basic;
                     Config.Remote_Options.HTTP_Basic_User :=
                       To_Unbounded_String (Value);
                  elsif Key = "http_basic_password" then
                     Config.Remote_Options.HTTP_Auth :=
                       Backup.Remote.HTTP_Auth_Basic;
                     Config.Remote_Options.HTTP_Basic_Pass :=
                       To_Unbounded_String (Value);
                  elsif Key = "http_header_name" then
                     Config.Remote_Options.HTTP_Auth :=
                       Backup.Remote.HTTP_Auth_Custom_Header;
                     Config.Remote_Options.HTTP_Header_Name :=
                       To_Unbounded_String (Value);
                  elsif Key = "http_header_value" then
                     Config.Remote_Options.HTTP_Auth :=
                       Backup.Remote.HTTP_Auth_Custom_Header;
                     Config.Remote_Options.HTTP_Header_Value :=
                       To_Unbounded_String (Value);
                  elsif Key = "tls_ca_file" then
                     Config.Remote_Options.TLS_CA_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "tls_ca_directory" then
                     Config.Remote_Options.TLS_CA_Directory :=
                       To_Unbounded_String (Value);
                  elsif Key = "tls_client_cert" then
                     Config.Remote_Options.TLS_Client_Cert_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "tls_client_key" then
                     Config.Remote_Options.TLS_Client_Key_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "tls_client_key_passphrase" then
                     Config.Remote_Options.TLS_Client_Key_Passphrase :=
                       To_Unbounded_String (Value);
                     Config.Remote_Options.TLS_Client_Has_Passphrase := True;
                  elsif Key = "s3_endpoint" then
                     Config.Remote_Options.S3_Endpoint :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_region" then
                     Config.Remote_Options.S3_Region :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_profile" then
                     Config.Remote_Options.S3_Profile :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_credentials_file" then
                     Config.Remote_Options.S3_Credentials_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_config_file" then
                     Config.Remote_Options.S3_Config_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_web_identity_token_file" then
                     Config.Remote_Options.S3_Web_Identity_Token_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_role_arn" then
                     Config.Remote_Options.S3_Role_Arn :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_credential_process" then
                     Config.Remote_Options.S3_Credential_Process :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_sso_session" then
                     Config.Remote_Options.S3_SSO_Session :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_sso_start_url" then
                     Config.Remote_Options.S3_SSO_Start_URL :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_sso_region" then
                     Config.Remote_Options.S3_SSO_Region :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_sso_account_id" then
                     Config.Remote_Options.S3_SSO_Account_Id :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_sso_role_name" then
                     Config.Remote_Options.S3_SSO_Role_Name :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_addressing" then
                     if Value = "path" then
                        Config.Remote_Options.S3_Virtual_Hosted_Style := False;
                     elsif Value = "virtual" or else Value = "virtual-hosted" then
                        Config.Remote_Options.S3_Virtual_Hosted_Style := True;
                     else
                        Diagnostic := To_Unbounded_String
                          ("s3_addressing requires path or virtual");
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                  elsif Key = "s3_server_side_encryption" then
                     Config.Remote_Options.S3_Server_Side_Encryption :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_sse_kms_key_id" then
                     Config.Remote_Options.S3_SSE_KMS_Key_Id :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_acl" then
                     Config.Remote_Options.S3_ACL :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_storage_class" then
                     Config.Remote_Options.S3_Storage_Class :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_tagging" then
                     Config.Remote_Options.S3_Tagging :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_metadata_name" then
                     Config.Remote_Options.S3_Metadata_Name :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_metadata_value" then
                     Config.Remote_Options.S3_Metadata_Value :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_cache_control" then
                     Config.Remote_Options.S3_Cache_Control :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_content_disposition" then
                     Config.Remote_Options.S3_Content_Disposition :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_content_encoding" then
                     Config.Remote_Options.S3_Content_Encoding :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_object_lock_mode" then
                     Config.Remote_Options.S3_Object_Lock_Mode :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_object_lock_retain_until" then
                     Config.Remote_Options.S3_Object_Lock_Retain_Until :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_object_lock_legal_hold" then
                     Config.Remote_Options.S3_Object_Lock_Legal_Hold :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_multipart_threshold" then
                     if not Parse_Natural_Text
                       (Value, Count, Diagnostic, "s3_multipart_threshold")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.S3_Multipart_Threshold := Count;
                  elsif Key = "s3_multipart_part_size" then
                     if not Parse_Natural_Text
                       (Value, Count, Diagnostic, "s3_multipart_part_size")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.S3_Multipart_Part_Size := Count;
                  elsif Key = "s3_access_key" then
                     Config.Remote_Options.S3_Access_Key :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_access_key_env" then
                     if Value'Length > 0 then
                        Config.Remote_Options.S3_Access_Key :=
                          Environment_Config_Value
                            (Value, "s3_access_key_env", Diagnostic);
                        if Length (Config.Remote_Options.S3_Access_Key) = 0 then
                           Ada.Text_IO.Close (File);
                           return False;
                        end if;
                     end if;
                  elsif Key = "s3_secret_key" then
                     Config.Remote_Options.S3_Secret_Key :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_secret_key_env" then
                     if Value'Length > 0 then
                        Config.Remote_Options.S3_Secret_Key :=
                          Environment_Config_Value
                            (Value, "s3_secret_key_env", Diagnostic);
                        if Length (Config.Remote_Options.S3_Secret_Key) = 0 then
                           Ada.Text_IO.Close (File);
                           return False;
                        end if;
                     end if;
                  elsif Key = "s3_session_token" then
                     Config.Remote_Options.S3_Session_Token :=
                       To_Unbounded_String (Value);
                  elsif Key = "s3_session_token_env" then
                     if Value'Length > 0 then
                        Config.Remote_Options.S3_Session_Token :=
                          Environment_Config_Value
                            (Value, "s3_session_token_env", Diagnostic);
                        if Length (Config.Remote_Options.S3_Session_Token) = 0 then
                           Ada.Text_IO.Close (File);
                           return False;
                        end if;
                     end if;
                  elsif Key = "google_drive_api_base" then
                     Config.Remote_Options.Google_Drive_API_Base :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_upload_base" then
                     Config.Remote_Options.Google_Drive_Upload_Base :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_access_token" then
                     Config.Remote_Options.Google_Drive_Access_Token :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_access_token_file" then
                     Config.Remote_Options.Google_Drive_Access_Token_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_refresh_token" then
                     Config.Remote_Options.Google_Drive_Refresh_Token :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_client_id" then
                     Config.Remote_Options.Google_Drive_Client_Id :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_client_secret" then
                     Config.Remote_Options.Google_Drive_Client_Secret :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_token_uri" then
                     Config.Remote_Options.Google_Drive_Token_URI :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_supports_all_drives" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "google_drive_supports_all_drives")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.Google_Drive_Supports_All_Drives := Flag;
                  elsif Key = "google_drive_drive_id" then
                     Config.Remote_Options.Google_Drive_Drive_Id :=
                       To_Unbounded_String (Value);
                  elsif Key = "google_drive_access_token_env" then
                     if Value'Length > 0 then
                        Config.Remote_Options.Google_Drive_Access_Token :=
                          Environment_Config_Value
                            (Value, "google_drive_access_token_env", Diagnostic);
                        if Length (Config.Remote_Options.Google_Drive_Access_Token) = 0 then
                           Ada.Text_IO.Close (File);
                           return False;
                        end if;
                     end if;
                  elsif Key = "pcloud_api_base" then
                     Config.Remote_Options.PCloud_API_Base :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_region" then
                     Config.Remote_Options.PCloud_Region :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_access_token" then
                     Config.Remote_Options.PCloud_Access_Token :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_access_token_file" then
                     Config.Remote_Options.PCloud_Access_Token_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_token_cache_file" then
                     Config.Remote_Options.PCloud_Token_Cache_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_refresh_token" then
                     Config.Remote_Options.PCloud_Refresh_Token :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_client_id" then
                     Config.Remote_Options.PCloud_Client_Id :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_client_secret" then
                     Config.Remote_Options.PCloud_Client_Secret :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_token_uri" then
                     Config.Remote_Options.PCloud_Token_URI :=
                       To_Unbounded_String (Value);
                  elsif Key = "pcloud_large_upload_threshold" then
                     Config.Remote_Options.PCloud_Large_Upload_Threshold :=
                       Natural'Value (Value);
                  elsif Key = "pcloud_upload_progress" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "pcloud_upload_progress")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.PCloud_Upload_Progress := Flag;
                  elsif Key = "pcloud_poll_progress" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "pcloud_poll_progress")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.PCloud_Poll_Progress := Flag;
                  elsif Key = "pcloud_check_quota" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "pcloud_check_quota")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.PCloud_Check_Quota := Flag;
                  elsif Key = "pcloud_create_parents" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "pcloud_create_parents")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.PCloud_Create_Parents := Flag;
                  elsif Key = "pcloud_clean_recursive" then
                     if not Parse_Boolean_Text
                       (Value, Flag, Diagnostic, "pcloud_clean_recursive")
                     then
                        Ada.Text_IO.Close (File);
                        return False;
                     end if;
                     Config.Remote_Options.PCloud_Clean_Recursive := Flag;
                  elsif Key = "pcloud_access_token_env" then
                     if Value'Length > 0 then
                        Config.Remote_Options.PCloud_Access_Token :=
                          Environment_Config_Value
                            (Value, "pcloud_access_token_env", Diagnostic);
                        if Length (Config.Remote_Options.PCloud_Access_Token) = 0 then
                           Ada.Text_IO.Close (File);
                           return False;
                        end if;
                     end if;
                  elsif Key = "proton_drive_api_base" then
                     Config.Remote_Options.Proton_Drive_API_Base :=
                       To_Unbounded_String (Value);
                  elsif Key = "proton_drive_app_version" then
                     Config.Remote_Options.Proton_Drive_App_Version :=
                       To_Unbounded_String (Value);
                  elsif Key = "proton_drive_session_file" then
                     Config.Remote_Options.Proton_Drive_Session_File :=
                       To_Unbounded_String (Value);
                  elsif Key = "proton_drive_user_address" then
                     Config.Remote_Options.Proton_Drive_User_Address :=
                       To_Unbounded_String (Value);
                  else
                     Diagnostic := To_Unbounded_String
                       ("remote config line" & Natural'Image (Line_No) &
                        ": unknown key '" & Key & "'");
                     Ada.Text_IO.Close (File);
                     return False;
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return True;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Diagnostic := To_Unbounded_String
           ("could not read remote config file: " & Path);
         return False;
   end Load_Remote_Config;

   function Contains_Normalized
     (Paths : String_Vectors.Vector;
      Path  : String)
      return Boolean
   is
      Normalized : constant String := Normalize_Path (Path);
   begin
      for Existing of Paths loop
         if Normalize_Path (Existing) = Normalized then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Normalized;

   function Validate_Final
     (Config     : Configuration;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Output_Normalized : constant String := To_String (Config.Output_Path);
      Catalog_Command : constant Boolean :=
        Backup.CLI_Syntax.Any_Catalog_Command
          (Length (Config.Catalog_Index) > 0,
           Length (Config.Catalog_Query) > 0,
           Config.Catalog_List_Archives,
           Config.Catalog_List_Contents,
           Config.Catalog_Verify);
   begin
      if Catalog_Command then
         if Length (Config.Catalog_File) = 0 then
            Diagnostic := To_Unbounded_String
              ("catalog commands require --catalog FILE");
            return False;
         end if;

         if Backup.CLI_Syntax.Job_Command_Selected
           (Config.Run_Job, Config.Create_Job)
         then
            Diagnostic := To_Unbounded_String
              ("catalog commands cannot be combined with job management commands");
            return False;
         end if;

         if Output_Normalized /= "" or else not Config.Input_Paths.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("catalog commands do not accept positional output or input paths");
            return False;
         end if;

         if Config.Dry_Run
           or else Config.Manifest
           or else Config.Deterministic
           or else Config.Verify
           or else Config.List_Archive
           or else Config.Extract
           or else not Config.Ignore_Files.Is_Empty
           or else Length (Config.Prefix) > 0
           or else Config.Compression_Set
           or else Config.Symlinks_Set
           or else Config.Max_File_Size.Is_Set
           or else Config.Max_Total_Size.Is_Set
           or else Config.Encrypt
           or else (Config.Password.Kind /= Backup.Encryption.Password_None
                    and then Length (Config.Catalog_Index) = 0)
           or else Config.Cipher_Set
           or else Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
           or else Config.Upload_Remote
           or else Config.Sync_Remote
           or else Config.Restore_Remote
           or else not Config.Restore_Only.Is_Empty
           or else not Config.Restore_Exclude.Is_Empty
           or else Config.Restore_Conflict /= Conflict_Reject
         then
            Diagnostic := To_Unbounded_String
              ("catalog commands cannot be combined with one-shot backup options");
            return False;
         end if;

         if not Backup.CLI_Syntax.Exactly_One_Catalog_Command
           (Length (Config.Catalog_Index) > 0,
            Length (Config.Catalog_Query) > 0,
            Config.Catalog_List_Archives,
            Config.Catalog_List_Contents,
            Config.Catalog_Verify)
         then
            Diagnostic := To_Unbounded_String
              ("choose exactly one catalog command: --index, --query, " &
               "--list-archives, --list-contents, or --verify-catalog");
            return False;
         end if;

         if Length (Config.Catalog_Index) > 0 then
            if not Ada.Directories.Exists (To_String (Config.Catalog_Index)) then
               Diagnostic := To_Unbounded_String
                 ("archive for --index does not exist: " &
                  To_String (Config.Catalog_Index));
               return False;
            end if;
         elsif not Config.Catalog_Verify
           and then not Ada.Directories.Exists (To_String (Config.Catalog_File))
         then
            Diagnostic := To_Unbounded_String
              ("catalog file does not exist: " &
               To_String (Config.Catalog_File));
            return False;
         end if;

         return True;
      end if;

      if Length (Config.Catalog_File) > 0 then
         if Config.Dry_Run then
            Diagnostic := To_Unbounded_String
              ("--catalog FILE cannot be used with --dry-run because " &
               "no archive is created to index");
            return False;
         elsif Config.Extract or else Config.Restore_Remote then
            Diagnostic := To_Unbounded_String
              ("--catalog FILE without a catalog command is only valid " &
               "for backup creation or archive verification");
            return False;
         elsif Backup.CLI_Syntax.Job_Command_Selected
           (Config.Run_Job, Config.Create_Job)
         then
            Diagnostic := To_Unbounded_String
              ("--catalog FILE cannot be combined directly with job " &
               "management commands; put catalog settings in the job " &
               "definition");
            return False;
         end if;
      end if;

      if Backup.CLI_Syntax.Job_Command_Selected
        (Config.Run_Job, Config.Create_Job)
      then
         if Backup.CLI_Syntax.Job_Command_Conflict
           (Config.Run_Job, Config.Create_Job)
         then
            Diagnostic := To_Unbounded_String
              ("choose only one of --run-job and --create-job");
            return False;
         end if;

         if Config.Run_Job and then Length (Config.Job_File) = 0 then
            Diagnostic := To_Unbounded_String ("--run-job requires a file");
            return False;
         end if;

         if Length (Config.Retention_Override) > 0 and then not Config.Run_Job then
            Diagnostic := To_Unbounded_String
              ("--retention-policy can only be used with --run-job");
            return False;
         end if;

         if Config.Create_Job and then Length (Config.Create_Job_File) = 0 then
            Diagnostic := To_Unbounded_String ("--create-job requires a file");
            return False;
         end if;

         if Output_Normalized /= "" or else not Config.Input_Paths.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("job management commands do not accept positional output or input paths");
            return False;
         end if;

         if Config.Dry_Run
           or else Config.Manifest
           or else Config.Deterministic
           or else Config.List_JSON
           or else Config.Verify
           or else Config.List_Archive
           or else Config.Extract
           or else not Config.Ignore_Files.Is_Empty
           or else Length (Config.Prefix) > 0
           or else Config.Compression_Set
           or else Config.Symlinks_Set
           or else Config.Max_File_Size.Is_Set
           or else Config.Max_Total_Size.Is_Set
           or else Config.Encrypt
           or else Config.Password.Kind /= Backup.Encryption.Password_None
           or else Config.Cipher_Set
           or else Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
           or else Length (Config.Remote_URL) > 0
           or else Length (Config.Remote_Config) > 0
           or else Config.Upload_Remote
           or else Config.Sync_Remote
           or else Config.Restore_Remote
           or else Config.Clean_PCloud_Temporary
           or else Config.Check_PCloud_Remote
           or else Length (Config.Catalog_File) > 0
           or else Length (Config.Catalog_Index) > 0
           or else Length (Config.Catalog_Query) > 0
           or else Config.Catalog_List_Archives
           or else Config.Catalog_List_Contents
           or else Config.Catalog_Verify
           or else not Config.Restore_Only.Is_Empty
           or else not Config.Restore_Exclude.Is_Empty
           or else Config.Restore_Conflict /= Conflict_Reject
         then
            Diagnostic := To_Unbounded_String
              ("job management commands cannot be combined with one-shot backup options");
            return False;
         end if;

         return True;
      end if;

      if Length (Config.Retention_Override) > 0 then
         Diagnostic := To_Unbounded_String
           ("--retention-policy can only be used with --run-job");
         return False;
      end if;

      if (Backup.CLI_Syntax.Remote_Operation_Selected
            (Config.Upload_Remote, Config.Sync_Remote, Config.Restore_Remote)
          or else Config.Clean_PCloud_Temporary
          or else Config.Check_PCloud_Remote)
        and then Length (Config.Remote_URL) = 0
      then
         Diagnostic := To_Unbounded_String
           ("remote operations require --remote URL");
         return False;
      end if;

      if Length (Config.Remote_Config) > 0
        and then not Backup.CLI_Syntax.Remote_Operation_Selected
          (Config.Upload_Remote, Config.Sync_Remote, Config.Restore_Remote)
        and then not Config.Clean_PCloud_Temporary
        and then not Config.Check_PCloud_Remote
      then
         Diagnostic := To_Unbounded_String
           ("--remote-config can only be used with a remote operation");
         return False;
      end if;

      if Length (Config.Remote_Config) > 0
        and then not Ada.Directories.Exists (To_String (Config.Remote_Config))
      then
         Diagnostic := To_Unbounded_String
           ("remote config file does not exist: " &
            To_String (Config.Remote_Config));
         return False;
      end if;

      if (Config.Clean_PCloud_Temporary or else Config.Check_PCloud_Remote) and then
        Backup.CLI_Syntax.Remote_Operation_Selected
          (Config.Upload_Remote, Config.Sync_Remote, Config.Restore_Remote)
      then
         Diagnostic := To_Unbounded_String
           ("--pcloud-clean-temp/--pcloud-check cannot be combined with upload, sync, or remote restore");
         return False;
      end if;

      if Backup.CLI_Syntax.Remote_Direction_Conflict
        (Config.Upload_Remote, Config.Sync_Remote, Config.Restore_Remote)
      then
         if Config.Upload_Remote then
            Diagnostic := To_Unbounded_String
              ("--upload cannot be combined with --restore-remote");
         else
            Diagnostic := To_Unbounded_String
              ("--sync cannot be combined with --restore-remote");
         end if;
         return False;
      end if;

      if Config.Check_PCloud_Remote then
         if not Config.Input_Paths.Is_Empty or else Output_Normalized /= "" then
            Diagnostic := To_Unbounded_String
              ("--pcloud-check accepts --remote URL and no archive paths");
            return False;
         end if;
         return True;
      end if;

      if Config.Clean_PCloud_Temporary then
         if not Config.Input_Paths.Is_Empty or else Output_Normalized /= "" then
            Diagnostic := To_Unbounded_String
              ("--pcloud-clean-temp accepts --remote URL and no archive paths");
            return False;
         end if;
         if Config.Encrypt
           or else Config.Manifest
           or else Config.Deterministic
           or else Config.Verify
           or else Config.List_Archive
           or else Config.Extract
           or else Config.Compression_Set
           or else Config.Symlinks_Set
           or else Config.Max_File_Size.Is_Set
           or else Config.Max_Total_Size.Is_Set
           or else Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
         then
            Diagnostic := To_Unbounded_String
              ("--pcloud-clean-temp cannot be combined with archive creation, verification, extraction, or incremental options");
            return False;
         end if;
         return True;
      end if;

      if Config.Restore_Remote then
         if not Config.Input_Paths.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("--restore-remote accepts a local output archive path and no input paths");
            return False;
         end if;

         if Config.Encrypt
           or else Config.Manifest
           or else Config.Deterministic
           or else Config.Verify
           or else Config.List_Archive
           or else Config.Extract
           or else Config.Compression_Set
           or else Config.Symlinks_Set
           or else Config.Max_File_Size.Is_Set
           or else Config.Max_Total_Size.Is_Set
           or else Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
         then
            Diagnostic := To_Unbounded_String
              ("--restore-remote cannot be combined with archive creation, verification, extraction, or incremental options");
            return False;
         end if;

         if Output_Normalized = "" then
            Diagnostic := To_Unbounded_String
              ("--restore-remote requires a local output archive path");
            return False;
         end if;

         return True;
      end if;

      if Output_Normalized = "" then
         Diagnostic := To_Unbounded_String ("missing output ZIP path");
         return False;
      end if;

      if Config.Remote_Options.Require_Encrypted
        and then Backup.CLI_Syntax.Remote_Upload_Or_Sync
          (Config.Upload_Remote, Config.Sync_Remote)
        and then not Config.Encrypt
      then
         Diagnostic := To_Unbounded_String
           ("--remote-require-encrypted requires --encrypt for remote upload or sync");
         return False;
      end if;

      if Config.Encrypt and then Config.Deterministic then
         Diagnostic := To_Unbounded_String
           ("--encrypt cannot be combined with --deterministic");
         return False;
      end if;

      if Config.Encrypt
        and then Config.Password.Kind = Backup.Encryption.Password_None
      then
         Diagnostic := To_Unbounded_String
           ("--encrypt requires --password-file, --password-env, or --password-prompt");
         return False;
      end if;

      if Config.Cipher_Set and then not Config.Encrypt then
         Diagnostic := To_Unbounded_String
           ("--cipher can only be used with --encrypt");
         return False;
      end if;

      if Config.Password.Kind /= Backup.Encryption.Password_None
        and then not Config.Encrypt
        and then not Config.Verify
        and then not Config.List_Archive
        and then not Config.Extract
        and then Length (Config.Incremental_From_Archive) = 0
      then
         Diagnostic := To_Unbounded_String
           ("password source can only be used with --encrypt, --verify, " &
            "--list, --extract, or --incremental-from");
         return False;
      end if;

      if Config.List_Archive then
         if Length (Config.Remote_URL) > 0 or else Config.Upload_Remote or else Config.Sync_Remote then
            Diagnostic := To_Unbounded_String
              ("--list cannot be combined with remote upload or sync options");
            return False;
         end if;

         if Config.Encrypt then
            Diagnostic := To_Unbounded_String
              ("--list cannot be combined with --encrypt");
            return False;
         end if;

         if Config.Verify or else Config.Extract then
            Diagnostic := To_Unbounded_String
              ("--list cannot be combined with --verify or --extract");
            return False;
         end if;

         if not Config.Input_Paths.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("--list accepts only the archive path and no input paths");
            return False;
         end if;

         if Config.Dry_Run then
            Diagnostic := To_Unbounded_String
              ("--list cannot be combined with --dry-run");
            return False;
         end if;

         if Config.Manifest
           or else not Config.Ignore_Files.Is_Empty
           or else Length (Config.Prefix) > 0
           or else Config.Compression_Set
           or else Config.Symlinks_Set
           or else Config.Max_File_Size.Is_Set
           or else Config.Max_Total_Size.Is_Set
           or else Config.Deterministic
           or else Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
           or else Length (Config.Output_Dir) > 0
           or else not Config.Restore_Only.Is_Empty
           or else not Config.Restore_Exclude.Is_Empty
           or else Config.Restore_Conflict /= Conflict_Reject
         then
            Diagnostic := To_Unbounded_String
              ("--list cannot be combined with backup creation or restore options");
            return False;
         end if;

         return True;
      end if;

      if Config.Extract then
         if Length (Config.Remote_URL) > 0 or else Config.Upload_Remote or else Config.Sync_Remote then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with remote upload or sync options");
            return False;
         end if;

         if Config.Encrypt then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --encrypt");
            return False;
         end if;

         if Config.Verify then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --verify");
            return False;
         end if;

         if not Config.Input_Paths.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("--extract accepts --extract ARCHIVE.zip --output-dir DIR and no input paths");
            return False;
         end if;

         if Length (Config.Output_Dir) = 0 then
            Diagnostic := To_Unbounded_String
              ("--extract requires --output-dir DIR");
            return False;
         end if;

         if Config.Manifest then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --manifest; manifest checks are automatic when present");
            return False;
         end if;

         if not Config.Ignore_Files.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --ignore");
            return False;
         end if;

         if Length (Config.Prefix) > 0 then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --prefix");
            return False;
         end if;

         if Config.Compression_Set then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --compression");
            return False;
         end if;

         if Config.Symlinks = Symlinks_Follow then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --symlinks=follow");
            return False;
         end if;

         if Config.Max_File_Size.Is_Set then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --max-file-size");
            return False;
         end if;

         if Config.Max_Total_Size.Is_Set then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --max-total-size");
            return False;
         end if;

         if Config.Deterministic then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with --deterministic");
            return False;
         end if;

         if Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
         then
            Diagnostic := To_Unbounded_String
              ("--extract cannot be combined with incremental options");
            return False;
         end if;

         return True;
      end if;

      if Config.Verify then
         if Length (Config.Remote_URL) > 0 or else Config.Upload_Remote or else Config.Sync_Remote then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with remote upload or sync options");
            return False;
         end if;

         if Config.Encrypt then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --encrypt");
            return False;
         end if;

         if not Config.Input_Paths.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("--verify accepts only the archive path and no input paths");
            return False;
         end if;

         if Config.Dry_Run then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --dry-run");
            return False;
         end if;

         if Config.Manifest then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --manifest; " &
               "manifest checks are automatic when present");
            return False;
         end if;

         if not Config.Ignore_Files.Is_Empty then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --ignore");
            return False;
         end if;

         if Length (Config.Prefix) > 0 then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --prefix");
            return False;
         end if;

         if Config.Compression_Set then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --compression");
            return False;
         end if;

         if Config.Symlinks_Set then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --symlinks");
            return False;
         end if;

         if Config.Max_File_Size.Is_Set then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --max-file-size");
            return False;
         end if;

         if Config.Max_Total_Size.Is_Set then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --max-total-size");
            return False;
         end if;

         if Config.Deterministic then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with --deterministic");
            return False;
         end if;

         if Length (Config.Incremental_From_Archive) > 0
           or else Length (Config.Incremental_From_Manifest) > 0
         then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with incremental options");
            return False;
         end if;

         if not Config.Restore_Only.Is_Empty
           or else not Config.Restore_Exclude.Is_Empty
           or else Config.Restore_Conflict /= Conflict_Reject
           or else Length (Config.Output_Dir) > 0
         then
            Diagnostic := To_Unbounded_String
              ("--verify cannot be combined with restore options");
            return False;
         end if;

         return True;
      end if;

      if Config.Input_Paths.Is_Empty then
         Diagnostic := To_Unbounded_String ("missing input path");
         return False;
      end if;

      if Length (Config.Incremental_From_Archive) > 0
        and then Length (Config.Incremental_From_Manifest) > 0
      then
         Diagnostic := To_Unbounded_String
           ("choose only one of --incremental-from or " &
            "--incremental-from-manifest");
         return False;
      end if;

      if Length (Config.Incremental_From_Archive) > 0
        and then not Ada.Directories.Exists
          (To_String (Config.Incremental_From_Archive))
      then
         Diagnostic := To_Unbounded_String
           ("incremental archive does not exist: " &
            To_String (Config.Incremental_From_Archive));
         return False;
      end if;

      if Length (Config.Incremental_From_Archive) > 0
        and then Ada.Directories.Exists
          (To_String (Config.Incremental_From_Archive))
        and then Ada.Directories.Kind
          (To_String (Config.Incremental_From_Archive))
          /= Ada.Directories.Ordinary_File
      then
         Diagnostic := To_Unbounded_String
           ("incremental archive is not an ordinary file: " &
            To_String (Config.Incremental_From_Archive));
         return False;
      end if;

      if Length (Config.Incremental_From_Archive) > 0
        and then Normalize_Path (To_String (Config.Incremental_From_Archive))
          = Output_Normalized
      then
         Diagnostic := To_Unbounded_String
           ("output ZIP path must not also be the incremental archive: " &
            To_String (Config.Incremental_From_Archive));
         return False;
      end if;

      if Length (Config.Incremental_From_Manifest) > 0
        and then not Ada.Directories.Exists
          (To_String (Config.Incremental_From_Manifest))
      then
         Diagnostic := To_Unbounded_String
           ("incremental manifest does not exist: " &
            To_String (Config.Incremental_From_Manifest));
         return False;
      end if;

      if Length (Config.Incremental_From_Manifest) > 0
        and then Ada.Directories.Exists
          (To_String (Config.Incremental_From_Manifest))
        and then Ada.Directories.Kind
          (To_String (Config.Incremental_From_Manifest))
          /= Ada.Directories.Ordinary_File
      then
         Diagnostic := To_Unbounded_String
           ("incremental manifest is not an ordinary file: " &
            To_String (Config.Incremental_From_Manifest));
         return False;
      end if;

      if Length (Config.Incremental_From_Manifest) > 0
        and then Normalize_Path (To_String (Config.Incremental_From_Manifest))
          = Output_Normalized
      then
         Diagnostic := To_Unbounded_String
           ("output ZIP path must not also be the incremental manifest: " &
            To_String (Config.Incremental_From_Manifest));
         return False;
      end if;

      for Ignore_File of Config.Ignore_Files loop
         if not Ada.Directories.Exists (Ignore_File) then
            Diagnostic := To_Unbounded_String
              ("ignore file does not exist: " & Ignore_File);
            return False;
         end if;

         if Ada.Directories.Kind (Ignore_File)
           /= Ada.Directories.Ordinary_File
         then
            Diagnostic := To_Unbounded_String
              ("ignore path is not an ordinary file: " & Ignore_File);
            return False;
         end if;
      end loop;

      declare
         Seen : String_Vectors.Vector;
      begin
         for Input_Path of Config.Input_Paths loop
            if Contains_Normalized (Seen, Input_Path) then
               Diagnostic := To_Unbounded_String
                 ("duplicate input path after normalization: " & Input_Path);
               return False;
            end if;

            if Normalize_Path (Input_Path) = Output_Normalized then
               Diagnostic := To_Unbounded_String
                 ("output ZIP path must not also be an input path: " &
                  Input_Path);
               return False;
            end if;

            Seen.Append (Input_Path);
         end loop;
      end;

      pragma Assert
        (not Config.Input_Paths.Is_Empty,
         "validated config has inputs");
      pragma Assert
        (To_String (Config.Output_Path)'Length > 0,
         "validated config has output");
      return True;
   end Validate_Final;

   function Parse
     (Arguments  : String_Vectors.Vector;
      Config     : out Configuration;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Positional : String_Vectors.Vector;
      Index      : Positive := 1;
      Value      : Unbounded_String;
   begin
      Config := (Output_Path    => Null_Unbounded_String,
                 Input_Paths    => String_Vectors.Empty_Vector,
                 Ignore_Files   => String_Vectors.Empty_Vector,
                 Prefix         => Null_Unbounded_String,
                 Dry_Run        => False,
                 Manifest       => False,
                 Deterministic  => False,
                 List_JSON      => False,
                 Verify         => False,
                 List_Archive   => False,
                 Extract        => False,
                 Output_Dir     => Null_Unbounded_String,
                 Restore_Only   => String_Vectors.Empty_Vector,
                 Restore_Exclude => String_Vectors.Empty_Vector,
                 Restore_Conflict => Conflict_Reject,
                 Incremental_From_Archive  => Null_Unbounded_String,
                 Incremental_From_Manifest => Null_Unbounded_String,
                 Compression    => Compression_Auto,
                 Compression_Set => False,
                 Symlinks       => Symlinks_Skip,
                 Symlinks_Set    => False,
                 Max_File_Size  => (Is_Set => False, Value => 0),
                 Max_Total_Size => (Is_Set => False, Value => 0),
                 Encrypt        => False,
                 Password       => (Kind  => Backup.Encryption.Password_None,
                                    Value => Null_Unbounded_String),
                 Cipher         => Backup.Encryption.Cipher_AES256_GCM,
                 Cipher_Set     => False,
                 Job_File       => Null_Unbounded_String,
                 Create_Job_File => Null_Unbounded_String,
                 Run_Job        => False,
                 Create_Job     => False,
                 Retention_Override => Null_Unbounded_String,
                 Remote_URL     => Null_Unbounded_String,
                 Remote_Config  => Null_Unbounded_String,
                 Upload_Remote  => False,
                 Sync_Remote    => False,
                 Restore_Remote => False,
                 Clean_PCloud_Temporary => False,
                 Check_PCloud_Remote => False,
                 Remote_Options => (Require_Encrypted => False,
                                    Upload_Behavior => Backup.Remote.Upload_Atomic,
                                    Retry_Count => 0,
                                    Timeout_Seconds => 60, others => <>),
                 Catalog_File => Null_Unbounded_String,
                 Catalog_Index => Null_Unbounded_String,
                 Catalog_Query => Null_Unbounded_String,
                 Catalog_List_Archives => False,
                 Catalog_List_Contents => False,
                 Catalog_Verify => False,
                 Json_Errors => False);
      Diagnostic := Null_Unbounded_String;

      if Arguments.Is_Empty then
         Diagnostic := To_Unbounded_String ("missing output ZIP path");
         return False;
      end if;

      while Index <= Positive (Arguments.Last_Index) loop
         declare
            Arg : constant String := Arguments.Element (Index);
         begin
            if Arg = "--catalog" then
               if not Consume_Value
                 (Arguments, Index, "--catalog", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--catalog requires a file");
                  return False;
               end if;
               Config.Catalog_File := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--catalog=") then
               if Arg'Length = 10 then
                  Diagnostic := To_Unbounded_String
                    ("--catalog requires a file");
                  return False;
               end if;
               Config.Catalog_File := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 10 .. Arg'Last)));
            elsif Arg = "--index" then
               if not Consume_Value
                 (Arguments, Index, "--index", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--index requires an archive path");
                  return False;
               end if;
               Config.Catalog_Index := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--index=") then
               if Arg'Length = 8 then
                  Diagnostic := To_Unbounded_String
                    ("--index requires an archive path");
                  return False;
               end if;
               Config.Catalog_Index := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 8 .. Arg'Last)));
            elsif Arg = "--query" then
               if not Consume_Value
                 (Arguments, Index, "--query", Value, Diagnostic)
               then
                  return False;
               end if;
               Config.Catalog_Query := Value;
            elsif Starts_With (Arg, "--query=") then
               Config.Catalog_Query := To_Unbounded_String
                 (Arg (Arg'First + 8 .. Arg'Last));
            elsif Arg = "--list-archives" then
               Config.Catalog_List_Archives := True;
            elsif Arg = "--list-contents" then
               Config.Catalog_List_Contents := True;
            elsif Arg = "--verify-catalog" then
               Config.Catalog_Verify := True;
            elsif Arg = "--job" or else Arg = "--run-job" then
               if not Consume_Value
                 (Arguments, Index, Arg, Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String (Arg & " requires a file");
                  return False;
               end if;
               if Config.Run_Job then
                  Diagnostic := To_Unbounded_String
                    ("choose only one job file option");
                  return False;
               end if;
               Config.Run_Job := True;
               Config.Job_File := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--job=") then
               if Arg'Length = 6 then
                  Diagnostic := To_Unbounded_String ("--job requires a file");
                  return False;
               end if;
               if Config.Run_Job then
                  Diagnostic := To_Unbounded_String
                    ("choose only one job file option");
                  return False;
               end if;
               Config.Run_Job := True;
               Config.Job_File := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 6 .. Arg'Last)));
            elsif Starts_With (Arg, "--run-job=") then
               if Arg'Length = 10 then
                  Diagnostic := To_Unbounded_String ("--run-job requires a file");
                  return False;
               end if;
               if Config.Run_Job then
                  Diagnostic := To_Unbounded_String
                    ("choose only one job file option");
                  return False;
               end if;
               Config.Run_Job := True;
               Config.Job_File := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 10 .. Arg'Last)));
            elsif Arg = "--create-job" then
               if not Consume_Value
                 (Arguments, Index, "--create-job", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--create-job requires a file");
                  return False;
               end if;
               if Config.Create_Job then
                  Diagnostic := To_Unbounded_String
                    ("choose only one create-job option");
                  return False;
               end if;
               Config.Create_Job := True;
               Config.Create_Job_File := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--create-job=") then
               if Arg'Length = 13 then
                  Diagnostic := To_Unbounded_String
                    ("--create-job requires a file");
                  return False;
               end if;
               if Config.Create_Job then
                  Diagnostic := To_Unbounded_String
                    ("choose only one create-job option");
                  return False;
               end if;
               Config.Create_Job := True;
               Config.Create_Job_File := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 13 .. Arg'Last)));
            elsif Arg = "--retention-policy" then
               if not Consume_Value
                 (Arguments, Index, "--retention-policy", Value, Diagnostic)
               then
                  return False;
               end if;
               Config.Retention_Override := Value;
            elsif Starts_With (Arg, "--retention-policy=") then
               if Arg'Length = 19 then
                  Diagnostic := To_Unbounded_String
                    ("--retention-policy requires a value");
                  return False;
               end if;
               Config.Retention_Override := To_Unbounded_String
                 (Arg (Arg'First + 19 .. Arg'Last));
            elsif Arg = "--remote" then
               if not Consume_Value
                 (Arguments, Index, "--remote", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--remote requires a non-empty URL");
                  return False;
               end if;
               Config.Remote_URL := Value;
            elsif Starts_With (Arg, "--remote=") then
               if Arg'Length = 9 then
                  Diagnostic := To_Unbounded_String
                    ("--remote requires a non-empty URL");
                  return False;
               end if;
               Config.Remote_URL := To_Unbounded_String
                 (Arg (Arg'First + 9 .. Arg'Last));
            elsif Arg = "--remote-config" then
               if not Consume_Value
                 (Arguments, Index, "--remote-config", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--remote-config requires a non-empty file path");
                  return False;
               end if;
               Config.Remote_Config := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--remote-config=") then
               if Arg'Length = 16 then
                  Diagnostic := To_Unbounded_String
                    ("--remote-config requires a non-empty file path");
                  return False;
               end if;
               Config.Remote_Config := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 16 .. Arg'Last)));
            elsif Arg = "--upload" then
               Config.Upload_Remote := True;
            elsif Arg = "--sync" then
               Config.Sync_Remote := True;
            elsif Arg = "--restore-remote" then
               Config.Restore_Remote := True;
            elsif Arg = "--pcloud-clean-temp" then
               Config.Clean_PCloud_Temporary := True;
            elsif Arg = "--pcloud-check" then
               Config.Check_PCloud_Remote := True;
            elsif Arg = "--remote-require-encrypted" then
               Config.Remote_Options.Require_Encrypted := True;
            elsif Arg = "--remote-resume" then
               Config.Remote_Options.Upload_Behavior := Backup.Remote.Upload_Resume_If_Supported;
            elsif Arg = "--password-prompt" then
               if Config.Password.Kind /= Backup.Encryption.Password_None then
                  Diagnostic := To_Unbounded_String
                    ("choose only one password source");
                  return False;
               end if;
               Config.Password :=
                 (Kind  => Backup.Encryption.Password_Prompt,
                  Value => Null_Unbounded_String);
            elsif Arg = "--dry-run" then
               Config.Dry_Run := True;
            elsif Arg = "--manifest" then
               Config.Manifest := True;
            elsif Arg = "--deterministic" then
               Config.Deterministic := True;
            elsif Arg = "--list-json" then
               Config.List_JSON := True;
            elsif Arg = "--json-errors" then
               Config.Json_Errors := True;
            elsif Arg = "--verify" then
               Config.Verify := True;
            elsif Arg = "--list" then
               if not Consume_Value
                 (Arguments, Index, "--list", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--list requires an archive path");
                  return False;
               end if;
               Config.List_Archive := True;
               Config.Output_Path := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--list=") then
               if Arg'Length = 7 then
                  Diagnostic := To_Unbounded_String
                    ("--list requires an archive path");
                  return False;
               end if;
               Config.List_Archive := True;
               Config.Output_Path := To_Unbounded_String
                 (Normalize_Path (Arg (Arg'First + 7 .. Arg'Last)));
            elsif Arg = "--extract" then
               if not Consume_Value
                 (Arguments, Index, "--extract", Value, Diagnostic)
               then
                  return False;
               end if;
               Config.Extract := True;
               Config.Output_Path := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Arg = "--output-dir" then
               if not Consume_Value
                 (Arguments, Index, "--output-dir", Value, Diagnostic)
               then
                  return False;
               end if;
               Config.Output_Dir := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Arg = "--only" then
               if not Consume_Value
                 (Arguments, Index, "--only", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--only requires an archive path");
                  return False;
               end if;
               Config.Restore_Only.Append (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--only=") then
               if Arg'Length = 7 then
                  Diagnostic := To_Unbounded_String
                    ("--only requires an archive path");
                  return False;
               end if;
               Config.Restore_Only.Append
                 (Normalize_Path (Arg (Arg'First + 7 .. Arg'Last)));
            elsif Arg = "--exclude" then
               if not Consume_Value
                 (Arguments, Index, "--exclude", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--exclude requires an archive path");
                  return False;
               end if;
               Config.Restore_Exclude.Append (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--exclude=") then
               if Arg'Length = 10 then
                  Diagnostic := To_Unbounded_String
                    ("--exclude requires an archive path");
                  return False;
               end if;
               Config.Restore_Exclude.Append
                 (Normalize_Path (Arg (Arg'First + 10 .. Arg'Last)));
            elsif Arg = "--overwrite" then
               if not Backup.CLI_Syntax.Restore_Conflict_Can_Be_Set
                 (Config.Restore_Conflict /= Conflict_Reject)
               then
                  Diagnostic := To_Unbounded_String
                    ("choose only one restore conflict policy");
                  return False;
               end if;
               Config.Restore_Conflict := Conflict_Overwrite;
            elsif Arg = "--skip-existing" then
               if not Backup.CLI_Syntax.Restore_Conflict_Can_Be_Set
                 (Config.Restore_Conflict /= Conflict_Reject)
               then
                  Diagnostic := To_Unbounded_String
                    ("choose only one restore conflict policy");
                  return False;
               end if;
               Config.Restore_Conflict := Conflict_Skip;
            elsif Arg = "--rename-existing" then
               if not Backup.CLI_Syntax.Restore_Conflict_Can_Be_Set
                 (Config.Restore_Conflict /= Conflict_Reject)
               then
                  Diagnostic := To_Unbounded_String
                    ("choose only one restore conflict policy");
                  return False;
               end if;
               Config.Restore_Conflict := Conflict_Rename;
            elsif Arg = "--incremental-from" then
               if not Consume_Value
                 (Arguments, Index, "--incremental-from", Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--incremental-from requires a non-empty value");
                  return False;
               end if;
               Config.Incremental_From_Archive := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--incremental-from=") then
               if Arg'Length = 19 then
                  Diagnostic := To_Unbounded_String
                    ("--incremental-from requires a non-empty value");
                  return False;
               end if;
               Config.Incremental_From_Archive := To_Unbounded_String
                 (Normalize_Path
                    (Arg (Arg'First + 19 .. Arg'Last)));
            elsif Arg = "--incremental-from-manifest" then
               if not Consume_Value
                 (Arguments, Index, "--incremental-from-manifest",
                  Value, Diagnostic)
               then
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--incremental-from-manifest requires a non-empty value");
                  return False;
               end if;
               Config.Incremental_From_Manifest := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Starts_With (Arg, "--incremental-from-manifest=") then
               if Arg'Length = 28 then
                  Diagnostic := To_Unbounded_String
                    ("--incremental-from-manifest requires a non-empty value");
                  return False;
               end if;
               Config.Incremental_From_Manifest := To_Unbounded_String
                 (Normalize_Path
                    (Arg (Arg'First + 28 .. Arg'Last)));
            elsif Arg = "--encrypt" then
               Config.Encrypt := True;
            elsif Arg = "--password-file" then
               if not Consume_Value
                 (Arguments, Index, "--password-file", Value, Diagnostic)
               then
                  return False;
               end if;
               if Config.Password.Kind /= Backup.Encryption.Password_None then
                  Diagnostic := To_Unbounded_String
                    ("choose only one password source");
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--password-file requires a non-empty value");
                  return False;
               end if;
               Config.Password :=
                 (Kind  => Backup.Encryption.Password_File,
                  Value => To_Unbounded_String
                    (Normalize_Path (To_String (Value))));
            elsif Starts_With (Arg, "--password-file=") then
               if Arg'Length = 16 then
                  Diagnostic := To_Unbounded_String
                    ("--password-file requires a non-empty value");
                  return False;
               end if;
               if Config.Password.Kind /= Backup.Encryption.Password_None then
                  Diagnostic := To_Unbounded_String
                    ("choose only one password source");
                  return False;
               end if;
               Config.Password :=
                 (Kind  => Backup.Encryption.Password_File,
                  Value => To_Unbounded_String
                    (Normalize_Path (Arg (Arg'First + 16 .. Arg'Last))));
            elsif Arg = "--password-env" then
               if not Consume_Value
                 (Arguments, Index, "--password-env", Value, Diagnostic)
               then
                  return False;
               end if;
               if Config.Password.Kind /= Backup.Encryption.Password_None then
                  Diagnostic := To_Unbounded_String
                    ("choose only one password source");
                  return False;
               end if;
               if Length (Value) = 0 then
                  Diagnostic := To_Unbounded_String
                    ("--password-env requires a non-empty value");
                  return False;
               end if;
               Config.Password :=
                 (Kind  => Backup.Encryption.Password_Env,
                  Value => Value);
            elsif Starts_With (Arg, "--password-env=") then
               if Arg'Length = 15 then
                  Diagnostic := To_Unbounded_String
                    ("--password-env requires a non-empty value");
                  return False;
               end if;
               if Config.Password.Kind /= Backup.Encryption.Password_None then
                  Diagnostic := To_Unbounded_String
                    ("choose only one password source");
                  return False;
               end if;
               Config.Password :=
                 (Kind  => Backup.Encryption.Password_Env,
                  Value => To_Unbounded_String
                    (Arg (Arg'First + 15 .. Arg'Last)));
            elsif Arg = "--cipher" then
               if not Consume_Value
                 (Arguments, Index, "--cipher", Value, Diagnostic)
               then
                  return False;
               end if;
               if not Backup.Encryption.Parse_Cipher
                 (To_String (Value), Config.Cipher, Diagnostic)
               then
                  return False;
               end if;
               Config.Cipher_Set := True;
            elsif Starts_With (Arg, "--cipher=") then
               if Arg'Length = 9 then
                  Diagnostic := To_Unbounded_String
                    ("--cipher requires a non-empty value");
                  return False;
               end if;
               if not Backup.Encryption.Parse_Cipher
                 (Arg (Arg'First + 9 .. Arg'Last),
                  Config.Cipher,
                  Diagnostic)
               then
                  return False;
               end if;
               Config.Cipher_Set := True;
            elsif Arg = "--ignore" then
               if not Consume_Value
                 (Arguments, Index, "--ignore", Value, Diagnostic)
               then
                  return False;
               end if;

               Config.Ignore_Files.Append (To_String (Value));
            elsif Arg = "--prefix" then
               if not Consume_Value
                 (Arguments, Index, "--prefix", Value, Diagnostic)
               then
                  return False;
               end if;

               if not Prefix_Is_Valid (To_String (Value)) then
                  Diagnostic := To_Unbounded_String
                    ("invalid --prefix value '" & To_String (Value) & "'");
                  return False;
               end if;

               Config.Prefix := To_Unbounded_String
                 (Normalize_Path (To_String (Value)));
            elsif Arg = "--max-file-size" then
               if not Consume_Value
                 (Arguments, Index, "--max-file-size", Value, Diagnostic)
               then
                  return False;
               end if;

               if not Parse_Size
                 (To_String (Value),
                  Config.Max_File_Size,
                  Diagnostic,
                  "--max-file-size")
               then
                  return False;
               end if;
            elsif Arg = "--max-total-size" then
               if not Consume_Value
                 (Arguments, Index, "--max-total-size", Value, Diagnostic)
               then
                  return False;
               end if;

               if not Parse_Size
                 (To_String (Value),
                  Config.Max_Total_Size,
                  Diagnostic,
                  "--max-total-size")
               then
                  return False;
               end if;
            elsif Starts_With (Arg, "--compression=") then
               if not Parse_Compression
                 (Arg (Arg'First + 14 .. Arg'Last),
                  Config.Compression,
                  Diagnostic)
               then
                  return False;
               end if;
               Config.Compression_Set := True;
            elsif Arg = "--compression" then
               Diagnostic := To_Unbounded_String
                 ("--compression requires '=auto', '=store', '=deflate', '=bzip2', '=lzma', or '=zstd'");
               return False;
            elsif Starts_With (Arg, "--symlinks=") then
               if not Parse_Symlinks
                 (Arg (Arg'First + 11 .. Arg'Last),
                  Config.Symlinks,
                  Diagnostic)
               then
                  return False;
               end if;
               Config.Symlinks_Set := True;
            elsif Arg = "--symlinks" then
               Diagnostic := To_Unbounded_String
                 ("--symlinks requires '=skip', '=store-link', or '=follow'");
               return False;
            elsif Is_Option (Arg) then
               Diagnostic := To_Unbounded_String ("unknown option: " & Arg);
               return False;
            else
               Positional.Append (Arg);
            end if;
         end;

         Index := Index + 1;
      end loop;

      if Backup.CLI_Syntax.Positional_Paths_Disallowed
        (Backup.CLI_Syntax.Any_Catalog_Command
           (Length (Config.Catalog_Index) > 0,
            Length (Config.Catalog_Query) > 0,
            Config.Catalog_List_Archives,
            Config.Catalog_List_Contents,
            Config.Catalog_Verify),
         Backup.CLI_Syntax.Job_Command_Selected
           (Config.Run_Job, Config.Create_Job),
         Config.List_Archive,
         Config.Extract)
      then
         if not Positional.Is_Empty then
            if Backup.CLI_Syntax.Any_Catalog_Command
              (Length (Config.Catalog_Index) > 0,
               Length (Config.Catalog_Query) > 0,
               Config.Catalog_List_Archives,
               Config.Catalog_List_Contents,
               Config.Catalog_Verify)
            then
               Diagnostic := To_Unbounded_String
                 ("catalog commands do not accept positional output or input paths");
            elsif Backup.CLI_Syntax.Job_Command_Selected
              (Config.Run_Job, Config.Create_Job)
            then
               Diagnostic := To_Unbounded_String
                 ("job management commands do not accept positional output or input paths");
            elsif Config.List_Archive then
               Diagnostic := To_Unbounded_String
                 ("--list does not accept positional output or input paths");
            else
               Diagnostic := To_Unbounded_String
                 ("--extract does not accept positional output or input paths");
            end if;
            return False;
         end if;
      else
         if Positional.Is_Empty then
            Diagnostic := To_Unbounded_String ("missing output ZIP path");
            return False;
         end if;

         Config.Output_Path := To_Unbounded_String
           (Normalize_Path (Positional.First_Element));

         if Positional.Length > 1 then
            for Input_Index in Positive'Succ (Positional.First_Index)
              .. Positional.Last_Index
            loop
               Config.Input_Paths.Append (Positional.Element (Input_Index));
            end loop;
         end if;
      end if;

      if Length (Config.Remote_Config) > 0 then
         if not Load_Remote_Config
           (To_String (Config.Remote_Config), Config, Diagnostic)
         then
            return False;
         end if;
      end if;

      return Validate_Final (Config, Diagnostic);
   end Parse;

   function Run return Exit_Status is
      Arguments  : String_Vectors.Vector;
      Config     : Configuration;
      Diagnostic : Unbounded_String;
      Status     : Backup.Workflow.Execution_Status;
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         Arguments.Append (Ada.Command_Line.Argument (Index));
      end loop;

      if Ada.Command_Line.Argument_Count = 1 then
         declare
            Arg : constant String := Ada.Command_Line.Argument (1);
         begin
            if Arg = "--help" or else Arg = "-h" then
               Print_Help;
               return Success;
            elsif Arg = "--help-advanced" then
               Print_Advanced_Help;
               return Success;
            elsif Arg = "--version" then
               Print_Version;
               return Success;
            elsif Arg = "--proton-drive-login" then
               Emit_Error
                 ("--proton-drive-login requires SESSION_FILE USER_ADDRESS USERNAME PASSWORD_PROOF [MFA_CODE] [SESSION_LABEL] [APP_VERSION] [API_BASE]",
                  Wants_JSON_Errors (Arguments));
               return Failure;
            end if;
         end;
      elsif Ada.Command_Line.Argument_Count = 3
        and then Ada.Command_Line.Argument (1) = "--pcloud-oauth-url"
      then
         Print_PCloud_OAuth_URL
           (Ada.Command_Line.Argument (2), Ada.Command_Line.Argument (3));
         return Success;
      elsif Ada.Command_Line.Argument_Count > 0
        and then Ada.Command_Line.Argument (1) = "--pcloud-oauth-url"
      then
         Emit_Error
           ("--pcloud-oauth-url requires CLIENT_ID and REDIRECT_URI",
            Wants_JSON_Errors (Arguments));
         return Failure;
      elsif (Ada.Command_Line.Argument_Count = 5
             or else Ada.Command_Line.Argument_Count = 6)
        and then Ada.Command_Line.Argument (1) = "--pcloud-oauth-token"
      then
         if Print_PCloud_OAuth_Token
           (Ada.Command_Line.Argument (2), Ada.Command_Line.Argument (3),
            Ada.Command_Line.Argument (4), Ada.Command_Line.Argument (5),
            (if Ada.Command_Line.Argument_Count = 6 then
                Ada.Command_Line.Argument (6)
             else ""))
         then
            return Success;
         else
            return Failure;
         end if;
      elsif Ada.Command_Line.Argument_Count > 0
        and then Ada.Command_Line.Argument (1) = "--pcloud-oauth-token"
      then
         Emit_Error
           ("--pcloud-oauth-token requires CLIENT_ID CLIENT_SECRET CODE REDIRECT_URI [API_BASE]",
            Wants_JSON_Errors (Arguments));
         return Failure;
      elsif Ada.Command_Line.Argument_Count in 5 .. 9
        and then Ada.Command_Line.Argument (1) = "--proton-drive-login"
      then
         if Run_Proton_Drive_Login
           (Ada.Command_Line.Argument (2),
            Ada.Command_Line.Argument (3),
            Ada.Command_Line.Argument (4),
            Ada.Command_Line.Argument (5),
            (if Ada.Command_Line.Argument_Count >= 6 then Ada.Command_Line.Argument (6) else ""),
            (if Ada.Command_Line.Argument_Count >= 7 then Ada.Command_Line.Argument (7) else ""),
            (if Ada.Command_Line.Argument_Count >= 8 then Ada.Command_Line.Argument (8) else ""),
            (if Ada.Command_Line.Argument_Count >= 9 then Ada.Command_Line.Argument (9) else ""))
         then
            return Success;
         else
            return Failure;
         end if;
      elsif Ada.Command_Line.Argument_Count > 0
        and then Ada.Command_Line.Argument (1) = "--proton-drive-login"
      then
         Emit_Error
           ("--proton-drive-login requires SESSION_FILE USER_ADDRESS USERNAME PASSWORD_PROOF [MFA_CODE] [SESSION_LABEL] [APP_VERSION] [API_BASE]",
            Wants_JSON_Errors (Arguments));
         return Failure;
      end if;

      if not Parse (Arguments, Config, Diagnostic) then
         Emit_Error (To_String (Diagnostic), Wants_JSON_Errors (Arguments));
         return Failure;
      end if;

      pragma Assert
        (Config.Run_Job
         or else Config.Create_Job
         or else Length (Config.Catalog_Index) > 0
         or else Length (Config.Catalog_Query) > 0
         or else Config.Catalog_List_Archives
         or else Config.Catalog_List_Contents
         or else Config.Catalog_Verify
         or else Config.Verify
         or else Config.List_Archive
         or else Config.Extract
         or else Config.Restore_Remote
         or else Config.Clean_PCloud_Temporary
         or else Config.Check_PCloud_Remote
         or else not Config.Input_Paths.Is_Empty,
         "successful command-line parse has inputs unless job management or existing-archive operations");

      if Length (Config.Catalog_Index) > 0 then
         declare
            Catalog : Backup.Catalog.Catalog_Data;
            Catalog_Status : constant Backup.Catalog.Catalog_Status :=
              Backup.Catalog.Index_Archive
                (To_String (Config.Catalog_File),
                 To_String (Config.Catalog_Index),
                 Config.Password,
                 Catalog,
                 Diagnostic);
            pragma Unreferenced (Catalog);
         begin
            if Catalog_Status /= Backup.Catalog.Catalog_Ok then
               Emit_Error (To_String (Diagnostic), Config.Json_Errors);
               return Failure;
            end if;
            return Success;
         end;
      end if;

      if Config.Catalog_Verify then
         declare
            Catalog : Backup.Catalog.Catalog_Data;
            Catalog_Status : constant Backup.Catalog.Catalog_Status :=
              Backup.Catalog.Verify_Catalog
                (To_String (Config.Catalog_File), Catalog, Diagnostic);
            pragma Unreferenced (Catalog);
         begin
            if Catalog_Status /= Backup.Catalog.Catalog_Ok then
               Emit_Error (To_String (Diagnostic), Config.Json_Errors);
               return Failure;
            end if;
            Ada.Text_IO.Put (To_String (Diagnostic));
            return Success;
         end;
      end if;

      if Length (Config.Catalog_Query) > 0
        or else Config.Catalog_List_Archives
        or else Config.Catalog_List_Contents
      then
         declare
            Catalog : Backup.Catalog.Catalog_Data;
            Parsed  : Backup.Catalog.Query;
            Result  : Backup.Catalog.Query_Result;
            Text    : Unbounded_String;
            Catalog_Status : Backup.Catalog.Catalog_Status;
         begin
            Catalog_Status := Backup.Catalog.Load
              (To_String (Config.Catalog_File), Catalog, Diagnostic);
            if Catalog_Status = Backup.Catalog.Catalog_Ok then
               if Config.Catalog_List_Archives then
                  Parsed := (Mode => Backup.Catalog.Query_Archives_Only,
                             Text => Null_Unbounded_String);
               elsif Config.Catalog_List_Contents then
                  Parsed := (Mode => Backup.Catalog.Query_Contents,
                             Text => Null_Unbounded_String);
               else
                  Catalog_Status := Backup.Catalog.Parse_Query
                    (To_String (Config.Catalog_Query), Parsed, Diagnostic);
               end if;
            end if;
            if Catalog_Status = Backup.Catalog.Catalog_Ok then
               Catalog_Status := Backup.Catalog.Query_Catalog
                 (Catalog, Parsed, Result, Diagnostic);
            end if;
            if Catalog_Status /= Backup.Catalog.Catalog_Ok then
               Emit_Error (To_String (Diagnostic), Config.Json_Errors);
               return Failure;
            end if;
            if Config.List_JSON then
               Backup.Catalog.Build_JSON_Report (Result, Text);
            else
               Backup.Catalog.Build_Human_Report (Result, Text);
            end if;
            Ada.Text_IO.Put (To_String (Text));
            return Success;
         end;
      end if;

      if Config.Create_Job then
         declare
            Job_Status : constant Backup.Jobs.Job_Status :=
              Backup.Jobs.Write_Template
                (To_String (Config.Create_Job_File), Diagnostic);
         begin
            if Job_Status /= Backup.Jobs.Job_Ok then
               Emit_Error (To_String (Diagnostic), Config.Json_Errors);
               return Failure;
            end if;
            return Success;
         end;
      end if;

      if Config.Run_Job then
         declare
            Job_Status : constant Backup.Jobs.Job_Status :=
              Backup.Jobs.Execute
                (To_String (Config.Job_File),
                 To_String (Config.Retention_Override),
                 Diagnostic);
         begin
            if Job_Status /= Backup.Jobs.Job_Ok then
               if Length (Diagnostic) > 0 then
                  if Config.Json_Errors then
                     Emit_Error (To_String (Diagnostic), True);
                  else
                     Ada.Text_IO.Put (To_String (Diagnostic));
                  end if;
               else
                  Emit_Error (Backup.Jobs.Status_Text (Job_Status), Config.Json_Errors);
               end if;
               return Failure;
            end if;
            if Length (Diagnostic) > 0 then
               Ada.Text_IO.Put (To_String (Diagnostic));
            end if;
            return Success;
         end;
      end if;



      if Config.Check_PCloud_Remote then
         declare
            Check_Status : constant Backup.Remote.Remote_Status :=
              Backup.Remote.Check_PCloud_Remote
                (To_String (Config.Remote_URL), Config.Remote_Options, Diagnostic);
         begin
            if Check_Status /= Backup.Remote.Remote_Ok then
               Emit_Error (To_String (Diagnostic), Config.Json_Errors);
               return Failure;
            end if;
            Ada.Text_IO.Put (To_String (Diagnostic));
            return Success;
         end;
      end if;

      if Config.Clean_PCloud_Temporary then
         declare
            Deleted : Natural := 0;
            Cleanup_Status : constant Backup.Remote.Remote_Status :=
              Backup.Remote.Cleanup_Remote_Temporary_Objects
                (To_String (Config.Remote_URL), Config.Remote_Options,
                 Deleted, Diagnostic);
         begin
            if Cleanup_Status /= Backup.Remote.Remote_Ok then
               Emit_Error (To_String (Diagnostic), Config.Json_Errors);
               return Failure;
            end if;
            Ada.Text_IO.Put_Line
              ("pCloud temporary cleanup deleted" & Natural'Image (Deleted) &
               " object(s)");
            return Success;
         end;
      end if;

      Status := Backup.Workflow.Execute (Config, Diagnostic);
      if Status /= Backup.Workflow.Execution_Ok then
         if Config.Json_Errors then
            Emit_Error (To_String (Diagnostic), True);
         elsif (Config.Verify or else Config.Extract)
           and then Config.List_JSON
           and then Length (Diagnostic) > 0
         then
            Ada.Text_IO.Put (To_String (Diagnostic));
         else
            Emit_Error (To_String (Diagnostic), False);
         end if;
         return Failure;
      end if;

      if (Config.Dry_Run or else Config.List_JSON or else Config.Verify or else Config.Extract)
        and then Length (Diagnostic) > 0
      then
         Ada.Text_IO.Put (To_String (Diagnostic));
      end if;

      return Success;
   end Run;

end Backup.CLI;
