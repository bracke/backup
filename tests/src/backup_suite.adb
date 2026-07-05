with AUnit;
with AUnit.Test_Cases;
with Backup_CLI_Tests;
with Backup_Ignore_Tests;
with Backup_Jobs_Tests;
with Backup_Legacy_Scripts_Tests;
with Backup_Paths_Tests;
with Backup_Catalog_Tests;
with Backup_Compression_Tests;
with Backup_Encryption_Tests;
with Backup_Incremental_Tests;
with Backup_Manifest_Tests;
with Backup_Remote_Tests;
with Backup_Restore_Tests;
with Backup_Scanner_Tests;
with Backup_Verify_Tests;
with Backup_Workflow_Tests;
with Backup_Zip_Tests;

package body Backup_Suite is
   pragma Warnings (Off, "use of an anonymous access type allocator");

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Test_Case) return AUnit.Message_String;
   overriding procedure Register_Tests (T : in out Test_Case);

   procedure Run_Paths (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_CLI (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Ignore (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Jobs (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Catalog (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Compression (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Encryption (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Incremental (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Manifest (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Remote (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Restore (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Scanner (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Verify (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Workflow (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Zip (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Run_Legacy_Scripts (T : in out AUnit.Test_Cases.Test_Case'Class);

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Backup");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases;
   begin
      Registration.Register_Routine (T, Run_Paths'Access, "paths");
      Registration.Register_Routine (T, Run_CLI'Access, "CLI");
      Registration.Register_Routine (T, Run_Ignore'Access, "ignore rules");
      Registration.Register_Routine (T, Run_Jobs'Access, "jobs");
      Registration.Register_Routine (T, Run_Catalog'Access, "catalog");
      Registration.Register_Routine (T, Run_Compression'Access, "compression");
      Registration.Register_Routine (T, Run_Encryption'Access, "encryption");
      Registration.Register_Routine (T, Run_Incremental'Access, "incremental");
      Registration.Register_Routine (T, Run_Manifest'Access, "manifest");
      Registration.Register_Routine (T, Run_Remote'Access, "remote");
      Registration.Register_Routine (T, Run_Restore'Access, "restore");
      Registration.Register_Routine (T, Run_Scanner'Access, "scanner");
      Registration.Register_Routine (T, Run_Verify'Access, "verify");
      Registration.Register_Routine (T, Run_Workflow'Access, "workflow");
      Registration.Register_Routine (T, Run_Zip'Access, "ZIP");
      Registration.Register_Routine
        (T, Run_Legacy_Scripts'Access, "legacy script audit");
   end Register_Tests;

   procedure Run_Paths (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Paths_Tests;
   end Run_Paths;

   procedure Run_CLI (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_CLI_Tests;
   end Run_CLI;

   procedure Run_Ignore (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Ignore_Tests;
   end Run_Ignore;

   procedure Run_Jobs (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Jobs_Tests;
   end Run_Jobs;

   procedure Run_Catalog (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Catalog_Tests;
   end Run_Catalog;

   procedure Run_Compression (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Compression_Tests;
   end Run_Compression;

   procedure Run_Encryption (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Encryption_Tests;
   end Run_Encryption;

   procedure Run_Incremental (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Incremental_Tests;
   end Run_Incremental;

   procedure Run_Manifest (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Manifest_Tests;
   end Run_Manifest;

   procedure Run_Remote (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Remote_Tests;
   end Run_Remote;

   procedure Run_Restore (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Restore_Tests;
   end Run_Restore;

   procedure Run_Scanner (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Scanner_Tests;
   end Run_Scanner;

   procedure Run_Verify (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Verify_Tests;
   end Run_Verify;

   procedure Run_Workflow (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Workflow_Tests;
   end Run_Workflow;

   procedure Run_Zip (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Backup_Zip_Tests;
   end Run_Zip;

   procedure Run_Legacy_Scripts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Backup_Legacy_Scripts_Tests;
   end Run_Legacy_Scripts;

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite :=
        new AUnit.Test_Suites.Test_Suite;
   begin
      Result.Add_Test (new Test_Case);
      return Result;
   end Suite;
end Backup_Suite;
