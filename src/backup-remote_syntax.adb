package body Backup.Remote_Syntax
  with SPARK_Mode => On
is
   use type Backup.Remote.Transport_Kind;
   use type Backup.Remote.Upload_Mode;
   function Transport_Name (Kind : Backup.Remote.Transport_Kind) return String is
   begin
      case Kind is
         when Backup.Remote.Transport_File =>
            return "file";
         when Backup.Remote.Transport_HTTP =>
            return "http";
         when Backup.Remote.Transport_HTTPS =>
            return "https";
         when Backup.Remote.Transport_S3 =>
            return "s3";
         when Backup.Remote.Transport_Google_Drive =>
            return "gdrive";
         when Backup.Remote.Transport_PCloud =>
            return "pcloud";
         when Backup.Remote.Transport_Proton_Drive =>
            return "protondrive";
         when Backup.Remote.Transport_SSH =>
            return "ssh";
         when Backup.Remote.Transport_Unsupported =>
            return "unsupported";
      end case;
   end Transport_Name;

   function Action_Name (Action : Backup.Remote.Sync_Action) return String is
   begin
      case Action is
         when Backup.Remote.Sync_Keep =>
            return "keep";
         when Backup.Remote.Sync_Upload =>
            return "upload";
         when Backup.Remote.Sync_Download =>
            return "download";
         when Backup.Remote.Sync_Delete_Remote =>
            return "delete_remote";
      end case;
   end Action_Name;

   function Status_Text (Status : Backup.Remote.Remote_Status) return String is
   begin
      case Status is
         when Backup.Remote.Remote_Ok =>
            return "remote operation completed";
         when Backup.Remote.Remote_Invalid_URL =>
            return "invalid remote URL";
         when Backup.Remote.Remote_Unsupported_Transport =>
            return "unsupported remote transport";
         when Backup.Remote.Remote_Open_Failed =>
            return "could not open remote object";
         when Backup.Remote.Remote_Read_Failed =>
            return "could not read remote object";
         when Backup.Remote.Remote_Write_Failed =>
            return "could not write remote object";
         when Backup.Remote.Remote_Copy_Failed =>
            return "could not copy remote object";
         when Backup.Remote.Remote_Verify_Failed =>
            return "remote verification failed";
         when Backup.Remote.Remote_Metadata_Mismatch =>
            return "remote metadata does not match local archive";
         when Backup.Remote.Remote_Authentication_Failed =>
            return "remote authentication failed";
         when Backup.Remote.Remote_Timeout =>
            return "remote operation timed out";
         when Backup.Remote.Remote_Interrupted =>
            return "remote operation interrupted";
         when Backup.Remote.Remote_Unsafe_Namespace =>
            return "remote namespace is unsafe";
         when Backup.Remote.Remote_Not_Found =>
            return "remote object was not found";
         when Backup.Remote.Remote_Partial_Object =>
            return "partial remote object detected";
         when Backup.Remote.Remote_Delete_Refused =>
            return "remote deletion was refused";
         when Backup.Remote.Remote_Encryption_Required =>
            return "remote operation requires an encrypted archive";
      end case;
   end Status_Text;

   function HTTP_Status_OK
     (Code       : Natural;
      For_Upload : Boolean := False) return Boolean
   is
   begin
      if For_Upload then
         return Code = 200 or else Code = 201 or else Code = 204;
      else
         return Code = 200;
      end if;
   end HTTP_Status_OK;

   function Is_HTTP_Transport
     (Kind : Backup.Remote.Transport_Kind) return Boolean
   is
   begin
      return Kind = Backup.Remote.Transport_HTTP
        or else Kind = Backup.Remote.Transport_HTTPS
        or else Kind = Backup.Remote.Transport_S3
        or else Kind = Backup.Remote.Transport_Google_Drive
        or else Kind = Backup.Remote.Transport_PCloud
        or else Kind = Backup.Remote.Transport_Proton_Drive;
   end Is_HTTP_Transport;

   function Is_Unsupported_Transfer_Transport
     (Kind : Backup.Remote.Transport_Kind) return Boolean
   is
   begin
      return Kind = Backup.Remote.Transport_Unsupported;
   end Is_Unsupported_Transfer_Transport;

   function Supports_HTTP_Index
     (Kind : Backup.Remote.Transport_Kind) return Boolean
   is
   begin
      return Is_HTTP_Transport (Kind);
   end Supports_HTTP_Index;

   function Resume_Upload_Enabled
     (Mode : Backup.Remote.Upload_Mode) return Boolean
   is
   begin
      return Mode = Backup.Remote.Upload_Resume_If_Supported;
   end Resume_Upload_Enabled;

   function Timeout_Precheck_Status
     (Timeout_Seconds : Natural) return Backup.Remote.Remote_Status
   is
   begin
      if Timeout_Seconds = 0 then
         return Backup.Remote.Remote_Timeout;
      else
         return Backup.Remote.Remote_Ok;
      end if;
   end Timeout_Precheck_Status;

   function Retry_Available
     (Attempt     : Natural;
      Retry_Count : Natural) return Boolean
   is
   begin
      return Attempt < Retry_Count;
   end Retry_Available;

   function Attempts_Exhausted
     (Attempt     : Natural;
      Retry_Count : Natural) return Boolean
   is
   begin
      return Attempt >= Retry_Count;
   end Attempts_Exhausted;
end Backup.Remote_Syntax;
