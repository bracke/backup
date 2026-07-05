with Backup.Restore;

package Backup.Restore_Syntax
  with SPARK_Mode => On
is
   function Status_Text (Status : Backup.Restore.Restore_Status) return String;

   function Action_Name (Action : Backup.Restore.Restore_Action) return String;

   function Report_Action
     (Action  : Backup.Restore.Restore_Action;
      Dry_Run : Boolean) return Backup.Restore.Restore_Action;

   function Path_Matches_Filter
     (Filter       : String;
      Archive_Path : String) return Boolean;

   function Symlink_Target_Is_Safe (Target : String) return Boolean;
end Backup.Restore_Syntax;
