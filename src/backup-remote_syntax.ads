with Backup.Remote;

package Backup.Remote_Syntax
  with SPARK_Mode => On
is
   function Transport_Name (Kind : Backup.Remote.Transport_Kind) return String;

   function Action_Name (Action : Backup.Remote.Sync_Action) return String;

   function Status_Text (Status : Backup.Remote.Remote_Status) return String;

   function HTTP_Status_OK
     (Code       : Natural;
      For_Upload : Boolean := False) return Boolean;

   function Is_HTTP_Transport
     (Kind : Backup.Remote.Transport_Kind) return Boolean;

   function Is_Unsupported_Transfer_Transport
     (Kind : Backup.Remote.Transport_Kind) return Boolean;

   function Supports_HTTP_Index
     (Kind : Backup.Remote.Transport_Kind) return Boolean;

   function Resume_Upload_Enabled
     (Mode : Backup.Remote.Upload_Mode) return Boolean;

   function Timeout_Precheck_Status
     (Timeout_Seconds : Natural) return Backup.Remote.Remote_Status;

   function Retry_Available
     (Attempt     : Natural;
      Retry_Count : Natural) return Boolean;

   function Attempts_Exhausted
     (Attempt     : Natural;
      Retry_Count : Natural) return Boolean;
end Backup.Remote_Syntax;
