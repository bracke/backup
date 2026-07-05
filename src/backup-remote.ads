with Ada.Calendar;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Backup.Remote is
   --  Strongly typed remote transport and synchronization planning.
   --
   --  Phase 21 implements deterministic file:// remote namespaces. SSH
   --  remote names are parsed through the sibling SSH_Lib library. HTTP/HTTPS
   --  object transfers and index inventory are implemented through HttpClient.
   --  Unsupported protocols fail before archive orchestration.

   type Transport_Kind is
     (Transport_File,
      Transport_HTTP,
      Transport_HTTPS,
      Transport_S3,
      Transport_Google_Drive,
      Transport_PCloud,
      Transport_Proton_Drive,
      Transport_SSH,
      Transport_Unsupported);

   type Remote_Status is
     (Remote_Ok,
      Remote_Invalid_URL,
      Remote_Unsupported_Transport,
      Remote_Open_Failed,
      Remote_Read_Failed,
      Remote_Write_Failed,
      Remote_Copy_Failed,
      Remote_Verify_Failed,
      Remote_Metadata_Mismatch,
      Remote_Authentication_Failed,
      Remote_Timeout,
      Remote_Interrupted,
      Remote_Unsafe_Namespace,
      Remote_Not_Found,
      Remote_Partial_Object,
      Remote_Delete_Refused,
      Remote_Encryption_Required);

   type Upload_Mode is
     (Upload_Atomic,
      Upload_Resume_If_Supported);

   type Sync_Action is
     (Sync_Keep,
      Sync_Upload,
      Sync_Download,
      Sync_Delete_Remote);

   type HTTP_Auth_Mode is
     (HTTP_Auth_None,
      HTTP_Auth_Bearer,
      HTTP_Auth_Basic,
      HTTP_Auth_Custom_Header);

   type S3_Presign_Method is
     (S3_Presign_GET,
      S3_Presign_PUT,
      S3_Presign_DELETE);

   type Remote_Options is record
      Require_Encrypted : Boolean := False;
      Upload_Behavior   : Upload_Mode := Upload_Atomic;
      Retry_Count       : Natural := 0;
      Timeout_Seconds   : Natural := 60;
      HTTP_Auth         : HTTP_Auth_Mode := HTTP_Auth_None;
      HTTP_Bearer_Token : Ada.Strings.Unbounded.Unbounded_String;
      HTTP_Basic_User   : Ada.Strings.Unbounded.Unbounded_String;
      HTTP_Basic_Pass   : Ada.Strings.Unbounded.Unbounded_String;
      HTTP_Header_Name  : Ada.Strings.Unbounded.Unbounded_String;
      HTTP_Header_Value : Ada.Strings.Unbounded.Unbounded_String;
      TLS_CA_File : Ada.Strings.Unbounded.Unbounded_String;
      TLS_CA_Directory : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Client_Cert_File : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Client_Key_File  : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Client_Key_Passphrase : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Client_Has_Passphrase : Boolean := False;
      S3_Endpoint      : Ada.Strings.Unbounded.Unbounded_String;
      S3_Region        : Ada.Strings.Unbounded.Unbounded_String;
      S3_Profile       : Ada.Strings.Unbounded.Unbounded_String;
      S3_Credentials_File : Ada.Strings.Unbounded.Unbounded_String;
      S3_Config_File   : Ada.Strings.Unbounded.Unbounded_String;
      S3_Web_Identity_Token_File : Ada.Strings.Unbounded.Unbounded_String;
      S3_Role_Arn      : Ada.Strings.Unbounded.Unbounded_String;
      S3_Credential_Process : Ada.Strings.Unbounded.Unbounded_String;
      S3_SSO_Session   : Ada.Strings.Unbounded.Unbounded_String;
      S3_SSO_Start_URL : Ada.Strings.Unbounded.Unbounded_String;
      S3_SSO_Region    : Ada.Strings.Unbounded.Unbounded_String;
      S3_SSO_Account_Id : Ada.Strings.Unbounded.Unbounded_String;
      S3_SSO_Role_Name : Ada.Strings.Unbounded.Unbounded_String;
      S3_Access_Key    : Ada.Strings.Unbounded.Unbounded_String;
      S3_Secret_Key    : Ada.Strings.Unbounded.Unbounded_String;
      S3_Session_Token : Ada.Strings.Unbounded.Unbounded_String;
      S3_Virtual_Hosted_Style : Boolean := False;
      S3_Server_Side_Encryption : Ada.Strings.Unbounded.Unbounded_String;
      S3_SSE_KMS_Key_Id : Ada.Strings.Unbounded.Unbounded_String;
      S3_ACL           : Ada.Strings.Unbounded.Unbounded_String;
      S3_Storage_Class : Ada.Strings.Unbounded.Unbounded_String;
      S3_Tagging       : Ada.Strings.Unbounded.Unbounded_String;
      S3_Metadata_Name : Ada.Strings.Unbounded.Unbounded_String;
      S3_Metadata_Value : Ada.Strings.Unbounded.Unbounded_String;
      S3_Cache_Control : Ada.Strings.Unbounded.Unbounded_String;
      S3_Content_Disposition : Ada.Strings.Unbounded.Unbounded_String;
      S3_Content_Encoding : Ada.Strings.Unbounded.Unbounded_String;
      S3_Object_Lock_Mode : Ada.Strings.Unbounded.Unbounded_String;
      S3_Object_Lock_Retain_Until : Ada.Strings.Unbounded.Unbounded_String;
      S3_Object_Lock_Legal_Hold : Ada.Strings.Unbounded.Unbounded_String;
      S3_Multipart_Threshold : Natural := 64 * 1024 * 1024;
      S3_Multipart_Part_Size : Natural := 8 * 1024 * 1024;
      Google_Drive_API_Base : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Upload_Base : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Access_Token : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Access_Token_File : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Refresh_Token : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Client_Id : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Client_Secret : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Token_URI : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Supports_All_Drives : Boolean := False;
      Google_Drive_Drive_Id : Ada.Strings.Unbounded.Unbounded_String;
      Google_Drive_Resumable_Threshold : Natural := 8 * 1024 * 1024;
      PCloud_API_Base : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Region : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Access_Token : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Access_Token_File : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Token_Cache_File : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Refresh_Token : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Client_Id : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Client_Secret : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Token_URI : Ada.Strings.Unbounded.Unbounded_String;
      PCloud_Large_Upload_Threshold : Natural := 64 * 1024 * 1024;
      PCloud_Upload_Progress : Boolean := True;
      PCloud_Poll_Progress : Boolean := False;
      PCloud_Check_Quota : Boolean := True;
      PCloud_Create_Parents : Boolean := True;
      PCloud_Clean_Recursive : Boolean := False;
      Proton_Drive_API_Base : Ada.Strings.Unbounded.Unbounded_String;
      Proton_Drive_App_Version : Ada.Strings.Unbounded.Unbounded_String;
      Proton_Drive_Session_File : Ada.Strings.Unbounded.Unbounded_String;
      Proton_Drive_User_Address : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Remote_Location is record
      Original_URL : Ada.Strings.Unbounded.Unbounded_String;
      Kind         : Transport_Kind := Transport_Unsupported;
      Namespace    : Ada.Strings.Unbounded.Unbounded_String;
      Object_Name  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Archive_Metadata is record
      Archive_Id : Ada.Strings.Unbounded.Unbounded_String;
      Size       : Interfaces.Unsigned_64 := 0;
      Crc32         : Interfaces.Unsigned_32 := 0;
      Has_Timestamp : Boolean := False;
      Timestamp     : Ada.Calendar.Time := Ada.Calendar.Time_Of (2000, 1, 1);
      Managed       : Boolean := False;
      Partial       : Boolean := False;
   end record;

   package Archive_Metadata_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Archive_Metadata);

   type Sync_Step is record
      Action   : Sync_Action := Sync_Keep;
      Archive  : Archive_Metadata;
      Reason   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Sync_Step_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Sync_Step);

   type Transfer_Report is record
      Status        : Remote_Status := Remote_Invalid_URL;
      Transport     : Transport_Kind := Transport_Unsupported;
      Remote_URL    : Ada.Strings.Unbounded.Unbounded_String;
      Local_Path    : Ada.Strings.Unbounded.Unbounded_String;
      Remote_Object : Ada.Strings.Unbounded.Unbounded_String;
      Size          : Interfaces.Unsigned_64 := 0;
      Crc32         : Interfaces.Unsigned_32 := 0;
      Atomic        : Boolean := False;
      Resumed       : Boolean := False;
      Verified      : Boolean := False;
      Retried       : Natural := 0;
      PCloud_Progress_Samples : Natural := 0;
   end record;

   function Status_Text (Status : Remote_Status) return String;

   function Exchange_PCloud_Authorization_Code
     (Client_Id    : String;
      Client_Secret : String;
      Code         : String;
      Redirect_URI : String;
      API_Base     : String;
      Token_JSON   : out Ada.Strings.Unbounded.Unbounded_String;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Parse_URL
     (URL        : String;
      Local_Path : String;
      Location   : out Remote_Location;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Archive_Id_For_Path (Path : String) return String;

   function Upload_Archive
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Report     : out Transfer_Report;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Download_Archive
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Report     : out Transfer_Report;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Verify_Remote_Archive
     (URL        : String;
      Local_Path : String;
      Report     : out Transfer_Report;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Verify_Remote_Archive
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Report     : out Transfer_Report;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Delete_Remote_Object
     (URL        : String;
      Local_Path : String;
      Object_Name : String;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Delete_Remote_Object
     (URL        : String;
      Local_Path : String;
      Object_Name : String;
      Options    : Remote_Options;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Cleanup_Remote_Temporary_Objects
     (URL        : String;
      Options    : Remote_Options;
      Deleted    : out Natural;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Check_PCloud_Remote
     (URL        : String;
      Options    : Remote_Options;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Read_Inventory
     (URL        : String;
      Local_Path : String;
      Inventory  : out Archive_Metadata_Vectors.Vector;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Read_Inventory
     (URL        : String;
      Local_Path : String;
      Options    : Remote_Options;
      Inventory  : out Archive_Metadata_Vectors.Vector;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Presign_S3_URL
     (URL             : String;
      Local_Path      : String;
      Options         : Remote_Options;
      Method          : S3_Presign_Method;
      Expires_Seconds : Natural;
      Presigned_URL   : out Ada.Strings.Unbounded.Unbounded_String;
      Diagnostic      : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   function Build_Sync_Plan
     (Local_Path : String;
      Remote_Set : Archive_Metadata_Vectors.Vector;
      Plan        : out Sync_Step_Vectors.Vector;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String)
      return Remote_Status;

   procedure Build_JSON_Report
     (Report : Transfer_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_Sync_JSON_Report
     (Plan : Sync_Step_Vectors.Vector;
      Text : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_Sync_Human_Report
     (Plan : Sync_Step_Vectors.Vector;
      Text : out Ada.Strings.Unbounded.Unbounded_String);
end Backup.Remote;
