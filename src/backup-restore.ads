with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Backup.CLI;
with Backup.Verify;

package Backup.Restore is
   type Restore_Status is
     (Restore_Ok,
      Restore_Verify_Failed,
      Restore_Target_Error,
      Restore_Existing_Path,
      Restore_Unsafe_Symlink,
      Restore_Unsupported_Symlink,
      Restore_Read_Error,
      Restore_Write_Error,
      Restore_Deflate_Invalid,
      Restore_Crc_Mismatch,
      Restore_Internal_Error);

   type Restore_Action is
     (Action_Restore,
      Action_Skip,
      Action_Reject,
      Action_Would_Restore,
      Action_Would_Skip,
      Action_Would_Reject);

   type Restore_Item is record
      Archive_Path : Ada.Strings.Unbounded.Unbounded_String;
      Kind         : Backup.Verify.Entry_Kind := Backup.Verify.Entry_File;
      Action       : Restore_Action := Action_Restore;
      Destination  : Ada.Strings.Unbounded.Unbounded_String;
      Reason       : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Item_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Restore_Item);

   type Restore_Report is record
      Status       : Restore_Status := Restore_Internal_Error;
      Dry_Run      : Boolean := False;
      Archive_Path : Ada.Strings.Unbounded.Unbounded_String;
      Output_Dir   : Ada.Strings.Unbounded.Unbounded_String;
      Items        : Item_Vectors.Vector;
      Verify       : Backup.Verify.Verification_Report;
   end record;

   function Status_Text (Status : Restore_Status) return String;

   function Extract_Archive
     (Config     : Backup.CLI.Configuration;
      Report     : out Restore_Report;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Restore_Status;

   procedure Build_Human_Report
     (Report : Restore_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_JSON_Report
     (Report : Restore_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);
end Backup.Restore;
