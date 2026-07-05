with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Proton_Drive is
   --  Ada SDK layer for Proton Drive integration.
   --
   --  This package owns Proton Drive client configuration, validation, and
   --  operation contracts. Direct Proton API mode is gated behind explicit
   --  session-descriptor opt-in; otherwise operation endpoint templates are
   --  required so the backend cannot silently bypass Proton-compatible crypto.

   type SDK_Status is
     (SDK_Ok,
      SDK_Invalid_Config,
      SDK_Provider_Missing,
      SDK_Crypto_Unavailable,
      SDK_Operations_Unavailable,
      SDK_HTTP_Failed,
      SDK_Not_Found,
      SDK_Rate_Limited);

   type Node_Kind is (Node_File, Node_Folder);

   type Client_Config is record
      App_Version  : Ada.Strings.Unbounded.Unbounded_String;
      API_Base     : Ada.Strings.Unbounded.Unbounded_String;
      Session_File : Ada.Strings.Unbounded.Unbounded_String;
      User_Address : Ada.Strings.Unbounded.Unbounded_String;
      Share_Id     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Client is private;

   type Session_Info is record
      UID           : Ada.Strings.Unbounded.Unbounded_String;
      Access_Token  : Ada.Strings.Unbounded.Unbounded_String;
      Refresh_Token : Ada.Strings.Unbounded.Unbounded_String;
      Address_Id    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type User_Address_Info is record
      Email      : Ada.Strings.Unbounded.Unbounded_String;
      Address_Id : Ada.Strings.Unbounded.Unbounded_String;
      Key_Id     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Crypto_Context is record
      Address_Key_Fingerprint  : Ada.Strings.Unbounded.Unbounded_String;
      Metadata_Key_Id          : Ada.Strings.Unbounded.Unbounded_String;
      Metadata_Key_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Node_Key_Fingerprint     : Ada.Strings.Unbounded.Unbounded_String;
      Content_Key_Fingerprint  : Ada.Strings.Unbounded.Unbounded_String;
      Content_Tag_Key_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Metadata_Packet is record
      Canonical_Text : Ada.Strings.Unbounded.Unbounded_String;
      Authentication_Tag : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Upload_Plan is record
      Total_Size        : Interfaces.Unsigned_64 := 0;
      Chunk_Size        : Interfaces.Unsigned_64 := 0;
      Part_Count        : Natural := 0;
      Requires_Chunking : Boolean := False;
   end record;

   type Auth_Request is record
      Username       : Ada.Strings.Unbounded.Unbounded_String;
      Password_Proof : Ada.Strings.Unbounded.Unbounded_String;
      MFA_Code       : Ada.Strings.Unbounded.Unbounded_String;
      Session_Label  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Revision_Info is record
      Revision_Id : Ada.Strings.Unbounded.Unbounded_String;
      Created_At  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Node_Metadata is record
      Node_Id : Ada.Strings.Unbounded.Unbounded_String;
      Name    : Ada.Strings.Unbounded.Unbounded_String;
      Kind    : Node_Kind := Node_File;
      Size    : Interfaces.Unsigned_64 := 0;
   end record;

   package Node_Metadata_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Node_Metadata);

   type Event_Cursor is record
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Event_Batch is record
      Cursor : Event_Cursor;
      Nodes  : Node_Metadata_Vectors.Vector;
   end record;

   function Default_API_Base return String;

   function Status_Text (Status : SDK_Status) return String;

   function SDK_Status_Text return String;

   function Is_App_Version_Valid (Value : String) return Boolean;

   function Is_Official_API_Base (Value : String) return Boolean;

   function Load_Session
     (Path       : String;
      Session    : out Session_Info;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Resolve_User_Address
     (Config     : Client_Config;
      Session    : Session_Info;
      Address    : out User_Address_Info;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Load_Crypto_Context
     (Config     : Client_Config;
      Session    : Session_Info;
      Address    : User_Address_Info;
      Context    : out Crypto_Context;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Supports_First_Party_Key_Unlock return Boolean;

   function First_Party_Key_Unlock_Status return String;

   function Key_Unlock_Envelope
     (Passphrase : String;
      Salt       : String;
      Rounds     : Interfaces.Unsigned_32;
      Name       : String;
      Plaintext  : String) return String;

   function Open_Key_Unlock_Envelope
     (Passphrase : String;
      Salt       : String;
      Rounds     : Interfaces.Unsigned_32;
      Name       : String;
      Envelope   : String;
      Plaintext  : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   function Metadata_Canonical_Text
     (Name : String;
      Kind : Node_Kind;
      Size : Interfaces.Unsigned_64) return String;

   function Metadata_Authentication_Tag
     (Context : Crypto_Context;
      Metadata : String) return String;

   function Content_Block_Tag
     (Context     : Crypto_Context;
      Remote_Path : String;
      Part_Number : Positive;
      Offset      : Interfaces.Unsigned_64;
      Payload     : String) return String;

   function Tagged_Content_Block
     (Context     : Crypto_Context;
      Remote_Path : String;
      Part_Number : Positive;
      Offset      : Interfaces.Unsigned_64;
      Payload     : String) return String;

   function Streaming_Content_Block
     (Context     : Crypto_Context;
      Remote_Path : String;
      Part_Number : Positive;
      Offset      : Interfaces.Unsigned_64;
      Payload     : String) return String;

   function Open_Streaming_Content_Block
     (Context     : Crypto_Context;
      Remote_Path : String;
      Body_Text   : String;
      Payload     : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   function Build_Metadata_Packet
     (Context : Crypto_Context;
      Name    : String;
      Kind    : Node_Kind;
      Size    : Interfaces.Unsigned_64) return Metadata_Packet;

   function Metadata_Envelope
     (Context : Crypto_Context;
      Packet  : Metadata_Packet) return String;

   function Encrypted_Metadata_Envelope
     (Context : Crypto_Context;
      Packet  : Metadata_Packet) return String;

   function Open_Encrypted_Metadata_Envelope
     (Context  : Crypto_Context;
      Envelope : String;
      Metadata : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   function Auth_Request_Envelope (Request : Auth_Request) return String;

   function Wire_Contract (Config : Client_Config) return String;

   function Wire_Response_Valid
     (Operation : String;
      Response  : String) return Boolean;

   function Has_Operation_Provider (Config : Client_Config) return Boolean;

   function Has_Large_Upload_Provider (Config : Client_Config) return Boolean;

   function Has_Folder_Provider (Config : Client_Config) return Boolean;

   function Has_Conflict_Provider (Config : Client_Config) return Boolean;

   function Has_Resume_Provider (Config : Client_Config) return Boolean;

   function Has_Trash_Provider (Config : Client_Config) return Boolean;

   function Has_Revision_Provider (Config : Client_Config) return Boolean;

   function Has_Event_Replay_Provider (Config : Client_Config) return Boolean;

   function Supports_Auth_Provider (Config : Client_Config) return Boolean;

   function Supports_Login_Provider (Config : Client_Config) return Boolean;

   function Supports_Native_Auth_Flow (Config : Client_Config) return Boolean;

   function Has_Wire_Contract (Config : Client_Config) return Boolean;

   function Supports_Live_Compatibility_Check (Config : Client_Config) return Boolean;

   function Requires_Chunked_Upload
     (Config : Client_Config;
      Size   : Interfaces.Unsigned_64) return Boolean;

   function Plan_Upload
     (Config : Client_Config;
      Size   : Interfaces.Unsigned_64) return Upload_Plan;

   function Supports_Streaming_Transfer (Config : Client_Config) return Boolean;

   function Refresh_Session
     (Config     : Client_Config;
      Session    : Session_Info;
      Updated    : out Session_Info;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Start_Login
     (Config     : Client_Config;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Complete_MFA
     (Config     : Client_Config;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Bootstrap_Session
     (Config     : Client_Config;
      Request    : Auth_Request;
      Session    : out Session_Info;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Login_And_Save_Session
     (Config     : Client_Config;
      Request    : Auth_Request;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Validate_Config
     (Config     : Client_Config;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Create
     (Config     : Client_Config;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String) return Client;

   function Status (Item : Client) return SDK_Status;

   function Ready (Item : Client) return Boolean;

   function Diagnostic (Item : Client) return String;

   function Session (Item : Client) return Session_Info;

   function User_Address (Item : Client) return User_Address_Info;

   function Crypto (Item : Client) return Crypto_Context;

   function Has_Crypto_Context (Item : Client) return Boolean;

   function Supports_Encrypted_Operations (Item : Client) return Boolean;

   function Upload_File
     (Item        : Client;
      Parent_Path : String;
      Local_Path  : String;
      Remote_Name : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Download_File
     (Item        : Client;
      Remote_Path : String;
      Local_Path  : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Delete_Node
     (Item        : Client;
      Remote_Path : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Create_Folder
     (Item        : Client;
      Parent_Path : String;
      Folder_Name : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Trash_Node
     (Item        : Client;
      Remote_Path : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Resolve_Conflict
     (Item        : Client;
      Remote_Path : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Latest_Revision
     (Item        : Client;
      Remote_Path : String;
      Revision    : out Revision_Info;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Resume_Upload
     (Item        : Client;
      Parent_Path : String;
      Remote_Name : String;
      Upload_Id   : String;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function List_Children
     (Item        : Client;
      Remote_Path : String;
      Nodes       : out Node_Metadata_Vectors.Vector;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

   function Get_Events
     (Item        : Client;
      After       : Event_Cursor;
      Batch       : out Event_Batch;
      Diagnostic  : out Ada.Strings.Unbounded.Unbounded_String) return SDK_Status;

private
   type Client is record
      Config     : Client_Config;
      State      : SDK_Status := SDK_Invalid_Config;
      Detail     : Ada.Strings.Unbounded.Unbounded_String;
      Session    : Session_Info;
      Address    : User_Address_Info;
      Crypto     : Crypto_Context;
   end record;
end Proton_Drive;
