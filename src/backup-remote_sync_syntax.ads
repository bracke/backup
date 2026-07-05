with Backup.Remote;

package Backup.Remote_Sync_Syntax
  with SPARK_Mode => On
is
   function Inventory_Item_Action
     (Partial       : Boolean;
      Same_Archive  : Boolean;
      Same_Metadata : Boolean) return Backup.Remote.Sync_Action;

   function Missing_Local_Action return Backup.Remote.Sync_Action;
end Backup.Remote_Sync_Syntax;
