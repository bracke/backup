package body Backup.Remote_Sync_Syntax
  with SPARK_Mode => On
is
   function Inventory_Item_Action
     (Partial       : Boolean;
      Same_Archive  : Boolean;
      Same_Metadata : Boolean) return Backup.Remote.Sync_Action
   is
   begin
      if Partial then
         return Backup.Remote.Sync_Delete_Remote;
      elsif Same_Archive and then Same_Metadata then
         return Backup.Remote.Sync_Keep;
      elsif Same_Archive then
         return Backup.Remote.Sync_Upload;
      else
         return Backup.Remote.Sync_Keep;
      end if;
   end Inventory_Item_Action;

   function Missing_Local_Action return Backup.Remote.Sync_Action is
   begin
      return Backup.Remote.Sync_Upload;
   end Missing_Local_Action;
end Backup.Remote_Sync_Syntax;
