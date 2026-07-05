with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;
with Interfaces;

with Project_Tools.Files;

with Backup.CLI;
with Backup.Jobs;
with Backup.Remote;
with Backup.Remote_Syntax;
with Backup.Workflow;
with Proton_Drive;

procedure Backup_Remote_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;
   use type Backup.Remote.Remote_Status;
   use type Backup.Remote.HTTP_Auth_Mode;
   use type Backup.Remote.Sync_Action;
   use type Backup.Remote.Transport_Kind;
   use type Backup.Remote.Upload_Mode;
   use type Backup.Jobs.Job_Status;
   use type Backup.Workflow.Execution_Status;
   use type Proton_Drive.SDK_Status;

   Root     : constant String := Ada.Directories.Compose
     ("/tmp", "backup_remote_tests");
   Src_Dir  : constant String := Root & "/src";
   Rem_Dir  : constant String := Root & "/remote";
   Rem_URL  : constant String := "file://" & Rem_Dir & "/";
   Local    : constant String := Root & "/local.zip";
   Output   : constant String := Root & "/out.zip";
   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Name);
      end if;
   end Check;

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Directory;

   procedure Write_File (Path : String; Text : String) is
   begin
      Project_Tools.Files.Write_Text_File (Path, Text);
   end Write_File;

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
      if A01 /= "" then
         Result.Append (A01);
      end if;
      if A02 /= "" then
         Result.Append (A02);
      end if;
      if A03 /= "" then
         Result.Append (A03);
      end if;
      if A04 /= "" then
         Result.Append (A04);
      end if;
      if A05 /= "" then
         Result.Append (A05);
      end if;
      if A06 /= "" then
         Result.Append (A06);
      end if;
      if A07 /= "" then
         Result.Append (A07);
      end if;
      if A08 /= "" then
         Result.Append (A08);
      end if;
      return Result;
   end Args;

   function Contains (Text : String; Pattern : String) return Boolean is
   begin
      if Pattern'Length = 0 then
         return True;
      end if;

      if Text'Length < Pattern'Length then
         return False;
      end if;

      for Index in Text'First .. Text'Last - Pattern'Length + 1 loop
         if Text (Index .. Index + Pattern'Length - 1) = Pattern then
            return True;
         end if;
      end loop;

      return False;
   end Contains;

   Diagnostic : Unbounded_String;
   Location   : Backup.Remote.Remote_Location;
   Report     : Backup.Remote.Transfer_Report;
   Status     : Backup.Remote.Remote_Status;
   Inventory  : Backup.Remote.Archive_Metadata_Vectors.Vector;
   Plan       : Backup.Remote.Sync_Step_Vectors.Vector;
   Config     : Backup.CLI.Configuration;
   Presigned  : Unbounded_String;
   Workflow_Status : Backup.Workflow.Execution_Status;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;
   Ensure_Directory (Src_Dir);
   Ensure_Directory (Rem_Dir);
   Write_File (Src_Dir & "/file.txt", "content" & ASCII.LF);
   Write_File (Local, "archive" & ASCII.LF);

   Report.PCloud_Progress_Samples := 2;
   Backup.Remote.Build_JSON_Report (Report, Diagnostic);
   Check
     (Contains (To_String (Diagnostic), """pcloud_progress_samples"": 2"),
      "pCloud live progress monitor records provider sample count");

   Check (Backup.Remote_Syntax.Is_HTTP_Transport (Backup.Remote.Transport_HTTP),
          "SPARK remote classifies HTTP transport");
   Check (Backup.Remote_Syntax.Is_HTTP_Transport (Backup.Remote.Transport_HTTPS),
          "SPARK remote classifies HTTPS transport");
   Check (Backup.Remote_Syntax.Is_HTTP_Transport (Backup.Remote.Transport_S3),
          "SPARK remote classifies S3 transport as HTTP object transport");
   Check (not Backup.Remote_Syntax.Is_HTTP_Transport (Backup.Remote.Transport_File),
          "SPARK remote excludes file from HTTP transport");
   Check (not Backup.Remote_Syntax.Is_Unsupported_Transfer_Transport (Backup.Remote.Transport_SSH),
          "SPARK remote treats SSH as implemented transfer transport");
   Check (Backup.Remote_Syntax.Is_Unsupported_Transfer_Transport (Backup.Remote.Transport_Unsupported),
          "SPARK remote classifies unsupported transport");
   Check (Backup.Remote_Syntax.Resume_Upload_Enabled (Backup.Remote.Upload_Resume_If_Supported),
          "SPARK remote detects resume upload mode");
   Check (not Backup.Remote_Syntax.Resume_Upload_Enabled (Backup.Remote.Upload_Atomic),
          "SPARK remote detects atomic upload mode");
   Check (Backup.Remote_Syntax.Timeout_Precheck_Status (0) = Backup.Remote.Remote_Timeout,
          "SPARK remote timeout precheck rejects zero timeout");
   Check (Backup.Remote_Syntax.Timeout_Precheck_Status (1) = Backup.Remote.Remote_Ok,
          "SPARK remote timeout precheck accepts nonzero timeout");

   Check (Proton_Drive.Is_App_Version_Valid
            ("external-drive-backup@0.1.0-alpha"),
          "Proton Drive SDK accepts external app version shape");
   Check (Proton_Drive.Is_App_Version_Valid
            ("external-drive-photo_backup@1.2.3-stable+abc123f"),
          "Proton Drive SDK accepts PR23 app version build metadata shape");
   Check (not Proton_Drive.Is_App_Version_Valid
            ("external-drive-backup@1.2.3-nightly"),
          "Proton Drive SDK rejects unsupported app version channel");
   Check (not Proton_Drive.Is_App_Version_Valid ("proton-drive@1.0.0"),
          "Proton Drive SDK rejects non-external app version shape");
   Write_File
     (Root & "/proton-session.json",
      "{ ""uid"": ""uid-123"", " &
      """access_token"": ""access-token"", " &
      """refresh_token"": ""refresh-token"", " &
      """user_address"": ""user@example.com"", " &
      """address_id"": ""address-123"", " &
      """address_key_id"": ""key-123"", " &
      """address_key_material"": ""address-key-material"", " &
      """metadata_key_id"": ""metadata-key-123"", " &
      """metadata_hmac_key"": ""metadata-hmac-secret"" }" & ASCII.LF);
   declare
      SDK_Diagnostic : Unbounded_String;
      Client : constant Proton_Drive.Client := Proton_Drive.Create
        ((App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
          API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
          Session_File => To_Unbounded_String (Root & "/proton-session.json"),
          User_Address => To_Unbounded_String ("user@example.com"),
          Share_Id     => To_Unbounded_String ("share-123")),
         SDK_Diagnostic);
      Nodes : Proton_Drive.Node_Metadata_Vectors.Vector;
      Packet : Proton_Drive.Metadata_Packet;
      SDK_Status : Proton_Drive.SDK_Status;
   begin
      Check (Proton_Drive.Status (Client) = Proton_Drive.SDK_Operations_Unavailable,
             "Proton Drive Ada SDK client reaches operations-unavailable state after crypto setup");
      Check (To_String (Proton_Drive.Session (Client).UID) = "uid-123",
             "Proton Drive Ada SDK loads session uid provider");
      Check (To_String (Proton_Drive.User_Address (Client).Address_Id) = "address-123",
             "Proton Drive Ada SDK resolves configured user address provider");
      Check (To_String (Proton_Drive.User_Address (Client).Key_Id) = "key-123",
             "Proton Drive Ada SDK loads user address key provider");
      Check (Proton_Drive.Has_Crypto_Context (Client),
             "Proton Drive Ada SDK loads CryptoLib-backed crypto context");
      Packet := Proton_Drive.Build_Metadata_Packet
        (Proton_Drive.Crypto (Client), "local.zip", Proton_Drive.Node_File, 7);
      Check (To_String (Packet.Authentication_Tag)'Length = 64,
             "Proton Drive Ada SDK authenticates metadata with CryptoLib HMAC-SHA256");
      Check (Proton_Drive.Content_Block_Tag
               (Proton_Drive.Crypto (Client), "/backups/local.zip", 1, 0,
                "archive") = "",
             "Proton Drive provider mode leaves content block tags unavailable without content key material");
      SDK_Status := Proton_Drive.Upload_File
        (Client, "/backups", Local, "local.zip", SDK_Diagnostic);
      Check (SDK_Status = Proton_Drive.SDK_Operations_Unavailable,
             "Proton Drive Ada SDK upload fails closed without provider endpoints");
      SDK_Status := Proton_Drive.List_Children
        (Client, "/backups", Nodes, SDK_Diagnostic);
      Check (SDK_Status = Proton_Drive.SDK_Operations_Unavailable,
             "Proton Drive Ada SDK list fails closed without provider endpoints");
      Check (Nodes.Is_Empty,
             "Proton Drive Ada SDK list clears output on unavailable operation");
      declare
         Login_Request : constant Proton_Drive.Auth_Request :=
           (Username       => To_Unbounded_String ("user@example.com"),
            Password_Proof => To_Unbounded_String ("proof"),
            MFA_Code       => Null_Unbounded_String,
            Session_Label  => To_Unbounded_String ("backup"));
      begin
         Check (Proton_Drive.Login_And_Save_Session
                  ((App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
                    API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
                    Session_File => To_Unbounded_String (Root & "/proton-session.json"),
                    User_Address => To_Unbounded_String ("user@example.com"),
                    Share_Id     => To_Unbounded_String ("share-123")),
                   Login_Request, SDK_Diagnostic) = Proton_Drive.SDK_Provider_Missing,
                "Proton Drive descriptor-saving login fails closed without provider endpoints");
      end;
   end;

   Write_File
     (Root & "/proton-provider-session.json",
      "{ ""uid"": ""uid-123"", " &
      """access_token"": ""access-token"", " &
      """refresh_token"": ""refresh-token"", " &
      """user_address"": ""user@example.com"", " &
      """address_id"": ""address-123"", " &
      """address_key_id"": ""key-123"", " &
      """address_key_material"": ""address-key-material"", " &
      """metadata_key_id"": ""metadata-key-123"", " &
      """metadata_hmac_key"": ""metadata-hmac-secret"", " &
      """proton_drive_descriptor_version"": ""1"", " &
      """proton_drive_create_folder_url"": ""http://127.0.0.1:1/proton-fixture/folders"", " &
      """proton_drive_conflict_url"": ""http://127.0.0.1:1/proton-fixture/conflicts"", " &
      """proton_drive_login_url"": ""http://127.0.0.1:1/proton-fixture/auth/login"", " &
      """proton_drive_mfa_url"": ""http://127.0.0.1:1/proton-fixture/auth/mfa"", " &
      """proton_drive_session_bootstrap_url"": ""http://127.0.0.1:1/proton-fixture/auth/session"", " &
      """proton_drive_live_check_url"": ""http://127.0.0.1:1/proton-fixture/live"", " &
      """proton_drive_operation_base_url"": ""http://127.0.0.1:1/proton-fixture"" }" & ASCII.LF);
   declare
      SDK_Diagnostic : Unbounded_String;
      Config : constant Proton_Drive.Client_Config :=
        (App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
         API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
         Session_File => To_Unbounded_String (Root & "/proton-provider-session.json"),
         User_Address => To_Unbounded_String ("user@example.com"),
         Share_Id     => To_Unbounded_String ("share-123"));
      Client : constant Proton_Drive.Client :=
        Proton_Drive.Create (Config, SDK_Diagnostic);
   begin
      Check (Proton_Drive.Has_Operation_Provider (Config),
             "Proton Drive Ada SDK detects provider operation endpoints");
      Check (Proton_Drive.Status (Client) = Proton_Drive.SDK_Ok,
             "Proton Drive Ada SDK client is ready with provider endpoints");
      Check (Proton_Drive.Supports_Encrypted_Operations (Client),
             "Proton Drive Ada SDK exposes encrypted operation support with provider endpoints");
      Check (Proton_Drive.Has_Large_Upload_Provider (Config),
             "Proton Drive Ada SDK detects provider large-upload endpoints");
      Check (Proton_Drive.Has_Folder_Provider (Config),
             "Proton Drive Ada SDK detects provider folder endpoint");
      Check (Proton_Drive.Has_Conflict_Provider (Config),
             "Proton Drive Ada SDK detects provider conflict endpoint");
      Check (Proton_Drive.Has_Trash_Provider (Config),
             "Proton Drive Ada SDK detects provider trash endpoint");
      Check (Proton_Drive.Has_Revision_Provider (Config),
             "Proton Drive Ada SDK detects provider revision endpoint");
      Check (Proton_Drive.Has_Event_Replay_Provider (Config),
             "Proton Drive Ada SDK detects provider event replay endpoints");
      Check (Proton_Drive.Supports_Login_Provider (Config),
             "Proton Drive Ada SDK detects provider login/session endpoints");
      Check (Proton_Drive.Supports_Native_Auth_Flow (Config),
             "Proton Drive Ada SDK detects complete provider auth flow endpoints");
      Check (Proton_Drive.Supports_Streaming_Transfer (Config),
             "Proton Drive Ada SDK detects provider streaming transfer surface");
      Check (Proton_Drive.Wire_Response_Valid
               ("upload_start", "{ ""upload_id"": ""upload-123"" }"),
             "Proton Drive Ada SDK validates upload-start wire response fields");
      Check (Proton_Drive.Supports_Live_Compatibility_Check (Config),
             "Proton Drive Ada SDK detects live compatibility check endpoint");
      declare
         Auth_Diagnostic : Unbounded_String;
         Auth_Session : Proton_Drive.Session_Info;
         Auth_Request : constant Proton_Drive.Auth_Request :=
           (Username       => To_Unbounded_String ("user@example.com"),
            Password_Proof => To_Unbounded_String ("proof"),
            MFA_Code       => To_Unbounded_String ("123456"),
            Session_Label  => To_Unbounded_String ("backup"));
      begin
         Check (Proton_Drive.Start_Login
                  (Config, Auth_Request, Auth_Session, Auth_Diagnostic) =
                Proton_Drive.SDK_HTTP_Failed,
                "Proton Drive Ada SDK exposes login provider operation");
         Check (Proton_Drive.Complete_MFA
                  (Config, Auth_Request, Auth_Session, Auth_Diagnostic) =
                Proton_Drive.SDK_HTTP_Failed,
                "Proton Drive Ada SDK exposes MFA provider operation");
         Check (Proton_Drive.Bootstrap_Session
                  (Config, Auth_Request, Auth_Session, Auth_Diagnostic) =
                Proton_Drive.SDK_HTTP_Failed,
                "Proton Drive Ada SDK exposes session bootstrap provider operation");
         Check (Proton_Drive.Login_And_Save_Session
                  (Config, Auth_Request, Auth_Diagnostic) =
                Proton_Drive.SDK_HTTP_Failed,
                "Proton Drive Ada SDK exposes descriptor-saving login flow");
      end;
   end;

   Write_File
     (Root & "/proton-native-session.json",
      "{ ""uid"": ""uid-123"", " &
      """access_token"": ""access-token"", " &
      """refresh_token"": ""refresh-token"", " &
      """user_address"": ""user@example.com"", " &
      """address_id"": ""address-123"", " &
      """address_key_id"": ""key-123"", " &
      """address_key_material"": ""address-key-material"", " &
      """metadata_key_id"": ""metadata-key-123"", " &
      """metadata_hmac_key"": ""metadata-hmac-secret"", " &
      """node_key_material"": ""node-key-material"", " &
      """content_key_material"": ""content-key-material"", " &
      """content_hmac_key"": ""content-hmac-secret"", " &
      """proton_drive_descriptor_version"": ""1"", " &
      """proton_drive_sdk_generation"": ""ada-compat-v1"", " &
      """proton_drive_wire_contract"": ""proton-drive-sdk-compat-v1"", " &
      """proton_drive_native_api"": ""true"", " &
      """proton_drive_large_upload_threshold"": ""4"", " &
      """proton_drive_large_upload_chunk_size"": ""2"" }" & ASCII.LF);
   declare
      Passphrase : constant String := "descriptor-unlock-passphrase";
      Salt       : constant String := "descriptor-unlock-salt";
      Rounds     : constant Interfaces.Unsigned_32 := 4;
      Address_Key : constant String := Proton_Drive.Key_Unlock_Envelope
        (Passphrase, Salt, Rounds, "address_key_material",
         "address-key-material");
      Metadata_Key : constant String := Proton_Drive.Key_Unlock_Envelope
        (Passphrase, Salt, Rounds, "metadata_hmac_key",
         "metadata-hmac-secret");
      Node_Key : constant String := Proton_Drive.Key_Unlock_Envelope
        (Passphrase, Salt, Rounds, "node_key_material",
         "node-key-material");
      Content_Key : constant String := Proton_Drive.Key_Unlock_Envelope
        (Passphrase, Salt, Rounds, "content_key_material",
         "content-key-material");
      Content_Tag_Key : constant String := Proton_Drive.Key_Unlock_Envelope
        (Passphrase, Salt, Rounds, "content_hmac_key",
         "content-hmac-secret");
      Opened_Key : Unbounded_String;
   begin
      Check (Address_Key'Length > 0
             and then Proton_Drive.Open_Key_Unlock_Envelope
               (Passphrase, Salt, Rounds, "address_key_material",
                Address_Key, Opened_Key)
             and then To_String (Opened_Key) = "address-key-material",
             "Proton Drive key unlock envelopes round-trip descriptor key material");
      Write_File
        (Root & "/proton-unlocked-session.json",
         "{ ""uid"": ""uid-123"", " &
         """access_token"": ""access-token"", " &
         """refresh_token"": ""refresh-token"", " &
         """user_address"": ""user@example.com"", " &
         """address_id"": ""address-123"", " &
         """address_key_id"": ""key-123"", " &
         """encrypted_address_key_material"": """ & Address_Key & """, " &
         """metadata_key_id"": ""metadata-key-123"", " &
         """encrypted_metadata_hmac_key"": """ & Metadata_Key & """, " &
         """encrypted_node_key_material"": """ & Node_Key & """, " &
         """encrypted_content_key_material"": """ & Content_Key & """, " &
         """encrypted_content_hmac_key"": """ & Content_Tag_Key & """, " &
         """proton_drive_key_unlock_passphrase"": """ & Passphrase & """, " &
         """proton_drive_key_unlock_salt"": """ & Salt & """, " &
         """proton_drive_key_unlock_rounds"": ""4"", " &
         """proton_drive_descriptor_version"": ""1"", " &
         """proton_drive_sdk_generation"": ""ada-compat-v1"", " &
         """proton_drive_wire_contract"": ""proton-drive-sdk-compat-v1"", " &
         """proton_drive_native_api"": ""true"" }" & ASCII.LF);
      declare
         Unlock_Diagnostic : Unbounded_String;
         Unlock_Config : constant Proton_Drive.Client_Config :=
           (App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
            API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
            Session_File => To_Unbounded_String (Root & "/proton-unlocked-session.json"),
            User_Address => To_Unbounded_String ("user@example.com"),
            Share_Id     => To_Unbounded_String ("share-123"));
         Unlock_Client : constant Proton_Drive.Client :=
           Proton_Drive.Create (Unlock_Config, Unlock_Diagnostic);
      begin
         Check (Proton_Drive.Status (Unlock_Client) = Proton_Drive.SDK_Ok,
                "Proton Drive native API mode unlocks encrypted descriptor key material");
         Check (Proton_Drive.Supports_Encrypted_Operations (Unlock_Client),
                "Proton Drive unlocked descriptor key material enables encrypted operations");
      end;
      Write_File
        (Root & "/proton-unlocked-session-bad.json",
         "{ ""uid"": ""uid-123"", " &
         """access_token"": ""access-token"", " &
         """user_address"": ""user@example.com"", " &
         """address_id"": ""address-123"", " &
         """address_key_id"": ""key-123"", " &
         """encrypted_address_key_material"": """ & Address_Key & """, " &
         """metadata_key_id"": ""metadata-key-123"", " &
         """encrypted_metadata_hmac_key"": """ & Metadata_Key & """, " &
         """encrypted_node_key_material"": """ & Node_Key & """, " &
         """encrypted_content_key_material"": """ & Content_Key & """, " &
         """encrypted_content_hmac_key"": """ & Content_Tag_Key & """, " &
         """proton_drive_key_unlock_passphrase"": ""wrong-passphrase"", " &
         """proton_drive_key_unlock_salt"": """ & Salt & """, " &
         """proton_drive_key_unlock_rounds"": ""4"", " &
         """proton_drive_descriptor_version"": ""1"", " &
         """proton_drive_sdk_generation"": ""ada-compat-v1"", " &
         """proton_drive_wire_contract"": ""proton-drive-sdk-compat-v1"", " &
         """proton_drive_native_api"": ""true"" }" & ASCII.LF);
      declare
         Bad_Diagnostic : Unbounded_String;
         Bad_Config : constant Proton_Drive.Client_Config :=
           (App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
            API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
            Session_File => To_Unbounded_String (Root & "/proton-unlocked-session-bad.json"),
            User_Address => To_Unbounded_String ("user@example.com"),
            Share_Id     => To_Unbounded_String ("share-123"));
         Bad_Client : constant Proton_Drive.Client :=
           Proton_Drive.Create (Bad_Config, Bad_Diagnostic);
      begin
         Check (Proton_Drive.Status (Bad_Client) = Proton_Drive.SDK_Crypto_Unavailable,
                "Proton Drive encrypted descriptor key material fails closed with wrong passphrase");
      end;
   end;

   declare
      SDK_Diagnostic : Unbounded_String;
      Native_Config : constant Proton_Drive.Client_Config :=
        (App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
         API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
         Session_File => To_Unbounded_String (Root & "/proton-native-session.json"),
         User_Address => To_Unbounded_String ("user@example.com"),
         Share_Id     => To_Unbounded_String ("share-123"));
      Native_Client : constant Proton_Drive.Client :=
        Proton_Drive.Create (Native_Config, SDK_Diagnostic);
   begin
      Check (Proton_Drive.Has_Operation_Provider (Native_Config),
             "Proton Drive Ada SDK derives native operation endpoints when explicitly enabled");
      Check (Proton_Drive.Has_Large_Upload_Provider (Native_Config),
             "Proton Drive Ada SDK derives native large-upload endpoints when explicitly enabled");
      Check (not Proton_Drive.Supports_First_Party_Key_Unlock,
             "Proton Drive Ada SDK does not advertise unsupported first-party key unlock");
      Check (Ada.Strings.Fixed.Index
               (Proton_Drive.First_Party_Key_Unlock_Status,
                "does not include authentication/login") > 0,
             "Proton Drive Ada SDK explains first-party key unlock limitation");
      Check (Proton_Drive.Status (Native_Client) = Proton_Drive.SDK_Ok,
             "Proton Drive native API mode accepts complete key material");
      Check (Proton_Drive.Supports_Encrypted_Operations (Native_Client),
             "Proton Drive native API mode requires content and node key fingerprints");
      Check (Proton_Drive.Content_Block_Tag
               (Proton_Drive.Crypto (Native_Client), "/backups/local.zip",
                1, 0, "archive")'Length = 64,
             "Proton Drive native API mode authenticates content blocks");
      Check (Proton_Drive.Metadata_Envelope
               (Proton_Drive.Crypto (Native_Client),
                Proton_Drive.Build_Metadata_Packet
                  (Proton_Drive.Crypto (Native_Client), "local.zip",
                   Proton_Drive.Node_File, 7))'Length > 2,
             "Proton Drive native API mode builds metadata envelopes");
      declare
         Metadata_Packet : constant Proton_Drive.Metadata_Packet :=
           Proton_Drive.Build_Metadata_Packet
             (Proton_Drive.Crypto (Native_Client), "local.zip",
              Proton_Drive.Node_File, 7);
         Metadata_Envelope : constant String :=
           Proton_Drive.Encrypted_Metadata_Envelope
             (Proton_Drive.Crypto (Native_Client), Metadata_Packet);
         Opened_Metadata : Unbounded_String;
      begin
         Check (Metadata_Envelope'Length > 2
                and then Ada.Strings.Fixed.Index
                  (Metadata_Envelope, "backup-proton-metadata-v2") > 0
                and then Ada.Strings.Fixed.Index
                  (Metadata_Envelope, "cryptolib-chacha20-poly1305") > 0,
                "Proton Drive native API mode builds encrypted metadata envelopes");
         Check (Proton_Drive.Open_Encrypted_Metadata_Envelope
                  (Proton_Drive.Crypto (Native_Client), Metadata_Envelope,
                   Opened_Metadata),
                "Proton Drive native API mode opens encrypted metadata envelopes");
         Check (Ada.Strings.Fixed.Index
                  (To_String (Opened_Metadata), "name=local.zip") > 0,
                "Proton Drive encrypted metadata envelope restores metadata");
         Check (not Proton_Drive.Open_Encrypted_Metadata_Envelope
                  (Proton_Drive.Crypto (Native_Client),
                   Ada.Strings.Fixed.Replace_Slice
                     (Metadata_Envelope,
                      Ada.Strings.Fixed.Index
                        (Metadata_Envelope, "cryptolib-chacha20-poly1305"),
                      Ada.Strings.Fixed.Index
                        (Metadata_Envelope, "cryptolib-chacha20-poly1305") +
                        String'("cryptolib-chacha20-poly1305")'Length - 1,
                      "cryptolib-chacha20-poly1300"),
                   Opened_Metadata),
                "Proton Drive encrypted metadata envelope rejects tampering");
      end;
      Check (Proton_Drive.Auth_Request_Envelope
               ((Username       => To_Unbounded_String ("user@example.com"),
                 Password_Proof => To_Unbounded_String ("proof"),
                 MFA_Code       => To_Unbounded_String ("123456"),
                 Session_Label  => To_Unbounded_String ("backup")))'Length > 2,
             "Proton Drive native API mode builds auth request envelopes");
      Check (Proton_Drive.Wire_Contract (Native_Config) =
               "proton-drive-sdk-compat-v1",
             "Proton Drive native API mode exposes the active wire contract");
      Check (Proton_Drive.Tagged_Content_Block
               (Proton_Drive.Crypto (Native_Client), "/backups/local.zip",
                1, 0, "archive")'Length > String'("PROTON-BLOCK-TAG:")'Length,
             "Proton Drive native API mode builds tagged content envelopes");
      declare
         Stream_Block : constant String := Proton_Drive.Streaming_Content_Block
           (Proton_Drive.Crypto (Native_Client), "/backups/local.zip",
            1, 0, "archive");
         Opened : Unbounded_String;
      begin
         Check (Stream_Block'Length > String'("PROTON-STREAM-BLOCK-V1")'Length
                and then Stream_Block
                  (Stream_Block'First .. Stream_Block'First + String'("PROTON-STREAM-BLOCK-V1")'Length - 1) =
                    "PROTON-STREAM-BLOCK-V1",
                "Proton Drive native API mode builds streaming encrypted content envelopes");
         Check (Proton_Drive.Open_Streaming_Content_Block
                  (Proton_Drive.Crypto (Native_Client), "/backups/local.zip",
                   Stream_Block, Opened),
                "Proton Drive native API mode opens streaming encrypted content envelopes");
         Check (To_String (Opened) = "archive",
                "Proton Drive streaming encrypted content envelope restores payload");
         Check (not Proton_Drive.Open_Streaming_Content_Block
                  (Proton_Drive.Crypto (Native_Client), "/other.zip",
                   Stream_Block, Opened),
                "Proton Drive streaming encrypted content envelope rejects wrong path");
      end;
      Check (Proton_Drive.Requires_Chunked_Upload (Native_Config, 5),
             "Proton Drive native API mode exposes bounded-memory chunk decision");
      Check (Proton_Drive.Plan_Upload (Native_Config, 5).Part_Count = 3,
             "Proton Drive native API mode exposes streaming upload plan");
      Check (Proton_Drive.Supports_Streaming_Transfer (Native_Config),
             "Proton Drive native API mode requires chunk endpoints for streaming transfer");
      Check (Proton_Drive.Has_Folder_Provider (Native_Config),
             "Proton Drive native API mode derives folder endpoint");
      Check (Proton_Drive.Has_Conflict_Provider (Native_Config),
             "Proton Drive native API mode derives conflict endpoint");
      Check (Proton_Drive.Has_Resume_Provider (Native_Config),
             "Proton Drive native API mode derives resume endpoint");
      Check (Proton_Drive.Has_Trash_Provider (Native_Config),
             "Proton Drive native API mode derives trash endpoint");
      Check (Proton_Drive.Has_Revision_Provider (Native_Config),
             "Proton Drive native API mode derives revision endpoint");
      Check (Proton_Drive.Has_Event_Replay_Provider (Native_Config),
             "Proton Drive native API mode derives event replay endpoints");
      Check (Proton_Drive.Supports_Auth_Provider (Native_Config),
             "Proton Drive native API mode exposes auth/session provider capability");
      Check (not Proton_Drive.Supports_Login_Provider (Native_Config),
             "Proton Drive native API mode does not derive unsupported first-party auth endpoints");
      Check (not Proton_Drive.Supports_Native_Auth_Flow (Native_Config),
             "Proton Drive native API mode requires explicit auth provider endpoints");
      declare
         Native_Auth_Diagnostic : Unbounded_String;
         Native_Auth_Session : Proton_Drive.Session_Info;
         Native_Auth_Request : constant Proton_Drive.Auth_Request :=
           (Username       => To_Unbounded_String ("user@example.com"),
            Password_Proof => To_Unbounded_String ("proof"),
            MFA_Code       => Null_Unbounded_String,
            Session_Label  => To_Unbounded_String ("backup"));
      begin
         Check (Proton_Drive.Start_Login
                  (Native_Config, Native_Auth_Request, Native_Auth_Session,
                   Native_Auth_Diagnostic) = Proton_Drive.SDK_Provider_Missing,
                "Proton Drive native API mode fails closed for unsupported first-party auth");
      end;
      Check (Proton_Drive.Has_Wire_Contract (Native_Config),
             "Proton Drive native API mode requires explicit SDK wire contract");
      declare
         Op_Diagnostic : Unbounded_String;
         Revision : Proton_Drive.Revision_Info;
      begin
         declare
            Status : Proton_Drive.SDK_Status;
         begin
            Status := Proton_Drive.Create_Folder
              (Native_Client, "/backups", "folder", Op_Diagnostic);
            Check (Status /= Proton_Drive.SDK_Ok
                   and then Status /= Proton_Drive.SDK_Invalid_Config
                   and then Status /= Proton_Drive.SDK_Operations_Unavailable,
                   "Proton Drive native API mode exposes folder creation operation");
            Status := Proton_Drive.Trash_Node
              (Native_Client, "/backups/local.zip", Op_Diagnostic);
            Check (Status /= Proton_Drive.SDK_Ok
                   and then Status /= Proton_Drive.SDK_Invalid_Config
                   and then Status /= Proton_Drive.SDK_Operations_Unavailable,
                   "Proton Drive native API mode exposes trash operation");
            Status := Proton_Drive.Resolve_Conflict
              (Native_Client, "/backups/local.zip", Op_Diagnostic);
            Check (Status /= Proton_Drive.SDK_Ok
                   and then Status /= Proton_Drive.SDK_Invalid_Config
                   and then Status /= Proton_Drive.SDK_Operations_Unavailable,
                   "Proton Drive native API mode exposes conflict operation");
            Status := Proton_Drive.Latest_Revision
              (Native_Client, "/backups/local.zip", Revision, Op_Diagnostic);
            Check (Status /= Proton_Drive.SDK_Ok
                   and then Status /= Proton_Drive.SDK_Invalid_Config
                   and then Status /= Proton_Drive.SDK_Operations_Unavailable,
                   "Proton Drive native API mode exposes revision lookup operation");
            Status := Proton_Drive.Resume_Upload
              (Native_Client, "/backups", "local.zip", "upload-123", Op_Diagnostic);
            Check (Status /= Proton_Drive.SDK_Ok
                   and then Status /= Proton_Drive.SDK_Invalid_Config
                   and then Status /= Proton_Drive.SDK_Operations_Unavailable,
                   "Proton Drive native API mode exposes resume upload operation");
         end;
      end;
   end;

   Write_File
     (Root & "/proton-native-missing-content-session.json",
      "{ ""uid"": ""uid-123"", " &
      """access_token"": ""access-token"", " &
      """user_address"": ""user@example.com"", " &
      """address_id"": ""address-123"", " &
      """address_key_id"": ""key-123"", " &
      """address_key_material"": ""address-key-material"", " &
      """metadata_key_id"": ""metadata-key-123"", " &
      """metadata_hmac_key"": ""metadata-hmac-secret"", " &
      """node_key_material"": ""node-key-material"", " &
      """proton_drive_wire_contract"": ""proton-drive-sdk-compat-v1"", " &
      """proton_drive_native_api"": ""true"" }" & ASCII.LF);
   declare
      SDK_Diagnostic : Unbounded_String;
      Native_Client : constant Proton_Drive.Client :=
        Proton_Drive.Create
          ((App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
            API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
            Session_File => To_Unbounded_String
              (Root & "/proton-native-missing-content-session.json"),
            User_Address => To_Unbounded_String ("user@example.com"),
            Share_Id     => To_Unbounded_String ("share-123")),
           SDK_Diagnostic);
   begin
      Check (Proton_Drive.Status (Native_Client) = Proton_Drive.SDK_Crypto_Unavailable,
             "Proton Drive native API mode fails closed without content key material");
   end;

   Write_File
     (Root & "/proton-native-missing-wire-session.json",
      "{ ""uid"": ""uid-123"", " &
      """access_token"": ""access-token"", " &
      """user_address"": ""user@example.com"", " &
      """address_id"": ""address-123"", " &
      """address_key_id"": ""key-123"", " &
      """address_key_material"": ""address-key-material"", " &
      """metadata_key_id"": ""metadata-key-123"", " &
      """metadata_hmac_key"": ""metadata-hmac-secret"", " &
      """node_key_material"": ""node-key-material"", " &
      """content_key_material"": ""content-key-material"", " &
      """content_hmac_key"": ""content-hmac-secret"", " &
      """proton_drive_native_api"": ""true"" }" & ASCII.LF);
   declare
      SDK_Diagnostic : Unbounded_String;
      Native_Client : constant Proton_Drive.Client :=
        Proton_Drive.Create
          ((App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
            API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
            Session_File => To_Unbounded_String
              (Root & "/proton-native-missing-wire-session.json"),
            User_Address => To_Unbounded_String ("user@example.com"),
            Share_Id     => To_Unbounded_String ("share-123")),
           SDK_Diagnostic);
   begin
      Check (Proton_Drive.Status (Native_Client) = Proton_Drive.SDK_Invalid_Config,
             "Proton Drive native API mode fails closed without explicit wire contract");
   end;

   Write_File
     (Root & "/proton-unsupported-schema-session.json",
      "{ ""uid"": ""uid-123"", " &
      """access_token"": ""access-token"", " &
      """user_address"": ""user@example.com"", " &
      """address_id"": ""address-123"", " &
      """address_key_id"": ""key-123"", " &
      """address_key_material"": ""address-key-material"", " &
      """metadata_key_id"": ""metadata-key-123"", " &
      """metadata_hmac_key"": ""metadata-hmac-secret"", " &
      """proton_drive_descriptor_version"": ""99"", " &
      """proton_drive_operation_base_url"": ""http://127.0.0.1:1/proton-fixture"" }" & ASCII.LF);
   declare
      SDK_Diagnostic : Unbounded_String;
      Bad_Client : constant Proton_Drive.Client :=
        Proton_Drive.Create
          ((App_Version  => To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
            API_Base     => To_Unbounded_String (Proton_Drive.Default_API_Base),
            Session_File => To_Unbounded_String
              (Root & "/proton-unsupported-schema-session.json"),
            User_Address => To_Unbounded_String ("user@example.com"),
            Share_Id     => To_Unbounded_String ("share-123")),
           SDK_Diagnostic);
   begin
      Check (Proton_Drive.Status (Bad_Client) = Proton_Drive.SDK_Invalid_Config,
             "Proton Drive Ada SDK rejects unsupported descriptor schema version");
   end;

   Status := Backup.Remote.Parse_URL
     (Rem_URL, Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse file remote namespace: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_File,
          "file remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "file remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("ssh://backup@example.com/var/backups/host.zip", Local,
      Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse ssh remote URL through ssh_lib: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_SSH,
          "ssh remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "host.zip",
          "ssh remote derives object name from remote path");

   Status := Backup.Remote.Parse_URL
     ("backup@example.com:archives/", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse scp-like remote through ssh_lib: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_SSH,
          "scp-like remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "scp-like directory remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("http://127.0.0.1:8080/backups/", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse http remote namespace: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_HTTP,
          "http remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "http directory remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("https://example.test/backups/nightly.zip", Local,
      Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse https remote object: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_HTTPS,
          "https remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "nightly.zip",
          "https remote derives object name from remote path");

   Status := Backup.Remote.Parse_URL
     ("s3://backup-bucket/hosts/", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse s3 remote namespace: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_S3,
          "s3 remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "s3 directory remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("s3://backup-bucket/hosts/nightly.zip", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse s3 remote object: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_S3,
          "s3 object remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "nightly.zip",
          "s3 remote derives object name from remote path");

   Status := Backup.Remote.Parse_URL
     ("gdrive://folder-123/hosts/", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse Google Drive remote namespace: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_Google_Drive,
          "Google Drive remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "Google Drive directory remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("gdrive://folder-123/hosts/nightly.zip", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse Google Drive remote object: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_Google_Drive,
          "Google Drive object remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "nightly.zip",
          "Google Drive remote derives object name from remote path");

   Check (Backup.Remote_Syntax.Is_HTTP_Transport
            (Backup.Remote.Transport_Google_Drive),
          "SPARK remote classifies Google Drive as HTTP object transport");

   Status := Backup.Remote.Parse_URL
     ("pcloud://0/hosts/", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse pCloud remote namespace: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_PCloud,
          "pCloud remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "pCloud directory remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("pcloud://0/hosts/nightly.zip", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse pCloud remote object: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_PCloud,
          "pCloud object remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "nightly.zip",
          "pCloud remote derives object name from remote path");

   Status := Backup.Remote.Parse_URL
     ("protondrive://share-123/hosts/", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse Proton Drive remote namespace: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_Proton_Drive,
          "Proton Drive remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "local.zip",
          "Proton Drive directory remote derives object name from local archive");

   Status := Backup.Remote.Parse_URL
     ("protondrive://share-123/hosts/nightly.zip", Local, Location, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "parse Proton Drive remote object: " & To_String (Diagnostic));
   Check (Location.Kind = Backup.Remote.Transport_Proton_Drive,
          "Proton Drive object remote transport kind parsed");
   Check (To_String (Location.Object_Name) = "nightly.zip",
          "Proton Drive remote derives object name from remote path");

   Check (Backup.Remote_Syntax.Is_HTTP_Transport
            (Backup.Remote.Transport_Proton_Drive),
          "SPARK remote classifies Proton Drive as HTTP SDK transport");

   Status := Backup.Remote.Upload_Archive
     ("protondrive://share-123/hosts/", Local,
      (Proton_Drive_App_Version =>
         To_Unbounded_String ("external-drive-backup@0.1.0-alpha"),
       Proton_Drive_Session_File => To_Unbounded_String (Root & "/proton-session.json"),
       Proton_Drive_User_Address => To_Unbounded_String ("user@example.com"),
       others => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Unsupported_Transport,
          "Proton Drive backend fails closed without provider endpoints");
   Check (Contains (To_String (Diagnostic), "provider operation endpoints are missing"),
          "Proton Drive fail-closed diagnostic names missing provider endpoint");

   Check (Backup.Remote_Syntax.Is_HTTP_Transport
            (Backup.Remote.Transport_PCloud),
          "SPARK remote classifies pCloud as HTTP object transport");

   Ada.Environment_Variables.Clear ("AWS_ACCESS_KEY_ID");
   Ada.Environment_Variables.Clear ("AWS_SECRET_ACCESS_KEY");
   Ada.Environment_Variables.Clear ("AWS_SESSION_TOKEN");
   Ada.Environment_Variables.Clear ("AWS_PROFILE");
   Ada.Environment_Variables.Clear ("AWS_DEFAULT_PROFILE");
   Ada.Environment_Variables.Clear ("AWS_SHARED_CREDENTIALS_FILE");
   Ada.Environment_Variables.Clear ("AWS_CONFIG_FILE");
   Ada.Environment_Variables.Clear ("AWS_CONTAINER_CREDENTIALS_FULL_URI");
   Ada.Environment_Variables.Clear ("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI");

   Status := Backup.Remote.Read_Inventory
     ("s3://backup-bucket/hosts/", Local, Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Authentication_Failed,
          "s3 inventory requires configured credentials before network access");

   Write_File (Root & "/aws-credentials",
               "[backup-test]" & ASCII.LF &
               "aws_access_key_id = shared-access" & ASCII.LF &
               "aws_secret_access_key = shared-secret" & ASCII.LF &
               "aws_session_token = shared-token" & ASCII.LF);
   Status := Backup.Remote.Read_Inventory
     ("s3://backup-bucket/hosts/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 1,
       S3_Endpoint       => To_Unbounded_String ("http://127.0.0.1:1"),
       S3_Profile        => To_Unbounded_String ("backup-test"),
       S3_Credentials_File => To_Unbounded_String (Root & "/aws-credentials"),
       others            => <>),
      Inventory, Diagnostic);
   Check (Status /= Backup.Remote.Remote_Authentication_Failed,
          "s3 shared credentials file supplies credentials before network access");

   Write_File (Root & "/aws-config",
               "[profile config-test]" & ASCII.LF &
               "aws_access_key_id = config-access" & ASCII.LF &
               "aws_secret_access_key = config-secret" & ASCII.LF &
               "aws_session_token = config-token" & ASCII.LF &
               "region = ap-southeast-2" & ASCII.LF);
   Status := Backup.Remote.Read_Inventory
     ("s3://backup-bucket/hosts/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 1,
       S3_Endpoint       => To_Unbounded_String ("http://127.0.0.1:1"),
       S3_Profile        => To_Unbounded_String ("config-test"),
       S3_Config_File    => To_Unbounded_String (Root & "/aws-config"),
       others            => <>),
      Inventory, Diagnostic);
   Check (Status /= Backup.Remote.Remote_Authentication_Failed,
          "s3 shared config profile supplies credentials before network access");

   Status := Backup.Remote.Presign_S3_URL
     ("s3://backup-bucket/hosts/nightly.zip", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       S3_Endpoint       => To_Unbounded_String ("https://s3.example.test"),
       S3_Region         => To_Unbounded_String ("eu-central-1"),
       S3_Access_Key     => To_Unbounded_String ("AKIAEXAMPLE"),
       S3_Secret_Key     => To_Unbounded_String ("secret"),
       S3_Session_Token  => To_Unbounded_String ("session"),
       others            => <>),
      Backup.Remote.S3_Presign_GET, 900, Presigned, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "s3 presigned URL can be generated: " & To_String (Diagnostic));
   Check (Contains (To_String (Presigned), "X-Amz-Algorithm=AWS4-HMAC-SHA256"),
          "s3 presigned URL includes SigV4 algorithm");
   Check (Contains (To_String (Presigned), "X-Amz-Expires=900"),
          "s3 presigned URL includes expiry");
   Check (Contains (To_String (Presigned), "X-Amz-Security-Token=session"),
          "s3 presigned URL includes session token");
   Check (Contains (To_String (Presigned), "X-Amz-Signature="),
          "s3 presigned URL includes signature");

   Status := Backup.Remote.Read_Inventory
     ("s3:///hosts/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       S3_Access_Key     => To_Unbounded_String ("key"),
       S3_Secret_Key     => To_Unbounded_String ("secret"),
       others            => <>),
      Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Invalid_URL,
          "s3 inventory rejects missing bucket before network access");

   Status := Backup.Remote.Read_Inventory
     ("s3://backup-bucket/hosts/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       S3_Endpoint       => To_Unbounded_String ("ftp://s3.example.test"),
       S3_Access_Key     => To_Unbounded_String ("key"),
       S3_Secret_Key     => To_Unbounded_String ("secret"),
       others            => <>),
      Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Invalid_URL,
          "s3 inventory rejects unsupported endpoint scheme before network access");

   Status := Backup.Remote.Read_Inventory
     ("s3://backup-bucket/hosts/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       S3_Access_Key     => To_Unbounded_String ("key"),
       S3_Secret_Key     => To_Unbounded_String ("secret"),
       S3_Server_Side_Encryption => To_Unbounded_String ("invalid"),
       others            => <>),
      Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Invalid_URL,
          "s3 inventory rejects unsupported SSE mode before network access");

   Status := Backup.Remote.Read_Inventory
     ("ssh://backup@example.com/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Invalid_URL,
          "ssh inventory rejects a missing remote path before opening a session");

   Status := Backup.Remote.Read_Inventory
     ("ssh://backup@example.com/var/backups/", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 0,
       others            => <>),
      Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Timeout,
          "ssh inventory honors timeout precheck before opening a session");

   Status := Backup.Remote.Upload_Archive
     ("ssh://backup@example.com/var/backups/host.zip", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 0,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Timeout,
          "ssh upload honors timeout precheck before opening a session");

   Status := Backup.Remote.Upload_Archive
     ("ssh://backup@example.com/var/backups/host.zip", Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Resume_If_Supported,
       Retry_Count       => 0,
       Timeout_Seconds   => 0,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Timeout,
          "ssh resume upload honors timeout precheck before opening a session");

   Status := Backup.Remote.Upload_Archive
     (Rem_URL, Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "file remote upload verifies metadata: " & To_String (Diagnostic));
   Check (Report.Atomic, "file remote upload uses temporary object rename");
   Check (Report.Verified, "file remote upload verifies remote copy");
   Check (GNAT.OS_Lib.Is_Readable_File (Rem_Dir & "/local.zip"),
          "file remote uploaded object exists");


   Status := Backup.Remote.Upload_Archive
     (Rem_URL, Local,
      (Require_Encrypted => True,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Encryption_Required,
          "remote upload refuses plaintext when encryption is required");

   Status := Backup.Remote.Upload_Archive
     (Rem_URL, Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 2,
       Timeout_Seconds   => 0,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Timeout,
          "remote upload honors explicit timeout policy");


   Write_File (Rem_Dir & "/local.zip.partial", "archive" & ASCII.LF);
   Status := Backup.Remote.Upload_Archive
     (Rem_URL, Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Resume_If_Supported,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check
     (Status = Backup.Remote.Remote_Ok,
      "remote upload resumes matching partial object: " &
      To_String (Diagnostic));
   Check (Report.Resumed, "matching partial upload is promoted as resumed");

   Write_File (Rem_Dir & "/local.zip", "corrupt" & ASCII.LF);
   Status := Backup.Remote.Verify_Remote_Archive
     (Rem_URL, Local, Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Metadata_Mismatch,
          "corrupted remote object is rejected");

   Status := Backup.Remote.Read_Inventory
     (Rem_URL, Local, Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "remote inventory loads: " & To_String (Diagnostic));
   declare
      Saw_Local : Boolean := False;
   begin
      for Item of Inventory loop
         if To_String (Item.Archive_Id) = "local.zip" then
            Saw_Local := True;
            Check (Item.Has_Timestamp,
                   "file remote inventory exposes object timestamp");
            Check
              (Item.Timestamp =
                 Ada.Directories.Modification_Time (Rem_Dir & "/local.zip"),
               "file remote inventory timestamp matches file metadata");
         end if;
      end loop;
      Check (Saw_Local, "remote inventory includes uploaded object");
   end;
   Status := Backup.Remote.Build_Sync_Plan
     (Local, Inventory, Plan, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "remote sync plan builds: " & To_String (Diagnostic));
   Check (not Plan.Is_Empty, "remote sync plan contains steps");
   Check (Plan.Last_Element.Action = Backup.Remote.Sync_Upload,
          "metadata mismatch plans upload");

   Write_File (Rem_Dir & "/local.zip.partial", "partial" & ASCII.LF);
   Write_File (Rem_Dir & "/scratch.partial", "not managed" & ASCII.LF);
   Status := Backup.Remote.Read_Inventory
     (Rem_URL, Local, Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "remote inventory accepts managed partial marker");
   declare
      Saw_Unmanaged_Partial : Boolean := False;
   begin
      for Item of Inventory loop
         if To_String (Item.Archive_Id) = "scratch.partial" then
            Saw_Unmanaged_Partial := True;
         end if;
      end loop;
      Check
        (not Saw_Unmanaged_Partial,
         "remote inventory ignores unmanaged partial object names");
   end;
   Status := Backup.Remote.Build_Sync_Plan
     (Local, Inventory, Plan, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "sync plan handles interrupted upload marker");
   declare
      Saw_Delete : Boolean := False;
   begin
      for Step of Plan loop
         if Step.Action = Backup.Remote.Sync_Delete_Remote then
            Saw_Delete := True;
         end if;
      end loop;
      Check (Saw_Delete, "partial upload marker plans scoped remote deletion");
   end;


   Status := Backup.Remote.Delete_Remote_Object
     (Rem_URL, Local, "local.zip.partial", Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "scoped remote delete removes managed partial marker: " &
          To_String (Diagnostic));
   Check (not GNAT.OS_Lib.Is_Readable_File (Rem_Dir & "/local.zip.partial"),
          "managed partial marker was deleted");
   Status := Backup.Remote.Delete_Remote_Object
     (Rem_URL, Local, "../escape.zip", Diagnostic);
   Check (Status = Backup.Remote.Remote_Delete_Refused,
          "remote delete refuses unsafe object name");
   Status := Backup.Remote.Delete_Remote_Object
     (Rem_URL, Local, "scratch.partial", Diagnostic);
   Check (Status = Backup.Remote.Remote_Delete_Refused,
          "remote delete refuses unmanaged partial object name");

   Write_File (Root & "/remote.conf",
               "remote=" & Rem_URL & ASCII.LF &
               "resume=true" & ASCII.LF &
               "retry_count=2" & ASCII.LF &
               "timeout_seconds=10" & ASCII.LF &
               "http_bearer_token=secret-token" & ASCII.LF &
               "tls_ca_file=/tmp/ca.pem" & ASCII.LF &
               "tls_ca_directory=/tmp/certs" & ASCII.LF &
               "tls_client_cert=/tmp/client.pem" & ASCII.LF &
               "tls_client_key=/tmp/client-key.pem" & ASCII.LF &
               "tls_client_key_passphrase=secret" & ASCII.LF &
               "s3_endpoint=https://s3.example.test" & ASCII.LF &
               "s3_region=eu-central-1" & ASCII.LF &
               "s3_profile=backup-profile" & ASCII.LF &
               "s3_credentials_file=/tmp/aws-credentials" & ASCII.LF &
               "s3_config_file=/tmp/aws-config" & ASCII.LF &
               "s3_web_identity_token_file=/tmp/web-identity-token" & ASCII.LF &
               "s3_role_arn=arn:aws:iam::123456789012:role/backup" & ASCII.LF &
               "s3_credential_process=/usr/bin/aws-credential-helper" & ASCII.LF &
               "s3_sso_session=backup-sso" & ASCII.LF &
               "s3_sso_start_url=https://example.awsapps.com/start" & ASCII.LF &
               "s3_sso_region=eu-west-1" & ASCII.LF &
               "s3_sso_account_id=123456789012" & ASCII.LF &
               "s3_sso_role_name=BackupRole" & ASCII.LF &
               "s3_addressing=virtual" & ASCII.LF &
               "s3_server_side_encryption=aws:kms" & ASCII.LF &
               "s3_sse_kms_key_id=kms-key" & ASCII.LF &
               "s3_acl=bucket-owner-full-control" & ASCII.LF &
               "s3_storage_class=STANDARD_IA" & ASCII.LF &
               "s3_tagging=backup=true&env=test" & ASCII.LF &
               "s3_metadata_name=backup-job" & ASCII.LF &
               "s3_metadata_value=nightly" & ASCII.LF &
               "s3_cache_control=no-store" & ASCII.LF &
               "s3_content_disposition=attachment" & ASCII.LF &
               "s3_content_encoding=gzip" & ASCII.LF &
               "s3_object_lock_mode=GOVERNANCE" & ASCII.LF &
               "s3_object_lock_retain_until=2030-01-01T00:00:00Z" & ASCII.LF &
               "s3_object_lock_legal_hold=ON" & ASCII.LF &
               "s3_multipart_threshold=12345" & ASCII.LF &
               "s3_multipart_part_size=6789" & ASCII.LF &
               "s3_access_key=AKIAEXAMPLE" & ASCII.LF &
               "s3_secret_key=secret" & ASCII.LF &
               "s3_session_token=session" & ASCII.LF &
               "google_drive_api_base=https://www.googleapis.test/drive/v3" & ASCII.LF &
               "google_drive_upload_base=https://www.googleapis.test/upload/drive/v3" & ASCII.LF &
               "google_drive_access_token_file=/tmp/google-drive-token" & ASCII.LF &
               "google_drive_refresh_token=refresh-token" & ASCII.LF &
               "google_drive_client_id=client-id" & ASCII.LF &
               "google_drive_client_secret=client-secret" & ASCII.LF &
               "google_drive_token_uri=https://oauth2.example.test/token" & ASCII.LF &
               "google_drive_supports_all_drives=true" & ASCII.LF &
               "google_drive_drive_id=shared-drive-123" & ASCII.LF &
               "google_drive_access_token=drive-token" & ASCII.LF &
               "pcloud_api_base=https://api.pcloud.test" & ASCII.LF &
               "pcloud_access_token_file=/tmp/pcloud-token" & ASCII.LF &
               "pcloud_token_cache_file=/tmp/pcloud-cache-token" & ASCII.LF &
               "pcloud_large_upload_threshold=1234" & ASCII.LF &
               "pcloud_upload_progress=false" & ASCII.LF &
               "pcloud_poll_progress=true" & ASCII.LF &
               "pcloud_check_quota=false" & ASCII.LF &
               "pcloud_create_parents=false" & ASCII.LF &
               "pcloud_clean_recursive=true" & ASCII.LF &
               "pcloud_access_token=pcloud-token" & ASCII.LF &
               "proton_drive_api_base=https://drive.proton.test" & ASCII.LF &
               "proton_drive_app_version=external-drive-backup@0.1.0-alpha" & ASCII.LF &
               "proton_drive_session_file=/tmp/proton-session.json" & ASCII.LF &
               "proton_drive_user_address=user@example.com" & ASCII.LF);
   Check
     (Backup.CLI.Parse
        (Args ("--remote-config", Root & "/remote.conf", "--upload",
               Output, Src_Dir),
         Config, Diagnostic),
      "CLI loads remote URL and options from remote config: " &
      To_String (Diagnostic));
   Check (To_String (Config.Remote_URL) = Rem_URL,
          "remote config supplies remote URL");
   Check (Config.Remote_Options.Upload_Behavior =
          Backup.Remote.Upload_Resume_If_Supported,
          "remote config supplies resume behavior");
   Check (Config.Remote_Options.HTTP_Auth = Backup.Remote.HTTP_Auth_Bearer,
          "remote config supplies HTTP bearer auth mode");
   Check (To_String (Config.Remote_Options.HTTP_Bearer_Token) = "secret-token",
          "remote config supplies HTTP bearer token");
   Check (To_String (Config.Remote_Options.TLS_CA_File) = "/tmp/ca.pem",
          "remote config supplies TLS CA file path");
   Check (To_String (Config.Remote_Options.TLS_CA_Directory) = "/tmp/certs",
          "remote config supplies TLS CA directory path");
   Check (To_String (Config.Remote_Options.TLS_Client_Cert_File) =
          "/tmp/client.pem",
          "remote config supplies TLS client certificate path");
   Check (To_String (Config.Remote_Options.TLS_Client_Key_File) =
          "/tmp/client-key.pem",
          "remote config supplies TLS client key path");
   Check (Config.Remote_Options.TLS_Client_Has_Passphrase,
          "remote config records explicit TLS key passphrase");
   Check (To_String (Config.Remote_Options.S3_Endpoint) =
          "https://s3.example.test",
          "remote config supplies S3 endpoint");
   Check (To_String (Config.Remote_Options.S3_Region) = "eu-central-1",
          "remote config supplies S3 region");
   Check (To_String (Config.Remote_Options.S3_Profile) = "backup-profile",
          "remote config supplies S3 profile");
   Check (To_String (Config.Remote_Options.S3_Credentials_File) =
          "/tmp/aws-credentials",
          "remote config supplies S3 credentials file");
   Check (To_String (Config.Remote_Options.S3_Config_File) =
          "/tmp/aws-config",
          "remote config supplies S3 config file");
   Check (To_String (Config.Remote_Options.S3_Web_Identity_Token_File) =
          "/tmp/web-identity-token",
          "remote config supplies S3 web identity token file");
   Check (To_String (Config.Remote_Options.S3_Role_Arn) =
          "arn:aws:iam::123456789012:role/backup",
          "remote config supplies S3 role ARN");
   Check (To_String (Config.Remote_Options.S3_Credential_Process) =
          "/usr/bin/aws-credential-helper",
          "remote config supplies S3 credential process");
   Check (To_String (Config.Remote_Options.S3_SSO_Session) = "backup-sso",
          "remote config supplies S3 SSO session");
   Check (To_String (Config.Remote_Options.S3_SSO_Start_URL) =
          "https://example.awsapps.com/start",
          "remote config supplies S3 SSO start URL");
   Check (To_String (Config.Remote_Options.S3_SSO_Region) = "eu-west-1",
          "remote config supplies S3 SSO region");
   Check (To_String (Config.Remote_Options.S3_SSO_Account_Id) = "123456789012",
          "remote config supplies S3 SSO account id");
   Check (To_String (Config.Remote_Options.S3_SSO_Role_Name) = "BackupRole",
          "remote config supplies S3 SSO role name");
   Check (Config.Remote_Options.S3_Virtual_Hosted_Style,
          "remote config supplies virtual-hosted S3 addressing");
   Check (To_String (Config.Remote_Options.S3_Server_Side_Encryption) =
          "aws:kms",
          "remote config supplies S3 server-side encryption mode");
   Check (To_String (Config.Remote_Options.S3_SSE_KMS_Key_Id) = "kms-key",
          "remote config supplies S3 KMS key id");
   Check (To_String (Config.Remote_Options.S3_ACL) =
          "bucket-owner-full-control",
          "remote config supplies S3 ACL");
   Check (To_String (Config.Remote_Options.S3_Storage_Class) = "STANDARD_IA",
          "remote config supplies S3 storage class");
   Check (To_String (Config.Remote_Options.S3_Tagging) =
          "backup=true&env=test",
          "remote config supplies S3 tagging");
   Check (To_String (Config.Remote_Options.S3_Metadata_Name) = "backup-job",
          "remote config supplies S3 metadata name");
   Check (To_String (Config.Remote_Options.S3_Metadata_Value) = "nightly",
          "remote config supplies S3 metadata value");
   Check (To_String (Config.Remote_Options.S3_Cache_Control) = "no-store",
          "remote config supplies S3 cache-control");
   Check (To_String (Config.Remote_Options.S3_Content_Disposition) = "attachment",
          "remote config supplies S3 content-disposition");
   Check (To_String (Config.Remote_Options.S3_Content_Encoding) = "gzip",
          "remote config supplies S3 content-encoding");
   Check (To_String (Config.Remote_Options.S3_Object_Lock_Mode) = "GOVERNANCE",
          "remote config supplies S3 Object Lock mode");
   Check (To_String (Config.Remote_Options.S3_Object_Lock_Retain_Until) =
          "2030-01-01T00:00:00Z",
          "remote config supplies S3 Object Lock retain-until date");
   Check (To_String (Config.Remote_Options.S3_Object_Lock_Legal_Hold) = "ON",
          "remote config supplies S3 Object Lock legal hold");
   Check (Config.Remote_Options.S3_Multipart_Threshold = 12345,
          "remote config supplies S3 multipart threshold");
   Check (Config.Remote_Options.S3_Multipart_Part_Size = 6789,
          "remote config supplies S3 multipart part size");
   Check (To_String (Config.Remote_Options.S3_Access_Key) = "AKIAEXAMPLE",
          "remote config supplies S3 access key");
   Check (To_String (Config.Remote_Options.S3_Secret_Key) = "secret",
          "remote config supplies S3 secret key");
   Check (To_String (Config.Remote_Options.S3_Session_Token) = "session",
          "remote config supplies S3 session token");
   Check (To_String (Config.Remote_Options.Google_Drive_API_Base) =
          "https://www.googleapis.test/drive/v3",
          "remote config supplies Google Drive API base");
   Check (To_String (Config.Remote_Options.Google_Drive_Upload_Base) =
          "https://www.googleapis.test/upload/drive/v3",
          "remote config supplies Google Drive upload base");
   Check (To_String (Config.Remote_Options.Google_Drive_Access_Token) =
          "drive-token",
          "remote config supplies Google Drive access token");
   Check (To_String (Config.Remote_Options.Google_Drive_Access_Token_File) =
          "/tmp/google-drive-token",
          "remote config supplies Google Drive token file");
   Check (To_String (Config.Remote_Options.Google_Drive_Refresh_Token) =
          "refresh-token",
          "remote config supplies Google Drive refresh token");
   Check (To_String (Config.Remote_Options.Google_Drive_Client_Id) =
          "client-id",
          "remote config supplies Google Drive client id");
   Check (To_String (Config.Remote_Options.Google_Drive_Client_Secret) =
          "client-secret",
          "remote config supplies Google Drive client secret");
   Check (To_String (Config.Remote_Options.Google_Drive_Token_URI) =
          "https://oauth2.example.test/token",
          "remote config supplies Google Drive token URI");
   Check (Config.Remote_Options.Google_Drive_Supports_All_Drives,
          "remote config supplies Google Drive shared-drive flag");
   Check (To_String (Config.Remote_Options.Google_Drive_Drive_Id) =
          "shared-drive-123",
          "remote config supplies Google Drive shared-drive id");
   Check (To_String (Config.Remote_Options.PCloud_API_Base) =
          "https://api.pcloud.test",
          "remote config supplies pCloud API base");
   Check (To_String (Config.Remote_Options.PCloud_Access_Token) =
          "pcloud-token",
          "remote config supplies pCloud access token");
   Check (To_String (Config.Remote_Options.PCloud_Access_Token_File) =
          "/tmp/pcloud-token",
          "remote config supplies pCloud token file");
   Check (To_String (Config.Remote_Options.PCloud_Token_Cache_File) =
          "/tmp/pcloud-cache-token",
          "remote config supplies pCloud token cache file");
   Check (Config.Remote_Options.PCloud_Large_Upload_Threshold = 1234,
          "remote config supplies pCloud large upload threshold");
   Check (not Config.Remote_Options.PCloud_Upload_Progress,
          "remote config supplies pCloud upload progress flag");
   Check (Config.Remote_Options.PCloud_Poll_Progress,
          "remote config supplies pCloud progress polling flag");
   Check (not Config.Remote_Options.PCloud_Check_Quota,
          "remote config supplies pCloud quota preflight flag");
   Check (not Config.Remote_Options.PCloud_Create_Parents,
          "remote config supplies pCloud parent creation flag");
   Check (Config.Remote_Options.PCloud_Clean_Recursive,
          "remote config supplies pCloud recursive cleanup flag");
   Check (To_String (Config.Remote_Options.Proton_Drive_API_Base) =
          "https://drive.proton.test",
          "remote config supplies Proton Drive API base");
   Check (To_String (Config.Remote_Options.Proton_Drive_App_Version) =
          "external-drive-backup@0.1.0-alpha",
          "remote config supplies Proton Drive app version");
   Check (To_String (Config.Remote_Options.Proton_Drive_Session_File) =
          "/tmp/proton-session.json",
          "remote config supplies Proton Drive session file");
   Check (To_String (Config.Remote_Options.Proton_Drive_User_Address) =
          "user@example.com",
          "remote config supplies Proton Drive user address");

   Ada.Environment_Variables.Set
     ("BACKUP_TEST_S3_ACCESS_KEY", "env-access");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_S3_SECRET_KEY", "env-secret");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_S3_SESSION_TOKEN", "env-session");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_GOOGLE_DRIVE_TOKEN", "env-drive-token");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_PCLOUD_TOKEN", "env-pcloud-token");
   Write_File (Root & "/remote-env.conf",
               "remote=" & Rem_URL & ASCII.LF &
               "s3_access_key_env=BACKUP_TEST_S3_ACCESS_KEY" & ASCII.LF &
               "s3_secret_key_env=BACKUP_TEST_S3_SECRET_KEY" & ASCII.LF &
               "s3_session_token_env=BACKUP_TEST_S3_SESSION_TOKEN" & ASCII.LF &
               "google_drive_access_token_env=BACKUP_TEST_GOOGLE_DRIVE_TOKEN" & ASCII.LF &
               "pcloud_access_token_env=BACKUP_TEST_PCLOUD_TOKEN" & ASCII.LF);
   Check
     (Backup.CLI.Parse
        (Args ("--remote-config", Root & "/remote-env.conf", "--upload",
               Output, Src_Dir),
         Config, Diagnostic),
      "CLI loads S3 credentials from environment-backed remote config: " &
      To_String (Diagnostic));
   Check (To_String (Config.Remote_Options.S3_Access_Key) = "env-access",
          "remote config env supplies S3 access key");
   Check (To_String (Config.Remote_Options.S3_Secret_Key) = "env-secret",
          "remote config env supplies S3 secret key");
   Check (To_String (Config.Remote_Options.S3_Session_Token) = "env-session",
          "remote config env supplies S3 session token");
   Check (To_String (Config.Remote_Options.Google_Drive_Access_Token) =
          "env-drive-token",
          "remote config env supplies Google Drive token");
   Check (To_String (Config.Remote_Options.PCloud_Access_Token) =
          "env-pcloud-token",
          "remote config env supplies pCloud token");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_S3_ACCESS_KEY");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_S3_SECRET_KEY");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_S3_SESSION_TOKEN");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_GOOGLE_DRIVE_TOKEN");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_PCLOUD_TOKEN");

   Check
     (Backup.CLI.Parse
        (Args ("--remote", Rem_URL, "--upload",
               Output, Src_Dir),
         Config, Diagnostic),
      "CLI accepts remote upload options: " & To_String (Diagnostic));
   Check (Config.Upload_Remote, "CLI records remote upload flag");
   Check (To_String (Config.Remote_URL) = Rem_URL,
          "CLI records remote URL");

   Workflow_Status := Backup.Workflow.Execute (Config, Diagnostic);
   Check (Workflow_Status = Backup.Workflow.Execution_Ok,
          "workflow uploads created archive: " & To_String (Diagnostic));
   Check (GNAT.OS_Lib.Is_Readable_File (Rem_Dir & "/out.zip"),
          "workflow remote upload object exists");

   Check
     (Backup.CLI.Parse
        (Args ("--restore-remote", "--remote",
               "file://" & Rem_Dir & "/out.zip",
               Root & "/restored.zip"),
         Config, Diagnostic),
      "CLI accepts remote restore options: " & To_String (Diagnostic));
   Workflow_Status := Backup.Workflow.Execute (Config, Diagnostic);
   Check (Workflow_Status = Backup.Workflow.Execution_Ok,
          "workflow restores remote archive: " & To_String (Diagnostic));
   Check (Ada.Directories.Exists (Root & "/restored.zip"),
          "remote restore creates local archive copy");



   Check
     (Backup.CLI.Parse
        (Args ("--list-json", "--remote", Rem_URL,
               "--upload", Root & "/json.zip", Src_Dir),
         Config, Diagnostic),
      "CLI accepts remote upload JSON options: " & To_String (Diagnostic));
   Workflow_Status := Backup.Workflow.Execute (Config, Diagnostic);
   Check (Workflow_Status = Backup.Workflow.Execution_Ok,
          "workflow remote upload JSON succeeds: " & To_String (Diagnostic));
   Check (Contains (To_String (Diagnostic), "backup-remote-v1"),
          "remote upload JSON report is not overwritten by archive JSON");

   Check
     (Backup.CLI.Parse
        (Args ("--dry-run", "--remote", Rem_URL,
               "--sync", Root & "/dry-sync.zip", Src_Dir),
         Config, Diagnostic),
      "CLI accepts remote sync dry-run options: " & To_String (Diagnostic));
   Workflow_Status := Backup.Workflow.Execute (Config, Diagnostic);
   Check (Workflow_Status = Backup.Workflow.Execution_Ok,
          "workflow remote sync dry-run succeeds: " & To_String (Diagnostic));
   Check (Contains (To_String (Diagnostic), "Remote synchronization plan"),
          "remote sync dry-run has human-readable output without --list-json");

   Write_File (Rem_Dir & "/unmanaged.zip", "do not delete" & ASCII.LF);
   Write_File (Root & "/remote-job.conf",
               "format=backup-job-v1" & ASCII.LF &
               "name=remote-retention" & ASCII.LF &
               "source=" & Src_Dir & ASCII.LF &
               "output=" & Root & "/job.zip" & ASCII.LF &
               "output_naming=sequence" & ASCII.LF &
               "compression=store" & ASCII.LF &
               "symlinks=skip" & ASCII.LF &
               "deterministic=false" & ASCII.LF &
               "manifest=true" & ASCII.LF &
               "list_json=true" & ASCII.LF &
               "dry_run=false" & ASCII.LF &
               "encrypt=false" & ASCII.LF &
               "verify_after=false" & ASCII.LF &
               "retention_after=true" & ASCII.LF &
               "retention=count:1" & ASCII.LF &
               "remote=" & Rem_URL & ASCII.LF &
               "upload_after=true" & ASCII.LF &
               "sync_after=false" & ASCII.LF &
               "remote_require_encrypted=false" & ASCII.LF &
               "remote_resume=false" & ASCII.LF &
               "remote_s3_endpoint=http://127.0.0.1:9000" & ASCII.LF &
               "remote_s3_region=test-region-1" & ASCII.LF &
               "remote_s3_profile=job-profile" & ASCII.LF &
               "remote_s3_credentials_file=/tmp/job-aws-credentials" & ASCII.LF &
               "remote_s3_config_file=/tmp/job-aws-config" & ASCII.LF &
               "remote_s3_web_identity_token_file=/tmp/job-web-identity-token" & ASCII.LF &
               "remote_s3_role_arn=arn:aws:iam::123456789012:role/job-backup" & ASCII.LF &
               "remote_s3_credential_process=/usr/bin/job-aws-credential-helper" & ASCII.LF &
               "remote_s3_sso_session=job-sso" & ASCII.LF &
               "remote_s3_sso_start_url=https://example.awsapps.com/start" & ASCII.LF &
               "remote_s3_sso_region=eu-west-1" & ASCII.LF &
               "remote_s3_sso_account_id=123456789012" & ASCII.LF &
               "remote_s3_sso_role_name=JobBackupRole" & ASCII.LF &
               "remote_s3_addressing=path" & ASCII.LF &
               "remote_s3_server_side_encryption=AES256" & ASCII.LF &
               "remote_s3_acl=private" & ASCII.LF &
               "remote_s3_storage_class=GLACIER_IR" & ASCII.LF &
               "remote_s3_tagging=job=true" & ASCII.LF &
               "remote_s3_metadata_name=job" & ASCII.LF &
               "remote_s3_metadata_value=scheduled" & ASCII.LF &
               "remote_s3_cache_control=no-store" & ASCII.LF &
               "remote_s3_content_disposition=attachment" & ASCII.LF &
               "remote_s3_content_encoding=gzip" & ASCII.LF &
               "remote_s3_object_lock_mode=COMPLIANCE" & ASCII.LF &
               "remote_s3_object_lock_retain_until=2031-01-01T00:00:00Z" & ASCII.LF &
               "remote_s3_object_lock_legal_hold=OFF" & ASCII.LF &
               "remote_s3_multipart_threshold=23456" & ASCII.LF &
               "remote_s3_multipart_part_size=7890" & ASCII.LF &
               "remote_s3_access_key_env=BACKUP_TEST_JOB_S3_ACCESS_KEY" & ASCII.LF &
               "remote_s3_secret_key_env=BACKUP_TEST_JOB_S3_SECRET_KEY" & ASCII.LF &
               "remote_s3_session_token_env=BACKUP_TEST_JOB_S3_SESSION_TOKEN" & ASCII.LF &
               "remote_google_drive_api_base=https://jobs.googleapis.test/drive/v3" & ASCII.LF &
               "remote_google_drive_upload_base=https://jobs.googleapis.test/upload/drive/v3" & ASCII.LF &
               "remote_google_drive_access_token_file=/tmp/job-google-drive-token" & ASCII.LF &
               "remote_google_drive_refresh_token=job-refresh-token" & ASCII.LF &
               "remote_google_drive_client_id=job-client-id" & ASCII.LF &
               "remote_google_drive_client_secret=job-client-secret" & ASCII.LF &
               "remote_google_drive_token_uri=https://oauth2.jobs.test/token" & ASCII.LF &
               "remote_google_drive_supports_all_drives=true" & ASCII.LF &
               "remote_google_drive_drive_id=job-shared-drive" & ASCII.LF &
               "remote_google_drive_access_token_env=BACKUP_TEST_JOB_GOOGLE_DRIVE_TOKEN" & ASCII.LF &
               "remote_pcloud_api_base=https://jobs.api.pcloud.test" & ASCII.LF &
               "remote_pcloud_access_token_file=/tmp/job-pcloud-token" & ASCII.LF &
               "remote_pcloud_token_cache_file=/tmp/job-pcloud-cache-token" & ASCII.LF &
               "remote_pcloud_large_upload_threshold=4321" & ASCII.LF &
               "remote_pcloud_upload_progress=false" & ASCII.LF &
               "remote_pcloud_poll_progress=true" & ASCII.LF &
               "remote_pcloud_check_quota=false" & ASCII.LF &
               "remote_pcloud_create_parents=false" & ASCII.LF &
               "remote_pcloud_clean_recursive=true" & ASCII.LF &
               "remote_pcloud_access_token_env=BACKUP_TEST_JOB_PCLOUD_TOKEN" & ASCII.LF &
               "schedule=manual" & ASCII.LF);
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_JOB_S3_ACCESS_KEY", "job-env-access");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_JOB_S3_SECRET_KEY", "job-env-secret");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_JOB_S3_SESSION_TOKEN", "job-env-session");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_JOB_GOOGLE_DRIVE_TOKEN", "job-env-drive-token");
   Ada.Environment_Variables.Set
     ("BACKUP_TEST_JOB_PCLOUD_TOKEN", "job-env-pcloud-token");
   Check (Backup.Jobs.Execute (Root & "/remote-job.conf", "", Diagnostic) =
          Backup.Jobs.Job_Ok,
          "remote retention job first execution succeeds: " &
          To_String (Diagnostic));
   GNAT.OS_Lib.Set_File_Last_Modify_Time_Stamp
     (Rem_Dir & "/job-000001.zip",
      GNAT.OS_Lib.GM_Time_Of (2030, 1, 1, 0, 0, 0));
   Check (Backup.Jobs.Execute (Root & "/remote-job.conf", "", Diagnostic) =
          Backup.Jobs.Job_Ok,
          "remote retention job second execution succeeds: " &
          To_String (Diagnostic));
   Check (GNAT.OS_Lib.Is_Readable_File (Rem_Dir & "/job-000001.zip"),
          "remote retention keeps newer remote timestamp over sequence name");
   Check (not GNAT.OS_Lib.Is_Readable_File (Rem_Dir & "/job-000002.zip"),
          "remote retention prunes older remote timestamp");
   Check (GNAT.OS_Lib.Is_Readable_File (Rem_Dir & "/unmanaged.zip"),
          "remote retention leaves unmanaged remote object untouched");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_JOB_S3_ACCESS_KEY");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_JOB_S3_SECRET_KEY");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_JOB_S3_SESSION_TOKEN");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_JOB_GOOGLE_DRIVE_TOKEN");
   Ada.Environment_Variables.Clear ("BACKUP_TEST_JOB_PCLOUD_TOKEN");

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup remote tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup remote test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Remote_Tests;
