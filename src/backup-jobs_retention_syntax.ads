with Backup.Jobs;

package Backup.Jobs_Retention_Syntax
  with SPARK_Mode => On
is
   function Has_Keep_Target
     (Policy : Backup.Jobs.Retention_Policy) return Boolean;

   function Count_Policy_Deletes
     (Zero_Based_Index : Natural;
      Keep_Count       : Natural) return Boolean;

   function Can_Keep_Daily
     (Daily_Kept : Natural;
      Daily_Limit : Natural) return Boolean;

   function Can_Keep_Weekly
     (Weekly_Kept  : Natural;
      Weekly_Limit : Natural;
      Bucket_Seen  : Boolean) return Boolean;

   function Can_Keep_Monthly
     (Monthly_Kept  : Natural;
      Monthly_Limit : Natural;
      Bucket_Seen   : Boolean) return Boolean;
end Backup.Jobs_Retention_Syntax;
