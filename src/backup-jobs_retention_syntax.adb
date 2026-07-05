package body Backup.Jobs_Retention_Syntax
  with SPARK_Mode => On
is
   function Has_Keep_Target
     (Policy : Backup.Jobs.Retention_Policy) return Boolean
   is
   begin
      case Policy.Kind is
         when Backup.Jobs.Retention_None =>
            return True;
         when Backup.Jobs.Retention_Count =>
            return Policy.Keep_Count > 0;
         when Backup.Jobs.Retention_Age_Days =>
            return True;
         when Backup.Jobs.Retention_Tiered =>
            return Policy.Daily > 0
              or else Policy.Weekly > 0
              or else Policy.Monthly > 0;
      end case;
   end Has_Keep_Target;

   function Count_Policy_Deletes
     (Zero_Based_Index : Natural;
      Keep_Count       : Natural) return Boolean
   is
   begin
      return Zero_Based_Index >= Keep_Count;
   end Count_Policy_Deletes;

   function Can_Keep_Daily
     (Daily_Kept : Natural;
      Daily_Limit : Natural) return Boolean
   is
   begin
      return Daily_Kept < Daily_Limit;
   end Can_Keep_Daily;

   function Can_Keep_Weekly
     (Weekly_Kept  : Natural;
      Weekly_Limit : Natural;
      Bucket_Seen  : Boolean) return Boolean
   is
   begin
      return Weekly_Kept < Weekly_Limit and then not Bucket_Seen;
   end Can_Keep_Weekly;

   function Can_Keep_Monthly
     (Monthly_Kept  : Natural;
      Monthly_Limit : Natural;
      Bucket_Seen   : Boolean) return Boolean
   is
   begin
      return Monthly_Kept < Monthly_Limit and then not Bucket_Seen;
   end Can_Keep_Monthly;
end Backup.Jobs_Retention_Syntax;
