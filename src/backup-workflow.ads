with Ada.Strings.Unbounded;

with Backup.CLI;

package Backup.Workflow is
   type Execution_Status is
     (Execution_Ok,
      Execution_Unsupported_Option,
      Execution_Size_Limit_Exceeded,
      Execution_Scan_Failed,
      Execution_Zip_Failed,
      Execution_Verify_Failed,
      Execution_Restore_Failed,
      Execution_Incremental_Failed,
      Execution_Encryption_Failed,
      Execution_Remote_Failed,
      Execution_Catalog_Failed);

   function Execute
     (Config     : Backup.CLI.Configuration;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Execution_Status;
end Backup.Workflow;
