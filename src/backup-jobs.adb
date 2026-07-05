with Ada.Containers;
with Ada.Containers.Vectors;
with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Environment_Variables;
with Interfaces;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Backup.Catalog;
with Backup.Jobs_Syntax;
with Backup.Jobs_Retention_Syntax;
with Backup.Workflow;
with Backup.Paths;

package body Backup.Jobs is
   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;
   use type Ada.Containers.Count_Type;
   use type Backup.Workflow.Execution_Status;
   use type Backup.Encryption.Password_Source_Kind;
   use type Backup.Remote.Remote_Status;
   use type Backup.Catalog.Catalog_Status;
   use type Backup.Paths.Validation_Status;
   use type Ada.Directories.File_Kind;
   use type Interfaces.Unsigned_64;

   package Natural_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Natural);


   function Environment_Job_Value
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
   end Environment_Job_Value;

   function Trim (Text : String) return String is
   begin
      return Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   end Trim;

   function Starts_With
     (Value  : String;
      Prefix : String)
      return Boolean
   is
   begin
      return Backup.Jobs_Syntax.Starts_With (Value, Prefix);
   end Starts_With;


   function Normalize_Path (Path : String) return String is
   begin
      return Backup.Paths.To_String
        (Backup.Paths.Normalize_File_System_Path (Path));
   end Normalize_Path;

   function Contains_Normalized
     (Paths : Backup.CLI.String_Vectors.Vector;
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

   function Repeated_Key_Allowed (Key : String) return Boolean is
   begin
      return Backup.Jobs_Syntax.Repeated_Key_Allowed (Key);
   end Repeated_Key_Allowed;

   function Seen_Key
     (Keys : Backup.CLI.String_Vectors.Vector;
      Key  : String)
      return Boolean
   is
   begin
      for Existing of Keys loop
         if Existing = Key then
            return True;
         end if;
      end loop;
      return False;
   end Seen_Key;

   function Status_Text (Status : Job_Status) return String is
   begin
      return Backup.Jobs_Syntax.Status_Text (Status);
   end Status_Text;

   function Parse_Boolean
     (Value      : String;
      Result     : out Boolean;
      Diagnostic : out Unbounded_String;
      Key        : String)
      return Boolean
   is
   begin
      if Backup.Jobs_Syntax.Is_Boolean_Text (Value) then
         Result := Value = "true";
         return True;
      else
         Diagnostic := To_Unbounded_String
           (Key & " expects true or false, got '" & Value & "'");
         return False;
      end if;
   end Parse_Boolean;

   function Parse_Natural
     (Value      : String;
      Result     : out Natural;
      Diagnostic : out Unbounded_String;
      Key        : String)
      return Boolean
   is
      Accumulated : Natural := 0;
   begin
      if Value'Length = 0 then
         Diagnostic := To_Unbounded_String (Key & " expects a number");
         return False;
      end if;

      for Ch of Value loop
         if Ch not in '0' .. '9' then
            Diagnostic := To_Unbounded_String
              (Key & " expects a decimal number, got '" & Value & "'");
            return False;
         end if;

         if Accumulated > (Natural'Last -
           (Character'Pos (Ch) - Character'Pos ('0'))) / 10
         then
            Diagnostic := To_Unbounded_String
              (Key & " value is too large: '" & Value & "'");
            return False;
         end if;

         Accumulated := Accumulated * 10 +
           (Character'Pos (Ch) - Character'Pos ('0'));
      end loop;

      Result := Accumulated;
      return True;
   end Parse_Natural;

   function Parse_Compression
     (Value      : String;
      Result     : out Backup.CLI.Compression_Mode;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Value = "auto" then
         Result := Backup.CLI.Compression_Auto;
      elsif Value = "store" then
         Result := Backup.CLI.Compression_Store;
      elsif Value = "deflate" then
         Result := Backup.CLI.Compression_Deflate;
      elsif Value = "bzip2" then
         Result := Backup.CLI.Compression_BZip2;
      elsif Value = "lzma" then
         Result := Backup.CLI.Compression_LZMA;
      elsif Value = "ppmd" then
         Result := Backup.CLI.Compression_PPMd;
      elsif Value = "zstd" then
         Result := Backup.CLI.Compression_Zstd;
      else
         Diagnostic := To_Unbounded_String
           ("compression expects auto, store, deflate, bzip2, lzma, ppmd, " &
            "or zstd, got '" & Value & "'");
         return False;
      end if;

      return True;
   end Parse_Compression;

   function Parse_Symlinks
     (Value      : String;
      Result     : out Backup.CLI.Symlink_Mode;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
   begin
      if Value = "skip" then
         Result := Backup.CLI.Symlinks_Skip;
      elsif Value = "store-link" then
         Result := Backup.CLI.Symlinks_Store_Link;
      elsif Value = "follow" then
         Result := Backup.CLI.Symlinks_Follow;
      else
         Diagnostic := To_Unbounded_String
           ("symlinks expects skip, store-link, or follow, got '" &
            Value & "'");
         return False;
      end if;

      return True;
   end Parse_Symlinks;


   function Valid_Schedule_Metadata
     (Value      : String;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Hour   : Natural;
      Minute : Natural;
      Sep    : Natural;
   begin
      if Backup.Jobs_Syntax.Valid_Schedule_Metadata (Value) then
         return True;
      end if;

      if Value'Length = 0
        or else Value = "external"
        or else Value = "manual"
        or else Value = "disabled"
      then
         return True;
      end if;

      if Starts_With (Value, "interval-hours:") then
         if not Parse_Natural
           (Value (Value'First + 15 .. Value'Last), Hour, Diagnostic,
            "schedule interval-hours")
         then
            return False;
         end if;

         if Hour = 0 then
            Diagnostic := To_Unbounded_String
              ("schedule interval-hours must be greater than zero");
            return False;
         end if;

         return True;
      elsif Starts_With (Value, "daily-at:") then
         declare
            Time_Text : constant String :=
              Value (Value'First + 9 .. Value'Last);
         begin
            Sep := Ada.Strings.Fixed.Index (Time_Text, ":");
            if Sep = 0 then
               Diagnostic := To_Unbounded_String
                 ("schedule daily-at expects HH:MM");
               return False;
            end if;

            if not Parse_Natural
              (Time_Text (Time_Text'First .. Sep - 1), Hour, Diagnostic,
               "schedule daily-at hour")
            then
               return False;
            end if;

            if not Parse_Natural
              (Time_Text (Sep + 1 .. Time_Text'Last), Minute, Diagnostic,
               "schedule daily-at minute")
            then
               return False;
            end if;

            if Hour > 23 or else Minute > 59 then
               Diagnostic := To_Unbounded_String
                 ("schedule daily-at time is outside 00:00..23:59");
               return False;
            end if;

            return True;
         end;
      end if;

      Diagnostic := To_Unbounded_String
        ("unsupported schedule metadata '" & Value &
         "'; expected external, manual, disabled, interval-hours:N, or daily-at:HH:MM");
      return False;
   end Valid_Schedule_Metadata;

   function Parse_Tiered_Item
     (Item       : String;
      Policy     : in out Retention_Policy;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Sep : constant Natural := Ada.Strings.Fixed.Index (Item, "=");
      Number : Natural;
   begin
      if Sep = 0 then
         Diagnostic := To_Unbounded_String
           ("tiered retention item requires name=value: '" & Item & "'");
         return False;
      end if;

      if not Parse_Natural
        (Trim (Item (Sep + 1 .. Item'Last)), Number, Diagnostic,
         "tiered retention")
      then
         return False;
      end if;

      declare
         Name : constant String := Trim (Item (Item'First .. Sep - 1));
      begin
         if Name = "daily" then
            Policy.Daily := Number;
         elsif Name = "weekly" then
            Policy.Weekly := Number;
         elsif Name = "monthly" then
            Policy.Monthly := Number;
         else
            Diagnostic := To_Unbounded_String
              ("unknown tiered retention bucket '" & Name & "'");
            return False;
         end if;
      end;

      return True;
   end Parse_Tiered_Item;

   function Parse_Retention_Policy
     (Text       : String;
      Policy     : out Retention_Policy;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Value : constant String := Trim (Text);
      Number : Natural;
      Start : Positive;
      Stop  : Natural;
   begin
      Policy := (Kind => Retention_None,
                 Keep_Count => 0,
                 Max_Age_Days => 0,
                 Daily => 0,
                 Weekly => 0,
                 Monthly => 0);

      if Value = "none" or else Value = "" then
         return True;
      elsif Starts_With (Value, "count:") then
         if not Parse_Natural
           (Value (Value'First + 6 .. Value'Last), Number, Diagnostic,
            "count retention")
         then
            return False;
         end if;
         Policy.Kind := Retention_Count;
         Policy.Keep_Count := Number;
         return True;
      elsif Starts_With (Value, "age-days:") then
         if not Parse_Natural
           (Value (Value'First + 9 .. Value'Last), Number, Diagnostic,
            "age-days retention")
         then
            return False;
         end if;
         Policy.Kind := Retention_Age_Days;
         Policy.Max_Age_Days := Number;
         return True;
      elsif Starts_With (Value, "tiered:") then
         Policy.Kind := Retention_Tiered;
         Start := Value'First + 7;
         while Start <= Value'Last loop
            Stop := Ada.Strings.Fixed.Index
              (Value (Start .. Value'Last), ",");
            if Stop = 0 then
               Stop := Value'Last;
            else
               Stop := Stop - 1;
            end if;

            if not Parse_Tiered_Item
              (Trim (Value (Start .. Stop)), Policy, Diagnostic)
            then
               return False;
            end if;

            Start := Stop + 2;
         end loop;

         if not Backup.Jobs_Retention_Syntax.Has_Keep_Target (Policy) then
            Diagnostic := To_Unbounded_String
              ("tiered retention must keep at least one backup");
            return False;
         end if;

         return True;
      else
         Diagnostic := To_Unbounded_String
           ("unsupported retention policy '" & Value & "'");
         return False;
      end if;
   end Parse_Retention_Policy;

   function Empty_Job return Job_Configuration is
   begin
      return
        (Name        => Null_Unbounded_String,
         Output_Path => Null_Unbounded_String,
         Output_Naming => Archive_Name_Exact,
         Inputs      => Backup.CLI.String_Vectors.Empty_Vector,
         Ignore_Files => Backup.CLI.String_Vectors.Empty_Vector,
         Prefix      => Null_Unbounded_String,
         Compression => Backup.CLI.Compression_Auto,
         Symlinks    => Backup.CLI.Symlinks_Skip,
         Deterministic => False,
         Manifest      => False,
         List_JSON     => False,
         Dry_Run       => False,
         Max_File_Size  => (Is_Set => False, Value => 0),
         Max_Total_Size => (Is_Set => False, Value => 0),
         Incremental_From_Archive => Null_Unbounded_String,
         Incremental_From_Manifest => Null_Unbounded_String,
         Encrypt  => False,
         Password => (Kind => Backup.Encryption.Password_None,
                      Value => Null_Unbounded_String),
         Cipher   => Backup.Encryption.Cipher_AES256_GCM,
         Verify_After => False,
         Retention_After => False,
         Schedule => Null_Unbounded_String,
         Retention => (Kind => Retention_None,
                       Keep_Count => 0,
                       Max_Age_Days => 0,
                       Daily => 0,
                       Weekly => 0,
                       Monthly => 0),
         Remote_URL => Null_Unbounded_String,
         Upload_Remote => False,
         Sync_Remote => False,
         Remote_Options => (Require_Encrypted => False,
                            Upload_Behavior => Backup.Remote.Upload_Atomic,
                            Retry_Count => 0,
                            Timeout_Seconds => 60, others => <>),
         Catalog_File => Null_Unbounded_String);
   end Empty_Job;

   function Apply_Field
     (Job        : in out Job_Configuration;
      Key        : String;
      Value      : String;
      Line       : Positive;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Flag : Boolean;
      Count : Backup.Jobs_Syntax.Natural_Parse;
      Size_Value : Backup.CLI.Size_Limit;

      function Parse_Size_Limit
        (Limit_Value : String;
         Limit       : out Backup.CLI.Size_Limit;
         Limit_Key   : String)
         return Boolean
      is
         Accumulated : Interfaces.Unsigned_64 := 0;
      begin
         Limit := (Is_Set => False, Value => 0);
         if Limit_Value'Length = 0 then
            Limit := (Is_Set => False, Value => 0);
            return True;
         end if;

         for Ch of Limit_Value loop
            if Ch not in '0' .. '9' then
               Diagnostic := To_Unbounded_String
                 (Limit_Key & " expects a decimal byte count, got '" &
                  Limit_Value & "'");
               return False;
            end if;

            declare
               Digit : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64
                   (Character'Pos (Ch) - Character'Pos ('0'));
            begin
               if Accumulated > (Interfaces.Unsigned_64'Last - Digit) / Interfaces.Unsigned_64'(10) then
                  Diagnostic := To_Unbounded_String
                    (Limit_Key & " byte count is too large: '" &
                     Limit_Value & "'");
                  return False;
               end if;
               Accumulated := Accumulated * Interfaces.Unsigned_64'(10) + Digit;
            end;
         end loop;

         Limit := (Is_Set => True, Value => Accumulated);
         return True;
      end Parse_Size_Limit;
   begin
      if Key = "format" then
         if Value /= "backup-job-v1" then
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) &
               ": format must be backup-job-v1");
            return False;
         end if;
      elsif Key = "name" then
         Job.Name := To_Unbounded_String (Value);
      elsif Key = "output" then
         Job.Output_Path := To_Unbounded_String (Value);
      elsif Key = "output_naming" or else Key = "archive_naming" then
         if Value = "exact" then
            Job.Output_Naming := Archive_Name_Exact;
         elsif Value = "sequence" then
            Job.Output_Naming := Archive_Name_Sequence;
         else
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) &
               ": output_naming expects exact or sequence, got '" &
               Value & "'");
            return False;
         end if;
      elsif Key = "source" or else Key = "input" then
         if Value'Length = 0 then
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) & ": source must not be empty");
            return False;
         end if;
         Job.Inputs.Append (Value);
      elsif Key = "ignore" then
         Job.Ignore_Files.Append (Value);
      elsif Key = "prefix" then
         if Backup.Paths.Validate_Prefix (Value) /= Backup.Paths.Valid then
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) & ": invalid prefix '" &
               Value & "'");
            return False;
         end if;
         Job.Prefix := To_Unbounded_String (Value);
      elsif Key = "compression" then
         if not Parse_Compression (Value, Job.Compression, Diagnostic) then
            return False;
         end if;
      elsif Key = "symlinks" then
         if not Parse_Symlinks (Value, Job.Symlinks, Diagnostic) then
            return False;
         end if;
      elsif Key = "deterministic" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Deterministic := Flag;
      elsif Key = "manifest" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Manifest := Flag;
      elsif Key = "list_json" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.List_JSON := Flag;
      elsif Key = "dry_run" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Dry_Run := Flag;
      elsif Key = "max_file_size" then
         if not Parse_Size_Limit (Value, Size_Value, Key) then
            return False;
         end if;
         Job.Max_File_Size := Size_Value;
      elsif Key = "max_total_size" then
         if not Parse_Size_Limit (Value, Size_Value, Key) then
            return False;
         end if;
         Job.Max_Total_Size := Size_Value;
      elsif Key = "incremental_from" then
         Job.Incremental_From_Archive := To_Unbounded_String (Value);
      elsif Key = "incremental_from_manifest" then
         Job.Incremental_From_Manifest := To_Unbounded_String (Value);
      elsif Key = "encrypt" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Encrypt := Flag;
      elsif Key = "password_file" then
         if Job.Password.Kind /= Backup.Encryption.Password_None then
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) &
               ": choose only one password source");
            return False;
         end if;
         Job.Password := (Kind => Backup.Encryption.Password_File,
                          Value => To_Unbounded_String (Value));
      elsif Key = "password_env" then
         if Job.Password.Kind /= Backup.Encryption.Password_None then
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) &
               ": choose only one password source");
            return False;
         end if;
         Job.Password := (Kind => Backup.Encryption.Password_Env,
                          Value => To_Unbounded_String (Value));
      elsif Key = "password_prompt" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         if Flag then
            if Job.Password.Kind /= Backup.Encryption.Password_None then
               Diagnostic := To_Unbounded_String
                 ("line" & Positive'Image (Line) &
                  ": choose only one password source");
               return False;
            end if;
            Job.Password := (Kind => Backup.Encryption.Password_Prompt,
                             Value => Null_Unbounded_String);
         end if;
      elsif Key = "cipher" then
         if not Backup.Encryption.Parse_Cipher
           (Value, Job.Cipher, Diagnostic)
         then
            return False;
         end if;
      elsif Key = "verify_after" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Verify_After := Flag;
      elsif Key = "retention_after" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Retention_After := Flag;
      elsif Key = "retention" then
         if not Parse_Retention_Policy (Value, Job.Retention, Diagnostic) then
            return False;
         end if;
      elsif Key = "catalog" then
         Job.Catalog_File := To_Unbounded_String (Value);
      elsif Key = "remote" then
         Job.Remote_URL := To_Unbounded_String (Value);
      elsif Key = "upload_after" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Upload_Remote := Flag;
      elsif Key = "sync_after" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Sync_Remote := Flag;
      elsif Key = "remote_require_encrypted" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.Require_Encrypted := Flag;
      elsif Key = "remote_resume" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         if Flag then
            Job.Remote_Options.Upload_Behavior := Backup.Remote.Upload_Resume_If_Supported;
         else
            Job.Remote_Options.Upload_Behavior := Backup.Remote.Upload_Atomic;
         end if;
      elsif Key = "remote_http_bearer_token" then
         Job.Remote_Options.HTTP_Auth := Backup.Remote.HTTP_Auth_Bearer;
         Job.Remote_Options.HTTP_Bearer_Token := To_Unbounded_String (Value);
      elsif Key = "remote_http_basic_user" then
         Job.Remote_Options.HTTP_Auth := Backup.Remote.HTTP_Auth_Basic;
         Job.Remote_Options.HTTP_Basic_User := To_Unbounded_String (Value);
      elsif Key = "remote_http_basic_password" then
         Job.Remote_Options.HTTP_Auth := Backup.Remote.HTTP_Auth_Basic;
         Job.Remote_Options.HTTP_Basic_Pass := To_Unbounded_String (Value);
      elsif Key = "remote_http_header_name" then
         Job.Remote_Options.HTTP_Auth := Backup.Remote.HTTP_Auth_Custom_Header;
         Job.Remote_Options.HTTP_Header_Name := To_Unbounded_String (Value);
      elsif Key = "remote_http_header_value" then
         Job.Remote_Options.HTTP_Auth := Backup.Remote.HTTP_Auth_Custom_Header;
         Job.Remote_Options.HTTP_Header_Value := To_Unbounded_String (Value);
      elsif Key = "remote_tls_ca_file" then
         Job.Remote_Options.TLS_CA_File := To_Unbounded_String (Value);
      elsif Key = "remote_tls_ca_directory" then
         Job.Remote_Options.TLS_CA_Directory := To_Unbounded_String (Value);
      elsif Key = "remote_tls_client_cert" then
         Job.Remote_Options.TLS_Client_Cert_File := To_Unbounded_String (Value);
      elsif Key = "remote_tls_client_key" then
         Job.Remote_Options.TLS_Client_Key_File := To_Unbounded_String (Value);
      elsif Key = "remote_tls_client_key_passphrase" then
         Job.Remote_Options.TLS_Client_Key_Passphrase := To_Unbounded_String (Value);
         Job.Remote_Options.TLS_Client_Has_Passphrase := True;
      elsif Key = "remote_s3_endpoint" then
         Job.Remote_Options.S3_Endpoint := To_Unbounded_String (Value);
      elsif Key = "remote_s3_region" then
         Job.Remote_Options.S3_Region := To_Unbounded_String (Value);
      elsif Key = "remote_s3_profile" then
         Job.Remote_Options.S3_Profile := To_Unbounded_String (Value);
      elsif Key = "remote_s3_credentials_file" then
         Job.Remote_Options.S3_Credentials_File := To_Unbounded_String (Value);
      elsif Key = "remote_s3_config_file" then
         Job.Remote_Options.S3_Config_File := To_Unbounded_String (Value);
      elsif Key = "remote_s3_web_identity_token_file" then
         Job.Remote_Options.S3_Web_Identity_Token_File := To_Unbounded_String (Value);
      elsif Key = "remote_s3_role_arn" then
         Job.Remote_Options.S3_Role_Arn := To_Unbounded_String (Value);
      elsif Key = "remote_s3_credential_process" then
         Job.Remote_Options.S3_Credential_Process := To_Unbounded_String (Value);
      elsif Key = "remote_s3_sso_session" then
         Job.Remote_Options.S3_SSO_Session := To_Unbounded_String (Value);
      elsif Key = "remote_s3_sso_start_url" then
         Job.Remote_Options.S3_SSO_Start_URL := To_Unbounded_String (Value);
      elsif Key = "remote_s3_sso_region" then
         Job.Remote_Options.S3_SSO_Region := To_Unbounded_String (Value);
      elsif Key = "remote_s3_sso_account_id" then
         Job.Remote_Options.S3_SSO_Account_Id := To_Unbounded_String (Value);
      elsif Key = "remote_s3_sso_role_name" then
         Job.Remote_Options.S3_SSO_Role_Name := To_Unbounded_String (Value);
      elsif Key = "remote_s3_addressing" then
         if Value = "path" then
            Job.Remote_Options.S3_Virtual_Hosted_Style := False;
         elsif Value = "virtual" or else Value = "virtual-hosted" then
            Job.Remote_Options.S3_Virtual_Hosted_Style := True;
         else
            Diagnostic := To_Unbounded_String
              ("remote_s3_addressing requires path or virtual");
            return False;
         end if;
      elsif Key = "remote_s3_server_side_encryption" then
         Job.Remote_Options.S3_Server_Side_Encryption := To_Unbounded_String (Value);
      elsif Key = "remote_s3_sse_kms_key_id" then
         Job.Remote_Options.S3_SSE_KMS_Key_Id := To_Unbounded_String (Value);
      elsif Key = "remote_s3_acl" then
         Job.Remote_Options.S3_ACL := To_Unbounded_String (Value);
      elsif Key = "remote_s3_storage_class" then
         Job.Remote_Options.S3_Storage_Class := To_Unbounded_String (Value);
      elsif Key = "remote_s3_tagging" then
         Job.Remote_Options.S3_Tagging := To_Unbounded_String (Value);
      elsif Key = "remote_s3_metadata_name" then
         Job.Remote_Options.S3_Metadata_Name := To_Unbounded_String (Value);
      elsif Key = "remote_s3_metadata_value" then
         Job.Remote_Options.S3_Metadata_Value := To_Unbounded_String (Value);
      elsif Key = "remote_s3_cache_control" then
         Job.Remote_Options.S3_Cache_Control := To_Unbounded_String (Value);
      elsif Key = "remote_s3_content_disposition" then
         Job.Remote_Options.S3_Content_Disposition := To_Unbounded_String (Value);
      elsif Key = "remote_s3_content_encoding" then
         Job.Remote_Options.S3_Content_Encoding := To_Unbounded_String (Value);
      elsif Key = "remote_s3_object_lock_mode" then
         Job.Remote_Options.S3_Object_Lock_Mode := To_Unbounded_String (Value);
      elsif Key = "remote_s3_object_lock_retain_until" then
         Job.Remote_Options.S3_Object_Lock_Retain_Until := To_Unbounded_String (Value);
      elsif Key = "remote_s3_object_lock_legal_hold" then
         Job.Remote_Options.S3_Object_Lock_Legal_Hold := To_Unbounded_String (Value);
      elsif Key = "remote_s3_multipart_threshold" then
         Count := Backup.Jobs_Syntax.Parse_Natural_Text (Value);
         if Count.Valid then
            Job.Remote_Options.S3_Multipart_Threshold := Count.Value;
         else
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) &
               ": remote_s3_multipart_threshold must be a natural number");
            return False;
         end if;
      elsif Key = "remote_s3_multipart_part_size" then
         Count := Backup.Jobs_Syntax.Parse_Natural_Text (Value);
         if Count.Valid then
            Job.Remote_Options.S3_Multipart_Part_Size := Count.Value;
         else
            Diagnostic := To_Unbounded_String
              ("line" & Positive'Image (Line) &
               ": remote_s3_multipart_part_size must be a natural number");
            return False;
         end if;
      elsif Key = "remote_s3_access_key" then
         Job.Remote_Options.S3_Access_Key := To_Unbounded_String (Value);
      elsif Key = "remote_s3_access_key_env" then
         if Value'Length > 0 then
            Job.Remote_Options.S3_Access_Key := Environment_Job_Value
              (Value, "remote_s3_access_key_env", Diagnostic);
            if Length (Job.Remote_Options.S3_Access_Key) = 0 then
               return False;
            end if;
         end if;
      elsif Key = "remote_s3_secret_key" then
         Job.Remote_Options.S3_Secret_Key := To_Unbounded_String (Value);
      elsif Key = "remote_s3_secret_key_env" then
         if Value'Length > 0 then
            Job.Remote_Options.S3_Secret_Key := Environment_Job_Value
              (Value, "remote_s3_secret_key_env", Diagnostic);
            if Length (Job.Remote_Options.S3_Secret_Key) = 0 then
               return False;
            end if;
         end if;
      elsif Key = "remote_s3_session_token" then
         Job.Remote_Options.S3_Session_Token := To_Unbounded_String (Value);
      elsif Key = "remote_s3_session_token_env" then
         if Value'Length > 0 then
            Job.Remote_Options.S3_Session_Token := Environment_Job_Value
              (Value, "remote_s3_session_token_env", Diagnostic);
            if Length (Job.Remote_Options.S3_Session_Token) = 0 then
               return False;
            end if;
         end if;
      elsif Key = "remote_google_drive_api_base" then
         Job.Remote_Options.Google_Drive_API_Base := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_upload_base" then
         Job.Remote_Options.Google_Drive_Upload_Base := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_access_token" then
         Job.Remote_Options.Google_Drive_Access_Token := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_access_token_file" then
         Job.Remote_Options.Google_Drive_Access_Token_File := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_refresh_token" then
         Job.Remote_Options.Google_Drive_Refresh_Token := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_client_id" then
         Job.Remote_Options.Google_Drive_Client_Id := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_client_secret" then
         Job.Remote_Options.Google_Drive_Client_Secret := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_token_uri" then
         Job.Remote_Options.Google_Drive_Token_URI := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_supports_all_drives" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.Google_Drive_Supports_All_Drives := Flag;
      elsif Key = "remote_google_drive_drive_id" then
         Job.Remote_Options.Google_Drive_Drive_Id := To_Unbounded_String (Value);
      elsif Key = "remote_google_drive_access_token_env" then
         if Value'Length > 0 then
            Job.Remote_Options.Google_Drive_Access_Token := Environment_Job_Value
              (Value, "remote_google_drive_access_token_env", Diagnostic);
            if Length (Job.Remote_Options.Google_Drive_Access_Token) = 0 then
               return False;
            end if;
         end if;
      elsif Key = "remote_pcloud_api_base" then
         Job.Remote_Options.PCloud_API_Base := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_region" then
         Job.Remote_Options.PCloud_Region := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_access_token" then
         Job.Remote_Options.PCloud_Access_Token := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_access_token_file" then
         Job.Remote_Options.PCloud_Access_Token_File := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_token_cache_file" then
         Job.Remote_Options.PCloud_Token_Cache_File := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_refresh_token" then
         Job.Remote_Options.PCloud_Refresh_Token := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_client_id" then
         Job.Remote_Options.PCloud_Client_Id := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_client_secret" then
         Job.Remote_Options.PCloud_Client_Secret := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_token_uri" then
         Job.Remote_Options.PCloud_Token_URI := To_Unbounded_String (Value);
      elsif Key = "remote_pcloud_large_upload_threshold" then
         Job.Remote_Options.PCloud_Large_Upload_Threshold := Natural'Value (Value);
      elsif Key = "remote_pcloud_upload_progress" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.PCloud_Upload_Progress := Flag;
      elsif Key = "remote_pcloud_poll_progress" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.PCloud_Poll_Progress := Flag;
      elsif Key = "remote_pcloud_check_quota" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.PCloud_Check_Quota := Flag;
      elsif Key = "remote_pcloud_create_parents" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.PCloud_Create_Parents := Flag;
      elsif Key = "remote_pcloud_clean_recursive" then
         if not Parse_Boolean (Value, Flag, Diagnostic, Key) then
            return False;
         end if;
         Job.Remote_Options.PCloud_Clean_Recursive := Flag;
      elsif Key = "remote_pcloud_access_token_env" then
         if Value'Length > 0 then
            Job.Remote_Options.PCloud_Access_Token := Environment_Job_Value
              (Value, "remote_pcloud_access_token_env", Diagnostic);
            if Length (Job.Remote_Options.PCloud_Access_Token) = 0 then
               return False;
            end if;
         end if;
      elsif Key = "schedule" then
         Job.Schedule := To_Unbounded_String (Value);
      else
         Diagnostic := To_Unbounded_String
           ("line" & Positive'Image (Line) & ": unknown job key '" &
            Key & "'");
         return False;
      end if;

      return True;
   end Apply_Field;

   function Validate_Loaded_Job
     (Job        : Job_Configuration;
      Diagnostic : out Unbounded_String)
      return Job_Status
   is
      Seen : Backup.CLI.String_Vectors.Vector;
      Output_Normalized : Unbounded_String;
   begin
      if Length (Job.Output_Path) = 0 then
         Diagnostic := To_Unbounded_String ("job requires output=PATH");
         return Job_Missing_Required_Field;
      end if;

      if Job.Inputs.Is_Empty then
         Diagnostic := To_Unbounded_String
           ("job requires at least one source=PATH");
         return Job_Missing_Required_Field;
      end if;

      Output_Normalized := To_Unbounded_String
        (Normalize_Path (To_String (Job.Output_Path)));

      if Job.Encrypt and then Job.Deterministic then
         Diagnostic := To_Unbounded_String
           ("encrypt=true cannot be combined with deterministic=true");
         return Job_Malformed;
      end if;

      if Job.Encrypt
        and then Job.Password.Kind = Backup.Encryption.Password_None
      then
         Diagnostic := To_Unbounded_String
           ("encrypted job requires password_file, password_env, or " &
            "password_prompt=true");
         return Job_Missing_Required_Field;
      end if;

      if Job.Password.Kind in Backup.Encryption.Password_File
        | Backup.Encryption.Password_Env
        and then Length (Job.Password.Value) = 0
      then
         Diagnostic := To_Unbounded_String
           ("password source value must not be empty");
         return Job_Malformed;
      end if;

      if Job.Password.Kind = Backup.Encryption.Password_File then
         if not Ada.Directories.Exists (To_String (Job.Password.Value)) then
            Diagnostic := To_Unbounded_String
              ("password file does not exist: " &
               To_String (Job.Password.Value));
            return Job_Malformed;
         end if;

         if Ada.Directories.Kind (To_String (Job.Password.Value))
           /= Ada.Directories.Ordinary_File
         then
            Diagnostic := To_Unbounded_String
              ("password path is not an ordinary file: " &
               To_String (Job.Password.Value));
            return Job_Malformed;
         end if;
      end if;

      if Job.Password.Kind /= Backup.Encryption.Password_None
        and then not Job.Encrypt
        and then Length (Job.Incremental_From_Archive) = 0
      then
         Diagnostic := To_Unbounded_String
           ("password source requires encrypt=true or incremental_from");
         return Job_Malformed;
      end if;

      if Length (Job.Incremental_From_Archive) > 0
        and then Length (Job.Incremental_From_Manifest) > 0
      then
         Diagnostic := To_Unbounded_String
           ("choose only one of incremental_from or " &
            "incremental_from_manifest");
         return Job_Malformed;
      end if;

      for Ignore_File of Job.Ignore_Files loop
         if not Ada.Directories.Exists (Ignore_File) then
            Diagnostic := To_Unbounded_String
              ("ignore file does not exist: " & Ignore_File);
            return Job_Malformed;
         end if;

         if Ada.Directories.Kind (Ignore_File)
           /= Ada.Directories.Ordinary_File
         then
            Diagnostic := To_Unbounded_String
              ("ignore path is not an ordinary file: " & Ignore_File);
            return Job_Malformed;
         end if;
      end loop;

      for Input_Path of Job.Inputs loop
         if Contains_Normalized (Seen, Input_Path) then
            Diagnostic := To_Unbounded_String
              ("duplicate input path after normalization: " & Input_Path);
            return Job_Malformed;
         end if;

         if Normalize_Path (Input_Path) = To_String (Output_Normalized) then
            Diagnostic := To_Unbounded_String
              ("output ZIP path must not also be an input path: " &
               Input_Path);
            return Job_Malformed;
         end if;

         Seen.Append (Input_Path);
      end loop;

      if Length (Job.Incremental_From_Archive) > 0 then
         if not Ada.Directories.Exists
           (To_String (Job.Incremental_From_Archive))
         then
            Diagnostic := To_Unbounded_String
              ("incremental archive does not exist: " &
               To_String (Job.Incremental_From_Archive));
            return Job_Malformed;
         end if;

         if Ada.Directories.Kind (To_String (Job.Incremental_From_Archive))
           /= Ada.Directories.Ordinary_File
         then
            Diagnostic := To_Unbounded_String
              ("incremental archive is not an ordinary file: " &
               To_String (Job.Incremental_From_Archive));
            return Job_Malformed;
         end if;
      end if;

      if Length (Job.Incremental_From_Manifest) > 0 then
         if not Ada.Directories.Exists
           (To_String (Job.Incremental_From_Manifest))
         then
            Diagnostic := To_Unbounded_String
              ("incremental manifest does not exist: " &
               To_String (Job.Incremental_From_Manifest));
            return Job_Malformed;
         end if;

         if Ada.Directories.Kind (To_String (Job.Incremental_From_Manifest))
           /= Ada.Directories.Ordinary_File
         then
            Diagnostic := To_Unbounded_String
              ("incremental manifest is not an ordinary file: " &
               To_String (Job.Incremental_From_Manifest));
            return Job_Malformed;
         end if;
      end if;

      if Length (Job.Incremental_From_Archive) > 0
        and then Normalize_Path (To_String (Job.Incremental_From_Archive)) =
          To_String (Output_Normalized)
      then
         Diagnostic := To_Unbounded_String
           ("output ZIP path must not also be the incremental archive: " &
            To_String (Job.Incremental_From_Archive));
         return Job_Malformed;
      end if;

      if Length (Job.Incremental_From_Manifest) > 0
        and then Normalize_Path (To_String (Job.Incremental_From_Manifest)) =
          To_String (Output_Normalized)
      then
         Diagnostic := To_Unbounded_String
           ("output ZIP path must not also be the incremental manifest: " &
            To_String (Job.Incremental_From_Manifest));
         return Job_Malformed;
      end if;

      if (Job.Upload_Remote or else Job.Sync_Remote)
        and then Length (Job.Remote_URL) = 0
      then
         Diagnostic := To_Unbounded_String
           ("remote job upload or sync requires remote=URL");
         return Job_Missing_Required_Field;
      end if;

      if Length (Job.Remote_URL) > 0 then
         declare
            Location : Backup.Remote.Remote_Location;
            Transport_Status : constant Backup.Remote.Remote_Status :=
              Backup.Remote.Parse_URL
                (To_String (Job.Remote_URL), To_String (Job.Output_Path),
                 Location, Diagnostic);
            pragma Unreferenced (Location);
         begin
            if Transport_Status /= Backup.Remote.Remote_Ok then
               return Job_Malformed;
            end if;
         end;
      end if;

      if Job.Remote_Options.Require_Encrypted
        and then (Job.Upload_Remote or else Job.Sync_Remote)
        and then not Job.Encrypt
      then
         Diagnostic := To_Unbounded_String
           ("remote_require_encrypted=true requires encrypt=true");
         return Job_Malformed;
      end if;

      if Job.Dry_Run and then Length (Job.Catalog_File) > 0 then
         Diagnostic := To_Unbounded_String
           ("catalog=PATH cannot be used with dry_run=true");
         return Job_Malformed;
      end if;

      if not Valid_Schedule_Metadata (To_String (Job.Schedule), Diagnostic) then
         return Job_Malformed;
      end if;

      return Job_Ok;
   end Validate_Loaded_Job;

   function Load
     (Path       : String;
      Job        : out Job_Configuration;
      Diagnostic : out Unbounded_String)
      return Job_Status
   is
      File : Ada.Text_IO.File_Type;
      Line_No : Positive := 1;
      Format_Seen : Boolean := False;
      Scalar_Keys : Backup.CLI.String_Vectors.Vector;
   begin
      Job := Empty_Job;
      Diagnostic := Null_Unbounded_String;

      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      exception
         when others =>
            Diagnostic := To_Unbounded_String
              ("could not open job configuration: " & Path);
            return Job_Open_Failed;
      end;

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Raw : constant String := Ada.Text_IO.Get_Line (File);
            Line : constant String := Trim (Raw);
            Sep  : Natural;
         begin
            if Line'Length > 0 and then Line (Line'First) /= '#' then
               Sep := Ada.Strings.Fixed.Index (Line, "=");
               if Sep = 0 then
                  Ada.Text_IO.Close (File);
                  Diagnostic := To_Unbounded_String
                    ("line" & Positive'Image (Line_No) &
                     ": expected key=value");
                  return Job_Malformed;
               end if;

               declare
                  Key_Value : constant String :=
                    Trim (Line (Line'First .. Sep - 1));
                  Field_Value : constant String :=
                    Trim (Line (Sep + 1 .. Line'Last));
               begin
                  if not Repeated_Key_Allowed (Key_Value)
                    and then Seen_Key (Scalar_Keys, Key_Value)
                  then
                     Ada.Text_IO.Close (File);
                     Diagnostic := To_Unbounded_String
                       ("line" & Positive'Image (Line_No) &
                        ": duplicate job key '" & Key_Value & "'");
                     return Job_Malformed;
                  end if;

                  if not Repeated_Key_Allowed (Key_Value) then
                     Scalar_Keys.Append (Key_Value);
                  end if;

                  if Key_Value = "format" then
                     Format_Seen := True;
                  end if;

                  if not Apply_Field
                    (Job,
                     Key_Value,
                     Field_Value,
                     Line_No,
                     Diagnostic)
                  then
                     Ada.Text_IO.Close (File);
                     return Job_Malformed;
                  end if;
               end;
            end if;
         end;

         if Line_No < Positive'Last then
            Line_No := Line_No + 1;
         end if;
      end loop;

      Ada.Text_IO.Close (File);

      if not Format_Seen then
         Diagnostic := To_Unbounded_String
           ("job requires format=backup-job-v1");
         return Job_Missing_Required_Field;
      end if;

      return Validate_Loaded_Job (Job, Diagnostic);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Diagnostic := To_Unbounded_String
           ("could not read job configuration: " & Path);
         return Job_Read_Failed;
   end Load;

   function Write_Template
     (Path       : String;
      Diagnostic : out Unbounded_String)
      return Job_Status
   is
      File : Ada.Text_IO.File_Type;
   begin
      Diagnostic := Null_Unbounded_String;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
         Ada.Text_IO.Put_Line (File, "format=backup-job-v1");
         Ada.Text_IO.Put_Line (File, "name=default");
         Ada.Text_IO.Put_Line (File, "source=./data");
         Ada.Text_IO.Put_Line (File, "output=./backup.zip");
         Ada.Text_IO.Put_Line (File, "output_naming=sequence");
         Ada.Text_IO.Put_Line (File, "compression=auto");
         Ada.Text_IO.Put_Line (File, "symlinks=skip");
         Ada.Text_IO.Put_Line (File, "deterministic=false");
         Ada.Text_IO.Put_Line (File, "manifest=true");
         Ada.Text_IO.Put_Line (File, "list_json=true");
         Ada.Text_IO.Put_Line (File, "dry_run=false");
         Ada.Text_IO.Put_Line (File, "max_file_size=");
         Ada.Text_IO.Put_Line (File, "max_total_size=");
         Ada.Text_IO.Put_Line (File, "incremental_from=");
         Ada.Text_IO.Put_Line (File, "encrypt=false");
         Ada.Text_IO.Put_Line (File, "verify_after=true");
         Ada.Text_IO.Put_Line (File, "retention_after=false");
         Ada.Text_IO.Put_Line (File, "retention=count:7");
         Ada.Text_IO.Put_Line (File, "remote=");
         Ada.Text_IO.Put_Line (File, "catalog=");
         Ada.Text_IO.Put_Line (File, "upload_after=false");
         Ada.Text_IO.Put_Line (File, "sync_after=false");
         Ada.Text_IO.Put_Line (File, "remote_require_encrypted=false");
         Ada.Text_IO.Put_Line (File, "remote_resume=false");
         Ada.Text_IO.Put_Line (File, "remote_s3_endpoint=");
         Ada.Text_IO.Put_Line (File, "remote_s3_region=");
         Ada.Text_IO.Put_Line (File, "remote_s3_profile=");
         Ada.Text_IO.Put_Line (File, "remote_s3_credentials_file=");
         Ada.Text_IO.Put_Line (File, "remote_s3_config_file=");
         Ada.Text_IO.Put_Line (File, "remote_s3_web_identity_token_file=");
         Ada.Text_IO.Put_Line (File, "remote_s3_role_arn=");
         Ada.Text_IO.Put_Line (File, "remote_s3_credential_process=");
         Ada.Text_IO.Put_Line (File, "remote_s3_sso_session=");
         Ada.Text_IO.Put_Line (File, "remote_s3_sso_start_url=");
         Ada.Text_IO.Put_Line (File, "remote_s3_sso_region=");
         Ada.Text_IO.Put_Line (File, "remote_s3_sso_account_id=");
         Ada.Text_IO.Put_Line (File, "remote_s3_sso_role_name=");
         Ada.Text_IO.Put_Line (File, "remote_s3_addressing=path");
         Ada.Text_IO.Put_Line (File, "remote_s3_server_side_encryption=");
         Ada.Text_IO.Put_Line (File, "remote_s3_sse_kms_key_id=");
         Ada.Text_IO.Put_Line (File, "remote_s3_acl=");
         Ada.Text_IO.Put_Line (File, "remote_s3_storage_class=");
         Ada.Text_IO.Put_Line (File, "remote_s3_tagging=");
         Ada.Text_IO.Put_Line (File, "remote_s3_metadata_name=");
         Ada.Text_IO.Put_Line (File, "remote_s3_metadata_value=");
         Ada.Text_IO.Put_Line (File, "remote_s3_cache_control=");
         Ada.Text_IO.Put_Line (File, "remote_s3_content_disposition=");
         Ada.Text_IO.Put_Line (File, "remote_s3_content_encoding=");
         Ada.Text_IO.Put_Line (File, "remote_s3_object_lock_mode=");
         Ada.Text_IO.Put_Line (File, "remote_s3_object_lock_retain_until=");
         Ada.Text_IO.Put_Line (File, "remote_s3_object_lock_legal_hold=");
         Ada.Text_IO.Put_Line (File, "remote_s3_multipart_threshold=67108864");
         Ada.Text_IO.Put_Line (File, "remote_s3_multipart_part_size=8388608");
         Ada.Text_IO.Put_Line (File, "remote_s3_access_key_env=");
         Ada.Text_IO.Put_Line (File, "remote_s3_secret_key_env=");
         Ada.Text_IO.Put_Line (File, "remote_s3_session_token_env=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_api_base=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_upload_base=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_access_token_file=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_refresh_token=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_client_id=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_client_secret=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_token_uri=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_supports_all_drives=false");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_drive_id=");
         Ada.Text_IO.Put_Line (File, "remote_google_drive_access_token_env=");
         Ada.Text_IO.Put_Line (File, "schedule=external");
         Ada.Text_IO.Close (File);
         return Job_Ok;
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
            Diagnostic := To_Unbounded_String
              ("could not write job template: " & Path);
            return Job_Write_Failed;
      end;
   end Write_Template;

   procedure To_CLI_Config
     (Job    : Job_Configuration;
      Config : out Backup.CLI.Configuration)
   is
   begin
      Config :=
        (Output_Path    => To_Unbounded_String (Planned_Output_Path (Job)),
         Input_Paths    => Job.Inputs,
         Ignore_Files   => Job.Ignore_Files,
         Prefix         => Job.Prefix,
         Dry_Run        => Job.Dry_Run,
         Manifest       => Job.Manifest,
         Deterministic  => Job.Deterministic,
         List_JSON      => Job.List_JSON,
         Verify         => False,
         List_Archive   => False,
         Extract        => False,
         Output_Dir     => Null_Unbounded_String,
         Restore_Only   => Backup.CLI.String_Vectors.Empty_Vector,
         Restore_Exclude => Backup.CLI.String_Vectors.Empty_Vector,
         Restore_Conflict => Backup.CLI.Conflict_Reject,
         Incremental_From_Archive  => Job.Incremental_From_Archive,
         Incremental_From_Manifest => Job.Incremental_From_Manifest,
         Compression    => Job.Compression,
         Compression_Set => True,
         Symlinks       => Job.Symlinks,
         Symlinks_Set    => True,
         Max_File_Size  => Job.Max_File_Size,
         Max_Total_Size => Job.Max_Total_Size,
         Encrypt        => Job.Encrypt,
         Password       => Job.Password,
         Cipher         => Job.Cipher,
         Cipher_Set     => Job.Encrypt,
         Job_File       => Null_Unbounded_String,
         Create_Job_File => Null_Unbounded_String,
         Run_Job        => False,
         Create_Job     => False,
         Retention_Override => Null_Unbounded_String,
         Remote_URL     => Job.Remote_URL,
         Remote_Config  => Null_Unbounded_String,
         Upload_Remote  => Job.Upload_Remote,
         Sync_Remote    => Job.Sync_Remote,
         Restore_Remote => False,
         Clean_PCloud_Temporary => False,
         Check_PCloud_Remote => False,
         Remote_Options => Job.Remote_Options,
         Catalog_File  => Job.Catalog_File,
         Catalog_Index => Null_Unbounded_String,
         Catalog_Query => Null_Unbounded_String,
         Catalog_List_Archives => False,
         Catalog_List_Contents => False,
         Catalog_Verify => False,
         Json_Errors => False);
   end To_CLI_Config;


   function Directory_Of (Path : String) return String is
   begin
      if Ada.Directories.Containing_Directory (Path) = "" then
         return ".";
      else
         return Ada.Directories.Containing_Directory (Path);
      end if;
   exception
      when others =>
         return ".";
   end Directory_Of;

   function Base_Without_Zip (Path : String) return String is
      Name : constant String := Ada.Directories.Simple_Name (Path);
   begin
      if Name'Length >= 4
        and then Name (Name'Last - 3 .. Name'Last) = ".zip"
      then
         return Name (Name'First .. Name'Last - 4);
      else
         return Name;
      end if;
   end Base_Without_Zip;

   function Zero_Prefix (Count : Natural) return String is
      Result : String (1 .. Count);
   begin
      for Index in Result'Range loop
         Result (Index) := '0';
      end loop;
      return Result;
   end Zero_Prefix;

   function Sequence_Path
     (Base_Path : String;
      Number    : Positive)
      return String
   is
      Dir   : constant String := Directory_Of (Base_Path);
      Base  : constant String := Base_Without_Zip (Base_Path);
      Image : constant String := Positive'Image (Number);
      Raw   : constant String := Image (Image'First + 1 .. Image'Last);
      Pad   : Natural := 0;
   begin
      if Raw'Length < 6 then
         Pad := 6 - Raw'Length;
      end if;

      if Dir = "." then
         return Base & "-" & Zero_Prefix (Pad) & Raw & ".zip";
      else
         return Ada.Directories.Compose
           (Dir, Base & "-" & Zero_Prefix (Pad) & Raw & ".zip");
      end if;
   end Sequence_Path;

   function Is_Managed_Backup_Name
     (Candidate_Name : String;
      Output_Path    : String;
      Naming         : Archive_Naming_Policy)
      return Boolean
   is
      Base : constant String := Base_Without_Zip (Output_Path);
   begin
      if Base'Length = 0 then
         return False;
      end if;

      if Candidate_Name = Base & ".zip" then
         return True;
      end if;

      if Naming = Archive_Name_Exact then
         return False;
      end if;

      if Candidate_Name'Length /= Base'Length + 11 then
         return False;
      end if;

      if Candidate_Name
          (Candidate_Name'First .. Candidate_Name'First + Base'Length - 1)
        /= Base
        or else Candidate_Name (Candidate_Name'First + Base'Length) /= '-'
        or else Candidate_Name
          (Candidate_Name'Last - 3 .. Candidate_Name'Last) /= ".zip"
      then
         return False;
      end if;

      for Index in Candidate_Name'First + Base'Length + 1
        .. Candidate_Name'Last - 4
      loop
         if Candidate_Name (Index) not in '0' .. '9' then
            return False;
         end if;
      end loop;

      return True;
   end Is_Managed_Backup_Name;

   function Planned_Output_Path
     (Job : Job_Configuration)
      return String
   is
      Output_Path : constant String := To_String (Job.Output_Path);
   begin
      if Job.Output_Naming = Archive_Name_Exact then
         return Normalize_Path (Output_Path);
      end if;

      for Number in Positive range 1 .. 999_999 loop
         declare
            Candidate : constant String := Sequence_Path (Output_Path, Number);
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Normalize_Path (Candidate);
            end if;
         end;
      end loop;

      return Normalize_Path (Output_Path);
   end Planned_Output_Path;

   function Newer_Than
     (Left  : Managed_Backup;
      Right : Managed_Backup)
      return Boolean
   is
   begin
      if Left.Created_At > Right.Created_At then
         return True;
      elsif Left.Created_At < Right.Created_At then
         return False;
      else
         return To_String (Left.Path) < To_String (Right.Path);
      end if;
   end Newer_Than;

   procedure Sort_Newest_First
     (Items : in out Managed_Backup_Vectors.Vector)
   is
      Swapped : Boolean;
   begin
      if Items.Length <= 1 then
         return;
      end if;

      loop
         Swapped := False;
         for Index in Items.First_Index
           .. Positive'Pred (Items.Last_Index)
         loop
            if not Newer_Than
              (Items.Element (Index), Items.Element (Index + 1))
            then
               declare
                  Left : constant Managed_Backup := Items.Element (Index);
                  Right : constant Managed_Backup := Items.Element (Index + 1);
               begin
                  Items.Replace_Element (Index, Right);
                  Items.Replace_Element (Index + 1, Left);
                  Swapped := True;
               end;
            end if;
         end loop;
         exit when not Swapped;
      end loop;
   end Sort_Newest_First;

   function Contains_Natural
     (Items : Natural_Vectors.Vector;
      Value : Natural)
      return Boolean
   is
   begin
      for Item of Items loop
         if Item = Value then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Natural;

   function Age_Days
     (Now      : Ada.Calendar.Time;
      Created  : Ada.Calendar.Time)
      return Natural
   is
      Remaining : Duration := Now - Created;
      Days      : Natural := 0;
   begin
      while Remaining >= 86_400.0 loop
         Days := Days + 1;
         Remaining := Remaining - 86_400.0;
      end loop;

      return Days;
   end Age_Days;

   function Month_Bucket (Created : Ada.Calendar.Time) return Natural is
      Year    : Ada.Calendar.Year_Number;
      Month   : Ada.Calendar.Month_Number;
      Day     : Ada.Calendar.Day_Number;
      Seconds : Ada.Calendar.Day_Duration;
   begin
      Ada.Calendar.Split (Created, Year, Month, Day, Seconds);
      return Natural (Year) * 12 + Natural (Month);
   end Month_Bucket;

   function Select_Retention_Deletions
     (Policy     : Retention_Policy;
      Now        : Ada.Calendar.Time;
      Candidates : Managed_Backup_Vectors.Vector;
      To_Delete  : out Managed_Backup_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Job_Status
   is
      Ordered : Managed_Backup_Vectors.Vector := Candidates;
      Age_Seconds : Duration;
   begin
      To_Delete.Clear;
      Diagnostic := Null_Unbounded_String;
      Sort_Newest_First (Ordered);

      for Candidate of Ordered loop
         if not Candidate.Managed then
            Diagnostic := To_Unbounded_String
              ("retention candidate is outside the managed backup set: " &
               To_String (Candidate.Path));
            return Job_Retention_Failed;
         end if;
      end loop;

      case Policy.Kind is
         when Retention_None =>
            null;
         when Retention_Count =>
            if not Ordered.Is_Empty then
               for Index in Ordered.First_Index .. Ordered.Last_Index loop
                  if Backup.Jobs_Retention_Syntax.Count_Policy_Deletes
                    (Natural (Index - Ordered.First_Index), Policy.Keep_Count)
                  then
                     To_Delete.Append (Ordered.Element (Index));
                  end if;
               end loop;
            end if;
         when Retention_Age_Days =>
            for Candidate of Ordered loop
               Age_Seconds := Now - Candidate.Created_At;
               if Age_Seconds > Duration (Policy.Max_Age_Days) * 86_400.0 then
                  To_Delete.Append (Candidate);
               end if;
            end loop;
         when Retention_Tiered =>
            declare
               Daily_Kept  : Natural := 0;
               Weekly_Kept : Natural := 0;
               Monthly_Kept : Natural := 0;
               Week_Buckets : Natural_Vectors.Vector;
               Month_Buckets : Natural_Vectors.Vector;
               Keep : Boolean;
               Days : Natural;
               Week : Natural;
               Month : Natural;
            begin
               for Candidate of Ordered loop
                  Keep := False;
                  Days := Age_Days (Now, Candidate.Created_At);
                  Week := Days / 7;
                  Month := Month_Bucket (Candidate.Created_At);

                  if Backup.Jobs_Retention_Syntax.Can_Keep_Daily
                    (Daily_Kept, Policy.Daily)
                  then
                     Daily_Kept := Daily_Kept + 1;
                     Keep := True;
                  elsif Backup.Jobs_Retention_Syntax.Can_Keep_Weekly
                    (Weekly_Kept, Policy.Weekly,
                     Contains_Natural (Week_Buckets, Week))
                  then
                     Week_Buckets.Append (Week);
                     Weekly_Kept := Weekly_Kept + 1;
                     Keep := True;
                  elsif Backup.Jobs_Retention_Syntax.Can_Keep_Monthly
                    (Monthly_Kept, Policy.Monthly,
                     Contains_Natural (Month_Buckets, Month))
                  then
                     Month_Buckets.Append (Month);
                     Monthly_Kept := Monthly_Kept + 1;
                     Keep := True;
                  end if;

                  if not Keep then
                     To_Delete.Append (Candidate);
                  end if;
               end loop;
            end;
      end case;

      return Job_Ok;
   end Select_Retention_Deletions;




   procedure Sort_Managed_By_Path
     (Items : in out Managed_Backup_Vectors.Vector)
   is
      Swapped : Boolean;
   begin
      if Items.Length <= 1 then
         return;
      end if;

      loop
         Swapped := False;
         for Index in Items.First_Index
           .. Positive'Pred (Items.Last_Index)
         loop
            if To_String (Items.Element (Index).Path)
              > To_String (Items.Element (Index + 1).Path)
            then
               declare
                  Left  : constant Managed_Backup := Items.Element (Index);
                  Right : constant Managed_Backup := Items.Element (Index + 1);
               begin
                  Items.Replace_Element (Index, Right);
                  Items.Replace_Element (Index + 1, Left);
               end;
               Swapped := True;
            end if;
         end loop;
         exit when not Swapped;
      end loop;
   end Sort_Managed_By_Path;

   procedure Assign_Lexical_Creation_Order
     (Items : in out Managed_Backup_Vectors.Vector)
   is
      Base : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (2000, 1, 1);
      Offset : Natural := 0;
   begin
      Sort_Managed_By_Path (Items);
      if Items.Is_Empty then
         return;
      end if;

      for Index in Items.First_Index .. Items.Last_Index loop
         declare
            Item : Managed_Backup := Items.Element (Index);
         begin
            Item.Created_At := Base + Duration (Offset);
            Items.Replace_Element (Index, Item);
            Offset := Offset + 1;
         end;
      end loop;
   end Assign_Lexical_Creation_Order;

   procedure Load_Managed_Backups
     (Output_Path : String;
      Naming      : Archive_Naming_Policy;
      Candidates  : out Managed_Backup_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      Dir_Entry  : Ada.Directories.Directory_Entry_Type;
      Dir    : constant String := Directory_Of (Output_Path);
      Full   : Unbounded_String;
      Search_Started : Boolean := False;
   begin
      Candidates.Clear;
      if not Ada.Directories.Exists (Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search, Dir, "*", [Ada.Directories.Ordinary_File => True,
                             others => False]);
      Search_Started := True;
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
         begin
            if Is_Managed_Backup_Name (Name, Output_Path, Naming) then
               Full := To_Unbounded_String
                 (Ada.Directories.Full_Name (Dir_Entry));
               Candidates.Append
                 (Managed_Backup'(Path       => Full,
                   Created_At => Ada.Directories.Modification_Time (Dir_Entry),
                   Managed    => True));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Search_Started := False;
   exception
      when others =>
         if Search_Started then
            Ada.Directories.End_Search (Search);
         end if;
         Candidates.Clear;
   end Load_Managed_Backups;



   function Load_Remote_Managed_Backups
     (Remote_URL  : String;
      Output_Path : String;
      Naming      : Archive_Naming_Policy;
      Candidates  : out Managed_Backup_Vectors.Vector;
      Diagnostic  : out Unbounded_String)
      return Job_Status
   is
      Inventory : Backup.Remote.Archive_Metadata_Vectors.Vector;
      Status    : Backup.Remote.Remote_Status;
   begin
      Candidates.Clear;
      Status := Backup.Remote.Read_Inventory
        (Remote_URL, Output_Path, Inventory, Diagnostic);
      if Status /= Backup.Remote.Remote_Ok then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String
              (Backup.Remote.Status_Text (Status));
         end if;
         return Job_Retention_Failed;
      end if;

      for Item of Inventory loop
         if Item.Managed
           and then not Item.Partial
           and then Is_Managed_Backup_Name
             (To_String (Item.Archive_Id), Output_Path, Naming)
         then
            Candidates.Append
              (Managed_Backup'
                 (Path       => Item.Archive_Id,
                  Created_At =>
                    (if Item.Has_Timestamp then
                        Item.Timestamp
                     else
                        Ada.Calendar.Time_Of (2000, 1, 1)),
                  Managed    => True));
         end if;
      end loop;

      --  Prefer transport-provided timestamps.  If a future transport cannot
      --  expose one, fall back to deterministic lexical ordering for the whole
      --  set so retention remains stable.
      for Item of Inventory loop
         if Item.Managed
           and then not Item.Partial
           and then Is_Managed_Backup_Name
             (To_String (Item.Archive_Id), Output_Path, Naming)
           and then not Item.Has_Timestamp
         then
            Assign_Lexical_Creation_Order (Candidates);
            exit;
         end if;
      end loop;
      return Job_Ok;
   end Load_Remote_Managed_Backups;

   procedure Append_JSON_String
     (Text  : in out Unbounded_String;
      Value : String)
   is
   begin
      Append (Text, '"');
      for Ch of Value loop
         case Ch is
            when '"' =>
               Append (Text, '\');
               Append (Text, '"');
            when '\' =>
               Append (Text, '\');
               Append (Text, '\');
            when Ada.Characters.Latin_1.LF =>
               Append (Text, '\');
               Append (Text, 'n');
            when others =>
               Append (Text, Ch);
         end case;
      end loop;
      Append (Text, '"');
   end Append_JSON_String;

   procedure Append_Phase
     (Text    : in out Unbounded_String;
      First   : in out Boolean;
      Name    : String;
      Status  : String;
      Message : String)
   is
   begin
      if not First then
         Append (Text, "," & Ada.Characters.Latin_1.LF);
      end if;
      First := False;
      Append (Text, "    {");
      Append_JSON_String (Text, "phase");
      Append (Text, ": ");
      Append_JSON_String (Text, Name);
      Append (Text, ", ");
      Append_JSON_String (Text, "status");
      Append (Text, ": ");
      Append_JSON_String (Text, Status);
      Append (Text, ", ");
      Append_JSON_String (Text, "message");
      Append (Text, ": ");
      Append_JSON_String (Text, Message);
      Append (Text, "}");
   end Append_Phase;

   function Execute
     (Job_File   : String;
      Retention_Override : String := "";
      Diagnostic : out Unbounded_String)
      return Job_Status
   is
      Job : Job_Configuration;
      Config : Backup.CLI.Configuration;
      Verify_Config : Backup.CLI.Configuration;
      Load_Status : Job_Status;
      Workflow_Status : Backup.Workflow.Execution_Status;
      Verify_Status : Backup.Workflow.Execution_Status;
      Retention_Status : Job_Status := Job_Ok;
      Candidates : Managed_Backup_Vectors.Vector;
      Deletions  : Managed_Backup_Vectors.Vector;
      Job_Report : Unbounded_String;
      Phase_First : Boolean := True;
      Marker_Path : constant String := Job_File & ".running";
   begin
      Diagnostic := Null_Unbounded_String;
      Load_Status := Load (Job_File, Job, Diagnostic);
      if Load_Status /= Job_Ok then
         return Load_Status;
      end if;

      if Retention_Override'Length > 0 then
         if not Parse_Retention_Policy
           (Retention_Override, Job.Retention, Diagnostic)
         then
            return Job_Malformed;
         end if;
         Job.Retention_After := True;
      end if;

      if Ada.Directories.Exists (Marker_Path) then
         Diagnostic := To_Unbounded_String
           ("previous interrupted execution marker exists: " & Marker_Path);
         return Job_Interrupted;
      end if;

      declare
         Marker : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (Marker, Ada.Text_IO.Out_File, Marker_Path);
         Ada.Text_IO.Put_Line (Marker, "running");
         Ada.Text_IO.Close (Marker);
      exception
         when others =>
            Diagnostic := To_Unbounded_String
              ("could not create execution marker: " & Marker_Path);
            return Job_Write_Failed;
      end;

      To_CLI_Config (Job, Config);
      Workflow_Status := Backup.Workflow.Execute (Config, Diagnostic);
      Append (Job_Report, "{" & Ada.Characters.Latin_1.LF);
      Append (Job_Report, "  ");
      Append_JSON_String (Job_Report, "job");
      Append (Job_Report, ": ");
      Append_JSON_String (Job_Report, To_String (Job.Name));
      Append (Job_Report, "," & Ada.Characters.Latin_1.LF);
      Append (Job_Report, "  ");
      Append_JSON_String (Job_Report, "output");
      Append (Job_Report, ": ");
      Append_JSON_String (Job_Report, To_String (Config.Output_Path));
      Append (Job_Report, "," & Ada.Characters.Latin_1.LF);
      Append (Job_Report, "  ");
      Append_JSON_String (Job_Report, "phases");
      Append (Job_Report, ": [" & Ada.Characters.Latin_1.LF);

      if Workflow_Status /= Backup.Workflow.Execution_Ok then
         Append_Phase
           (Job_Report, Phase_First, "backup", "failed",
            To_String (Diagnostic));
         Append (Job_Report, Ada.Characters.Latin_1.LF & "  ]" &
           Ada.Characters.Latin_1.LF & "}" & Ada.Characters.Latin_1.LF);
         Diagnostic := Job_Report;
         if Ada.Directories.Exists (Marker_Path) then
            Ada.Directories.Delete_File (Marker_Path);
         end if;
         return Job_Backup_Failed;
      end if;
      if Config.Dry_Run then
         Append_Phase
           (Job_Report, Phase_First, "backup", "ok",
            "planned " & To_String (Config.Output_Path));
      else
         Append_Phase
           (Job_Report, Phase_First, "backup", "ok",
            "created " & To_String (Config.Output_Path));
      end if;

      if Job.Verify_After and then Config.Dry_Run then
         Append_Phase
           (Job_Report, Phase_First, "verify", "skipped",
            "dry-run does not verify a newly created archive");
      elsif Job.Verify_After then
         Verify_Config := Config;
         Verify_Config.Verify := True;
         Verify_Config.Encrypt := False;
         Verify_Config.Manifest := False;
         Verify_Config.Dry_Run := False;
         Verify_Config.Input_Paths.Clear;
         Verify_Config.Ignore_Files.Clear;
         Verify_Config.Prefix := Null_Unbounded_String;
         Verify_Config.Compression_Set := False;
         Verify_Config.Symlinks_Set := False;
         Verify_Config.Incremental_From_Archive := Null_Unbounded_String;
         Verify_Config.Incremental_From_Manifest := Null_Unbounded_String;
         Verify_Status := Backup.Workflow.Execute (Verify_Config, Diagnostic);
         if Verify_Status /= Backup.Workflow.Execution_Ok then
            Append_Phase
              (Job_Report, Phase_First, "verify", "failed",
               To_String (Diagnostic));
            Append (Job_Report, Ada.Characters.Latin_1.LF & "  ]" &
              Ada.Characters.Latin_1.LF & "}" & Ada.Characters.Latin_1.LF);
            Diagnostic := Job_Report;
            if Ada.Directories.Exists (Marker_Path) then
               Ada.Directories.Delete_File (Marker_Path);
            end if;
            return Job_Verification_Failed;
         end if;
         Append_Phase (Job_Report, Phase_First, "verify", "ok", "verified");
      end if;

      if Job.Retention_After and then Job.Retention.Kind /= Retention_None then
         if Length (Job.Remote_URL) > 0
           and then (Job.Upload_Remote or else Job.Sync_Remote)
         then
            Retention_Status := Load_Remote_Managed_Backups
              (To_String (Job.Remote_URL), To_String (Job.Output_Path),
               Job.Output_Naming, Candidates, Diagnostic);
         else
            Load_Managed_Backups
              (To_String (Job.Output_Path), Job.Output_Naming, Candidates);
         end if;

         if Retention_Status = Job_Ok then
            Retention_Status := Select_Retention_Deletions
              (Job.Retention, Ada.Calendar.Clock, Candidates, Deletions,
               Diagnostic);
         end if;
         if Retention_Status /= Job_Ok then
            Append_Phase
              (Job_Report, Phase_First, "retention", "failed",
               To_String (Diagnostic));
            Append (Job_Report, Ada.Characters.Latin_1.LF & "  ]" &
              Ada.Characters.Latin_1.LF & "}" & Ada.Characters.Latin_1.LF);
            Diagnostic := Job_Report;
            if Ada.Directories.Exists (Marker_Path) then
               Ada.Directories.Delete_File (Marker_Path);
            end if;
            return Job_Retention_Failed;
         end if;

         if Config.Dry_Run then
            Append_Phase
              (Job_Report, Phase_First, "retention", "planned",
               "would delete" & Natural'Image (Natural (Deletions.Length)));
         else
            for Item of Deletions loop
               begin
                  if Length (Job.Remote_URL) > 0
                    and then (Job.Upload_Remote or else Job.Sync_Remote)
                  then
                     declare
                        Delete_Status : constant Backup.Remote.Remote_Status :=
                          Backup.Remote.Delete_Remote_Object
                            (To_String (Job.Remote_URL),
                             To_String (Job.Output_Path),
                             To_String (Item.Path), Job.Remote_Options,
                             Diagnostic);
                     begin
                        if Delete_Status /= Backup.Remote.Remote_Ok then
                           raise Program_Error;
                        end if;
                     end;
                  else
                     Ada.Directories.Delete_File (To_String (Item.Path));
                  end if;

                  if Length (Job.Catalog_File) > 0 then
                     declare
                        Catalog : Backup.Catalog.Catalog_Data;
                        Catalog_Status : constant Backup.Catalog.Catalog_Status :=
                          Backup.Catalog.Remove_Indexed_Archive
                            (To_String (Job.Catalog_File),
                             To_String (Item.Path),
                             Catalog,
                             Diagnostic);
                        pragma Unreferenced (Catalog);
                     begin
                        if Catalog_Status = Backup.Catalog.Catalog_Archive_Not_Found then
                           null;
                        elsif Catalog_Status /= Backup.Catalog.Catalog_Ok then
                           raise Program_Error;
                        end if;
                     end;
                  end if;
               exception
                  when others =>
                     Append_Phase
                       (Job_Report, Phase_First, "retention", "failed",
                        "could not delete " & To_String (Item.Path));
                     Append (Job_Report, Ada.Characters.Latin_1.LF & "  ]" &
                       Ada.Characters.Latin_1.LF & "}" &
                       Ada.Characters.Latin_1.LF);
                     Diagnostic := Job_Report;
                     if Ada.Directories.Exists (Marker_Path) then
                        Ada.Directories.Delete_File (Marker_Path);
                     end if;
                     return Job_Retention_Failed;
               end;
            end loop;
            Append_Phase
              (Job_Report, Phase_First, "retention", "ok",
               "deleted" & Natural'Image (Natural (Deletions.Length)));
         end if;
      end if;

      Append (Job_Report, Ada.Characters.Latin_1.LF & "  ]" &
        Ada.Characters.Latin_1.LF & "}" & Ada.Characters.Latin_1.LF);
      Diagnostic := Job_Report;
      if Ada.Directories.Exists (Marker_Path) then
         Ada.Directories.Delete_File (Marker_Path);
      end if;
      return Job_Ok;
   end Execute;
end Backup.Jobs;
