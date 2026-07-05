with Interfaces;

with Backup.Incremental;

package Backup.Incremental_Syntax
  with SPARK_Mode => On
is
   function Status_Text
     (Status : Backup.Incremental.Plan_Status) return String;

   function Decision_Name
     (Decision : Backup.Incremental.Decision_Kind) return String;

   function Kind_Name
     (Kind : Backup.Incremental.Plan_Entry_Kind) return String;

   function Method_Name (Method : Interfaces.Unsigned_16) return String;
end Backup.Incremental_Syntax;
