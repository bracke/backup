with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Project_Tools.Files;
with Project_Tools.Processes;
with Project_Tools.Release_Checks;
with Project_Tools.Tree_Checks;

procedure Check_All is

   Root : constant String := Ada.Directories.Full_Name (".");
   Install_Prefix : constant String := "/tmp/backup-install-smoke";
   Package_Prefix : constant String := "/tmp/backup-package-smoke";
   Alr  : constant String := Project_Tools.Processes.Locate_Command ("alr");
   Env  : constant String := Project_Tools.Processes.Locate_Command ("env");
   Checks : constant Project_Tools.Release_Checks.Checker :=
     Project_Tools.Release_Checks.Create (Root);

   procedure Run
     (Label   : String;
      Dir     : String;
      Program : String;
      Args    : GNAT.OS_Lib.Argument_List;
      Quiet   : Boolean := False)
      renames Project_Tools.Release_Checks.Run;


   procedure Require_File (Relative_Path : String) is
   begin
      Project_Tools.Release_Checks.Require_File (Checks, Relative_Path);
   end Require_File;

   procedure Require_Directory (Relative_Path : String) is
   begin
      Project_Tools.Release_Checks.Require_Directory (Checks, Relative_Path);
   end Require_Directory;


   procedure Require_Absolute_File (Path : String) is
   begin
      Project_Tools.Release_Checks.Require_Absolute_File (Path);
   end Require_Absolute_File;

   procedure Require_Absolute_Directory (Path : String) is
   begin
      Project_Tools.Release_Checks.Require_Absolute_Directory (Path);
   end Require_Absolute_Directory;


   procedure Require_Text (Relative_Path : String; Text : String) is
   begin
      Project_Tools.Release_Checks.Require_Text (Checks, Relative_Path, Text);
   end Require_Text;

   procedure Require_Alire_GNAT_15 is
      Output : Unbounded_String;
      Status : Integer;
   begin
      Status :=
        Project_Tools.Processes.Run_Status
          (Label   => "GNAT 15 version check",
           Dir     => Root,
           Program => Alr,
           Args    =>
             [1 => new String'("exec"),
              2 => new String'("--"),
              3 => new String'("gnatls"),
              4 => new String'("--version")],
           Output  => Output,
           Quiet   => True);

      if Status /= 0 then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "could not run `alr exec -- gnatls --version`");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      elsif Ada.Strings.Fixed.Index (To_String (Output), "GNATLS 15.") = 0 then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "wrong Ada compiler: backup validation must use Alire GNAT 15; got: "
            & To_String (Output));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Require_Alire_GNAT_15;

begin
   if not Project_Tools.Files.File_Exists (Root & "/backup.gpr") then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "check_all must be run from the backup root");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Project_Tools.Processes.Require_Command
     ("alr", "alr executable not found on PATH");
   Require_Alire_GNAT_15;
   Project_Tools.Processes.Require_Command
     ("tar", "tar executable not found on PATH");

   Require_File ("LICENSE");
   Require_File ("README.md");
   Require_File ("AGENTS.md");
   Require_File ("backup_spark.gpr");
   Require_File ("docs/RELEASE.md");
   Require_File ("docs/CLI_SURFACE.md");
   Require_File ("docs/CLI_COMPATIBILITY.md");
   Require_File ("docs/SPARK.md");
   Require_File ("docs/TESTING.md");
   Require_File ("docs/LEGACY_TESTS.md");
   Require_File ("docs/SYMLINKS.md");
   Require_File ("docs/PORTABILITY.md");
   Require_File ("docs/IDRIVE_E2.md");
   Require_File ("docs/PCLOUD.md");
   Require_File ("docs/PROTON_DRIVE.md");
   Require_File ("docs/history/PHASE22_COMPLETENESS.md");
   Require_File (".github/workflows/ci.yml");
   Require_File ("share/examples/backup/example.conf");
   Require_File ("share/completions/_backup");
   Require_File ("share/completions/backup.bash");
   Require_File ("share/completions/backup.fish");
   Require_File ("share/completions/backup.ps1");
   Require_File ("share/man/man1/backup.1");
   Require_File ("share/backup/messages.catalog");
   Require_File ("src/backup-messages.adb");
   Require_File ("src/backup-messages.ads");
   Require_File ("src/backup-cli_surface.ads");
   Require_File ("src/backup-cli_surface.adb");
   Require_File ("tests/src/backup_legacy_scripts_tests.adb");
   Require_File ("tools/src/package_release.adb");
   Require_File ("tools/src/check_bash_completion.adb");
   Require_File ("tools/src/check_fish_completion.adb");
   Require_File ("tools/src/check_zsh_completion.adb");
   Require_File ("tools/src/check_powershell_completion.adb");
   Require_File ("tools/src/check_s3_compatibility.adb");
   Require_File ("tools/src/check_google_drive_compatibility.adb");
   Require_File ("tools/src/check_pcloud_compatibility.adb");
   Require_File ("tools/src/check_proton_drive_compatibility.adb");
   Require_File ("tools/src/generate_manpage.adb");
   Require_File ("tools/src/check_manpage.adb");
   Require_File ("tools/cli_surface.conf");
   Require_File ("tools/src/generate_cli_surface.adb");
   Require_File ("tools/src/check_cli_surface.adb");
   Require_Directory ("src");
   Require_Directory ("src/unix");
   Require_Directory ("src/windows");
   Require_Directory ("tests/src");
   Require_Directory ("tools/src");
   Require_Directory ("docs/history");
   Require_Directory ("share/examples/backup");
   Require_Directory ("share/backup");
   Require_Directory ("share/completions");
   Require_Directory ("share/man");
   Require_Directory ("share");

   Require_Text ("README.md", "tools/bin/check_all");
   Require_Text ("README.md", "--json-errors");
   Require_Text ("README.md", "backup-error-v1");
   Require_Text ("README.md", "## Advanced CLI Reference");
   Require_Text ("README.md", "--remote-config FILE");
   Require_Text ("README.md", "--remote-require-encrypted");
   Require_Text ("README.md", "--catalog FILE");
   Require_Text ("README.md", "--verify-catalog");
   Require_Text ("README.md", "`remote-verified` accepts");
   Require_Text ("README.md", "`encrypted` accepts the same boolean");
   Require_Text ("README.md", "for the built-in named methods");
   Require_Text ("README.md", "--create-job FILE");
   Require_Text ("README.md", "--retention-policy POLICY");
   Require_Text ("README.md", "REMOTE_TRANSPORT.md");
   Require_Text ("README.md", "CATALOG.md");
   Require_Text ("CATALOG.md", "Named method ids are stable: store=0, deflate=8, bzip2=12, lzma=14, legacy zstd=20, and zstd=93");
   Require_Text ("tests/src/backup_catalog_tests.adb", "SPARK catalog accepts documented numeric method ids");
   Require_Text ("README.md", "JOBS_RETENTION.md");
   Require_Text
     ("README.md",
      "alr exec -- gnatprove -P backup_spark.gpr --level=4");
   Require_Text ("README.md", "terminal_styles");
   Require_Text ("README.md", "i18n");
   Require_Text ("README.md", "share/backup/messages.catalog");
   Require_Text ("README.md", "share/man/man1/backup.1");
   Require_Text ("README.md", "share/completions");
   Require_Text ("README.md", "share/examples/backup");
   Require_Text
     ("docs/SPARK.md",
      "alr exec -- gnatprove -P backup_spark.gpr --level=4");
   Require_Text ("docs/SPARK.md", "Backup.Path_Syntax");
   Require_Text ("docs/SPARK.md", "Backup.Incremental_Syntax");
   Require_Text ("docs/SPARK.md", "Backup.Jobs_Syntax");
   Require_Text ("docs/SPARK.md", "Backup.Jobs_Retention_Syntax");
   Require_Text ("docs/SPARK.md", "Backup.Remote_Syntax");
   Require_Text ("docs/SPARK.md", "remote status, transport, sync-action, HTTP status, transport classification, resume-mode, timeout precheck, and retry-decision helpers");
   Require_Text ("docs/SPARK.md", "Backup.Remote_Sync_Syntax");
   Require_Text ("docs/SPARK.md", "Backup.Manifest_Syntax");
   Require_Text ("docs/SPARK.md", "Backup.CLI_Syntax");
   Require_Text ("docs/SPARK.md", "catalog/job/remote command selection predicates");
   Require_Text ("docs/SPARK.md", "restore conflict-policy admission");
   Require_Text ("src/backup-cli_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-cli_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Syntax.Accumulate_Decimal");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Syntax.Any_Catalog_Command");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Syntax.Remote_Direction_Conflict");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Syntax.Job_Command_Conflict");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Syntax.Positional_Paths_Disallowed");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Syntax.Restore_Conflict_Can_Be_Set");
   Require_Text ("src/backup-cli_syntax.ads", "Exactly_One_Catalog_Command");
   Require_Text ("src/backup-cli_syntax.ads", "Remote_Direction_Conflict");
   Require_Text ("src/backup-cli_syntax.ads", "Job_Command_Conflict");
   Require_Text ("src/backup-cli_syntax.ads", "Positional_Paths_Disallowed");
   Require_Text ("src/backup-cli_syntax.ads", "Restore_Conflict_Can_Be_Set");
   Require_Text ("src/backup-manifest_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-manifest_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-manifest.adb", "Backup.Manifest_Syntax.Method_Name");
   Require_Text ("docs/SPARK.md", "Backup.Catalog_Syntax");
   Require_Text ("docs/SPARK.md", "catalog status, verification, encryption, entry-kind, numeric, boolean, and query-value parse helpers");
   Require_Text ("docs/SPARK.md", "Backup.Restore_Syntax");
   Require_Text ("src/backup-path_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-path_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-incremental_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-incremental_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-jobs_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-jobs_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-jobs_retention_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-jobs_retention_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-jobs.adb", "Backup.Jobs_Retention_Syntax.Count_Policy_Deletes");
   Require_Text ("src/backup-remote_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-remote_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-remote_syntax.ads", "Is_HTTP_Transport");
   Require_Text ("src/backup-remote_syntax.ads", "Timeout_Precheck_Status");
   Require_Text ("src/backup-remote_syntax.ads", "Retry_Available");
   Require_Text ("src/backup-remote_syntax.ads", "Attempts_Exhausted");
   Require_Text ("src/backup-remote.adb", "Backup.Remote_Syntax.Is_HTTP_Transport");
   Require_Text ("src/backup-remote.adb", "Backup.Remote_Syntax.Timeout_Precheck_Status");
   Require_Text ("src/backup-remote.adb", "Backup.Remote_Syntax.Retry_Available");
   Require_Text ("src/backup-remote.adb", "Backup.Remote_Syntax.Attempts_Exhausted");
   Require_Text ("src/backup-remote_sync_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-remote_sync_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-remote.adb", "Backup.Remote_Sync_Syntax.Inventory_Item_Action");
   Require_Text ("src/backup-catalog_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-catalog_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-catalog_syntax.ads", "Parse_U64_Text");
   Require_Text ("src/backup-catalog_syntax.ads", "Is_Method_Query_Text");
   Require_Text ("src/backup-catalog.adb", "Backup.Catalog_Syntax.Parse_U64_Text");
   Require_Text ("src/backup-catalog.adb", "Backup.Catalog_Syntax.Is_Method_Query_Text");
   Require_Text ("src/backup-restore_syntax.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-restore_syntax.adb", "with SPARK_Mode => On");
   Require_Text ("src/backup-restore_syntax.ads", "Path_Matches_Filter");
   Require_Text ("src/backup-restore_syntax.ads", "Symlink_Target_Is_Safe");
   Require_Text ("src/backup-restore.adb", "Backup.Restore_Syntax.Report_Action");
   Require_Text ("src/backup-restore.adb", "Backup.Restore_Syntax.Path_Matches_Filter");
   Require_Text ("src/backup-restore.adb", "Backup.Restore_Syntax.Symlink_Target_Is_Safe");
   Require_Text ("src/backup-cli.adb", "--help-advanced");
   Require_Text ("src/backup-cli_surface.adb", "help.advanced");
   Require_Text ("src/backup-cli.adb", "--json-errors");
   Require_Text ("src/backup-cli.adb", "backup-error-v1");
   Require_Text ("src/backup-cli.adb", "Terminal_Styles");
   Require_Text ("tests/src/backup_cli_tests.adb", "json-errors parsed");
   Require_Text ("tests/src/backup_cli_tests.adb", "binary help-advanced emits remote options");
   Require_Text ("tests/src/backup_cli_tests.adb", "binary json-errors smoke emits format marker");
   Require_Text ("src/backup-catalog.adb", "Backup.Catalog_Syntax.Parse_Verification");
   Require_Text ("src/backup-remote.adb", "Backup.Remote_Syntax.HTTP_Status_OK");
   Require_Text ("src/backup-jobs.adb", "Backup.Jobs_Syntax.Valid_Schedule_Metadata");
   Require_Text ("src/backup-incremental.adb", "Backup.Incremental_Syntax.Method_Name");
   Require_Text ("src/backup-path_syntax.ads", "Safe_Object_Name");
   Require_Text ("src/backup-path_syntax.ads", "Looks_Like_Managed_Object");
   Require_Text ("src/backup-remote.adb", "Backup.Path_Syntax.Safe_Object_Name");
   Require_Text ("docs/TESTING.md", "./bin/tests");
   Require_Text ("docs/SYMLINKS.md", "--symlinks=skip");
   Require_Text ("docs/SYMLINKS.md", "--symlinks=store-link");
   Require_Text ("docs/SYMLINKS.md", "Windows builds use `cmd.exe /C mklink`");
   Require_Text ("docs/SYMLINKS.md", "--symlinks=follow");
   Require_Text ("docs/LEGACY_TESTS.md", "No test procedures remain in the legacy repair queue.");
   Require_Text ("tests/tests.gpr", "for Main use (""tests.adb""");
   Require_Text ("tests/tests.gpr", "backup_http_remote_live_tests.adb");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "GNAT.Sockets");
   Require_Text ("tests/tests.gpr", "-lssl");
   Require_Text ("tests/tests.gpr", "-lcrypto");
   Require_Text ("README.md", "docs/RELEASE.md");
   Require_Text ("README.md", "docs/CLI_SURFACE.md");
   Require_Text ("README.md", "docs/CLI_COMPATIBILITY.md");
   Require_Text ("README.md", "docs/SPARK.md");
   Require_Text ("README.md", "docs/TESTING.md");
   Require_Text ("README.md", "docs/LEGACY_TESTS.md");
   Require_Text ("README.md", "docs/SYMLINKS.md");
   Require_Text ("README.md", "docs/PORTABILITY.md");
   Require_Text ("README.md", "docs/IDRIVE_E2.md");
   Require_Text ("README.md", "docs/history");
   Require_Text ("README.md", "--help-advanced");
   Require_Text ("docs/RELEASE.md", "tools/bin/check_all");
   Require_Text ("docs/RELEASE.md", "bin/backup");
   Require_Text ("docs/RELEASE.md", "windows-latest");
   Require_Text ("docs/RELEASE.md", "macos-latest");
   Require_Text ("docs/RELEASE.md", "docs/history");
   Require_Text ("docs/RELEASE.md", "Fish, Zsh, and PowerShell completion smoke scripts");
   Require_Text ("docs/RELEASE.md", "tools/bin/generate_cli_surface");
   Require_Text ("docs/RELEASE.md", "docs/CLI_SURFACE.md");
   Require_Text ("docs/RELEASE.md", "docs/CLI_COMPATIBILITY.md");
   Require_Text ("docs/RELEASE.md", "terminal_styles");
   Require_Text ("docs/RELEASE.md", "i18n");
   Require_Text ("docs/RELEASE.md", "share/backup");
   Require_Text ("docs/RELEASE.md", "share/man");
   Require_Text ("docs/RELEASE.md", "all 16 test procedures");
   Require_Text ("backup.gpr", "BACKUP_TARGET_OS");
   Require_Text ("backup.gpr", "src/windows/");
   Require_Text ("backup.gpr", "src/unix/");
   Require_Text ("backup.gpr", "for Main use (""backup-main.adb"")");
   Require_Text ("backup.gpr", "for Executable (""backup-main.adb"") use ""backup""");
   Require_Text ("src/backup-remote.adb", "SSH_Lib.File_Transfer.Resume_Upload_File");
   Require_Text ("REMOTE_TRANSPORT.md", "ssh_lib` byte-offset resume");
   Require_Text ("REMOTE_TRANSPORT.md", "`ProxyCommand`");
   Require_Text ("README.md", "`ProxyCommand` configuration");
   Require_Text ("README.md", "ZIP bzip2, bounded ZIP-LZMA, and Zstandard creation and unencrypted verification/extraction for classic and ZIP64 metadata are in-process through zlib");
   Require_Text ("README.md", "ZIP PPMd (method 98) is not supported");
   Require_Text ("README.md", "ZIP method ids are stable: bzip2 uses method 12, LZMA uses method 14, Zstandard uses method 93");
   Require_Text ("JOBS_RETENTION.md", "BZip2, bounded ZIP-LZMA, and Zstandard ZIP creation are in-process through zlib");
   Require_Text ("JOBS_RETENTION.md", "unencrypted BZip2, bounded ZIP-LZMA, and Zstandard ZIP verification/extraction, including ZIP64 metadata, are also in-process");
   Require_Text ("JOBS_RETENTION.md", "ZIP PPMd (method 98) is not supported");
   Require_Text ("JOBS_RETENTION.md", "ZIP method ids are stable: bzip2=12, lzma=14, zstd=93");
   Require_Text ("tests/src/backup_zip_tests.adb", "BZip2 central header uses method 12");
   Require_Text ("tests/src/backup_verify_tests.adb", "native bzip2 ZIP archive");
   Require_Text ("tests/src/backup_verify_tests.adb", "native bzip2 ZIP64 archive");
   Require_Text ("tests/src/backup_verify_tests.adb", "native zstd ZIP archive");
   Require_Text ("tests/src/backup_verify_tests.adb", "native zstd ZIP64 archive");
   Require_Text ("tests/src/backup_verify_tests.adb", "legacy zstd ZIP archive");
   Require_Text ("tests/src/backup_verify_tests.adb", "legacy zstd ZIP64 archive");
   Require_Text ("tests/src/backup_verify_tests.adb", "native LZMA archive created");
   Require_Text ("tests/src/backup_verify_tests.adb", "LZMA ZIP64 archive");
   Require_Text ("tests/src/backup_restore_tests.adb", "native bzip2 ZIP archive extraction succeeds");
   Require_Text ("tests/src/backup_restore_tests.adb", "native bzip2 ZIP64 archive extraction succeeds");
   Require_Text ("tests/src/backup_restore_tests.adb", "native zstd ZIP archive extraction succeeds");
   Require_Text ("tests/src/backup_restore_tests.adb", "native zstd ZIP64 archive extraction succeeds");
   Require_Text ("tests/src/backup_restore_tests.adb", "legacy zstd ZIP archive extraction succeeds");
   Require_Text ("tests/src/backup_restore_tests.adb", "legacy zstd ZIP64 archive extraction succeeds");
   Require_Text ("tests/src/backup_restore_tests.adb", "create native LZMA restore fixture");
   Require_Text ("tests/src/backup_restore_tests.adb", "LZMA ZIP64 archive extraction succeeds");
   Require_Text ("../sshlib/src/ssh_lib-sessions.ads", "Proxy_Command");
   Require_Text ("../sshlib/src/ssh_lib-forwarding.ads", "type Forward_Service");
   Require_Text
     ("../sshlib/src/ssh_lib-forwarding.ads",
      "function Start_Dynamic_Forward_Service");
   Require_Text ("tests/src/backup_remote_tests.adb",
                 "ssh resume upload honors timeout precheck before opening a session");
   Require_Text ("alire.toml", "gnat_native = ""=15.2.1""");
   Require_Text ("tests/alire.toml", "gnat_native = ""=15.2.1""");
   Require_Text ("README.md", "gnat_native = ""=15.2.1""");
   Require_Text ("docs/RELEASE.md", "gnat_native = ""=15.2.1""");
   Require_Text ("tools/src/check_all.adb", "GNATLS 15.");
   Require_Text ("alire.toml", "project_tools = ");
   Require_Text ("alire.toml", "project_tools = { path = ""../project_tools"" }");
   --  The sibling crates are Alire dependencies with path pins; Alire generates
   --  the with-clauses into config/backup_config.gpr. backup.gpr must not import
   --  their project files directly: a raw GPR import bypasses Alire, so nothing
   --  builds the sibling or generates its (gitignored) config, and the path case
   --  has to match on case-sensitive file systems.
   Require_Text ("alire.toml", "zlib = { path = ""../zlib"" }");
   Require_Text ("alire.toml", "ssh_lib = { path = ""../sshlib"" }");
   Require_Text ("alire.toml", "cryptolib = { path = ""../cryptolib"" }");
   Require_Text ("alire.toml", "httpclient = { path = ""../httpclient"" }");
   Require_Text ("alire.toml", "terminal_styles = { path = ""../terminal_styles"" }");
   Require_Text ("alire.toml", "i18n = { path = ""../i18n"" }");
   Require_Text ("alire.toml", "project_tools = { path = ""../project_tools"" }");

   Require_Text ("backup.gpr", "-lssl");
   Require_Text ("backup.gpr", "-lcrypto");
   Require_Text ("backup.gpr", "package Install");
   Require_Text ("backup.gpr", "for Artifacts");
   Require_Text ("backup.gpr", "share");
   Require_Text ("alire.toml", "zlib = ""*""");
   Require_Text ("alire.toml", "zlib = { path = ""../zlib"" }");
   Require_Text ("alire.toml", "terminal_styles = ""*""");
   Require_Text ("alire.toml", "terminal_styles = { path = ""../terminal_styles"" }");
   Require_Text ("alire.toml", "i18n = ""*""");
   Require_Text ("alire.toml", "i18n = { path = ""../i18n"" }");
   Require_Text ("tests/alire.toml", "terminal_styles = ""*""");
   Require_Text ("tests/alire.toml", "terminal_styles = { path = ""../../terminal_styles"" }");
   Require_Text ("tests/alire.toml", "i18n = ""*""");
   Require_Text ("tests/alire.toml", "i18n = { path = ""../../i18n"" }");
   Require_Text ("tests/alire.toml", "zlib = { path = ""../../zlib"" }");
   Require_Text ("alire.toml", "type = ""test""");
   Require_Text ("alire.toml", "cd tests && alr build && ./bin/tests");
   Require_Text ("tests/alire.toml", "backup = { path = "".."" }");
   Require_Text ("tests/alire.toml", "aunit = ");
   Require_Text ("tests/alire.toml", "project_tools = ");
   Require_Text ("tests/alire.toml", "project_tools = { path = ""../../project_tools"" }");
   Require_Text ("tests/tests.gpr", "../../project_tools/project_tools.gpr");
   Require_Text ("tests/src/backup_catalog_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_cli_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_encryption_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_jobs_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_manifest_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_remote_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_restore_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_verify_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_workflow_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/backup_zip_tests.adb", "Project_Tools.Files");
   Require_Text ("tests/src/tests.adb", "AUnit.Run.Test_Runner");
   Require_Text ("tests/src/all_suites.ads", "AUnit.Test_Suites");
   Require_Text ("tests/src/all_suites.adb", "Backup_Suite.Suite");
   Require_Text ("tests/src/backup_suite.ads", "AUnit.Test_Suites");
   Require_Text ("tests/src/backup_suite.adb", "AUnit.Test_Cases");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Paths_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_CLI_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Ignore_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Jobs_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Catalog_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Compression_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Encryption_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Incremental_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Manifest_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Remote_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Restore_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Scanner_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Verify_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Workflow_Tests");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Zip_Tests");
   Require_Text ("tests/src/backup_catalog_tests.adb", "backup catalog tests passed");
   Require_Text ("tests/src/backup_encryption_tests.adb", "backup encryption tests passed");
   Require_Text ("tests/src/backup_incremental_tests.adb", "backup incremental tests passed");
   Require_Text ("tests/src/backup_remote_tests.adb", "backup remote tests passed");
   Require_Text ("tests/src/backup_zip_tests.adb", "backup ZIP tests passed");
   Require_Text ("tests/src/backup_zip_tests.adb", "backup can consume zlib ZIP_Files");
   Require_Text (".github/workflows/ci.yml", "tools/bin/check_all");
   Require_Text (".github/workflows/ci.yml", "windows-latest");
   Require_Text (".github/workflows/ci.yml", "macos-latest");
   Require_Text (".github/workflows/ci.yml", "terminal_styles");
   Require_Text (".github/workflows/ci.yml", "fish zsh");
   Require_Text (".github/workflows/ci.yml", "pwsh");
   Require_Text (".github/workflows/ci.yml", "powershell --classic");
   Require_Text (".github/workflows/ci.yml", "i18n");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/zlib");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/sshlib");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/cryptolib");
   Require_Text (".github/workflows/ci.yml", "path: sshlib");
   Require_Text (".github/workflows/ci.yml", "path: cryptolib");
   Require_Text (".github/workflows/ci.yml", "working-directory: backup/tests");
   Require_Text (".github/workflows/ci.yml", ".\bin\tests.exe");
   Require_Text (".github/workflows/ci.yml",
                 ".\bin\backup_http_remote_live_tests.exe");
   Require_Text ("docs/RELEASE.md", "runs both maintained test executables");
   Require_Text ("docs/RELEASE.md", "gprinstall");
   Require_Text ("docs/RELEASE.md", "installed `backup --version`");
   Require_Text ("docs/TESTING.md", "Windows and macOS coverage are execution coverage");
   Require_Text ("docs/TESTING.md", "Always-On Provider Simulation");
   Require_Text ("docs/TESTING.md", "S3, Google Drive, pCloud, and Proton Drive fail-closed behavior");
   Require_Text ("docs/TESTING.md", "fixture fallback must remain an explicit, tested path");
   Require_Text ("docs/TESTING.md", "macos-latest");
   Require_Text ("docs/TESTING.md", "BACKUP_S3_COMPAT_REMOTE");
   Require_Text ("docs/TESTING.md", "BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/project_tools");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/HttpClient");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/terminal_styles");
   Require_Text (".github/workflows/ci.yml", "${{ github.repository_owner }}/i18n");
   Require_Text (".github/workflows/ci.yml", "BACKUP_S3_COMPAT_REMOTE");
   Require_Text (".github/workflows/ci.yml", "BACKUP_S3_COMPAT_ENDPOINT");
   Require_Text (".github/workflows/ci.yml", "BACKUP_S3_COMPAT_ACCESS_KEY");
   Require_Text (".github/workflows/ci.yml", "BACKUP_S3_COMPAT_SECRET_KEY");
   Require_Text (".github/workflows/ci.yml", "BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE");
   Require_Text (".github/workflows/ci.yml", "BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN");
   Require_Text (".github/workflows/ci.yml", "BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN");
   Require_Text ("docs/RELEASE.md", "S3 CI Provider Secrets");
   Require_Text ("docs/RELEASE.md", "BACKUP_S3_COMPAT_SECRET_KEY");
   Require_Text ("docs/RELEASE.md", "Google Drive CI Provider Secrets");
   Require_Text ("docs/RELEASE.md", "BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN");
   Require_Text ("docs/RELEASE.md", "BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN");
   Require_Text ("REMOTE_TRANSPORT.md", "HTTP and HTTPS object remotes are implemented through");
   Require_Text ("REMOTE_TRANSPORT.md", "backup-remote-index-v1");
   Require_Text ("REMOTE_TRANSPORT.md", "OBJECT<TAB>SIZE<TAB>CRC32<TAB>TIMESTAMP");
   Require_Text ("REMOTE_TRANSPORT.md", "x-amz-meta-backup-crc32");
   Require_Text ("REMOTE_TRANSPORT.md", "x-amz-checksum-crc32");
   Require_Text ("REMOTE_TRANSPORT.md", "x-amz-checksum-algorithm: CRC32");
   Require_Text ("REMOTE_TRANSPORT.md", "<ChecksumCRC32>");
   Require_Text ("src/backup-remote.adb", "x-amz-checksum-algorithm");
   Require_Text ("src/backup-remote.adb", "<ChecksumCRC32>");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "x-amz-checksum-algorithm");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "<ChecksumCRC32>");
   Require_Text ("REMOTE_TRANSPORT.md", "x-amz-checksum-mode: ENABLED");
   Require_Text ("REMOTE_TRANSPORT.md", "docs/IDRIVE_E2.md");
   Require_Text ("docs/IDRIVE_E2.md", "IDrive e2 is S3-compatible object storage");
   Require_Text ("docs/IDRIVE_E2.md", "s3_endpoint=https://YOUR-IDRIVE-E2-ENDPOINT");
   Require_Text ("docs/IDRIVE_E2.md", "s3_addressing=path");
   Require_Text ("docs/IDRIVE_E2.md", "BACKUP_IDRIVE_E2_ACCESS_KEY");
   Require_Text ("REMOTE_TRANSPORT.md", "gdrive://FOLDER_ID/PREFIX/");
   Require_Text ("REMOTE_TRANSPORT.md", "files.create`/`files.update");
   Require_Text ("src/backup-remote.ads", "Transport_Google_Drive");
   Require_Text ("src/backup-remote.adb", "Google_Drive_Access_Token");
   Require_Text ("src/backup-remote.adb", "nextPageToken");
   Require_Text ("src/backup-remote.adb", "supportsAllDrives=true");
   Require_Text ("src/backup-remote.adb", "rateLimitExceeded");
   Require_Text ("src/backup-remote.adb", "uploadType=resumable");
   Require_Text ("src/backup-remote.adb", "googleapis.com/token");
   Require_Text ("src/backup-cli.adb", "google_drive_access_token_file");
   Require_Text ("src/backup-jobs.adb", "remote_google_drive_refresh_token");
   Require_Text ("REMOTE_TRANSPORT.md", "uploadType=resumable");
   Require_Text ("REMOTE_TRANSPORT.md", "without loading the archive into memory");
   Require_Text ("REMOTE_TRANSPORT.md", "google_drive_access_token_file");
   Require_Text ("REMOTE_TRANSPORT.md", "google_drive_refresh_token");
   Require_Text ("REMOTE_TRANSPORT.md", "google_drive_drive_id");
   Require_Text ("REMOTE_TRANSPORT.md", "quotaExceeded");
   Require_Text ("tests/src/backup_remote_tests.adb", "Transport_Google_Drive");
   Require_Text ("tests/src/backup_remote_tests.adb", "Transport_PCloud");
   Require_Text ("src/backup-remote.adb", "x-amz-checksum-crc32");
   Require_Text ("src/backup-remote.adb", "S3_CRC32_Base64");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "S3 single PUT sends native CRC32 checksum");
   Require_Text ("src/backup-remote.adb", "x-amz-meta-backup-crc32");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "S3 fallback preserves CRC32 from object metadata");
   Require_Text ("REMOTE_TRANSPORT.md", "the updated index with `PUT` to the namespace URL");
   Require_Text ("REMOTE_TRANSPORT.md", "fixed-length streaming request");
   Require_Text ("REMOTE_TRANSPORT.md", "reopening the local archive for each");
   Require_Text ("REMOTE_TRANSPORT.md", "If-Match");
   Require_Text ("REMOTE_TRANSPORT.md", "If-None-Match: *");
   Require_Text ("src/backup-remote.adb", "From_Fixed_Length_Stream");
   Require_Text ("src/backup-remote.adb", "If-Match");
   Require_Text ("src/backup-remote.adb", "If-None-Match");
   Require_Text ("src/backup-remote.adb", "HTTP_Index_Conflict_Retry_Limit");
   Require_Text ("REMOTE_TRANSPORT.md", "refetching the current index");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "HTTP index conflict is refetched and retried");
   Require_Text ("src/backup-remote.ads", "HTTP_Auth_Bearer");
   Require_Text ("src/backup-remote.adb", "Add_HTTP_Auth_Headers");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "authenticated HTTP upload");
   Require_Text ("REMOTE_TRANSPORT.md", "http_bearer_token=TOKEN");
   Require_Text ("REMOTE_TRANSPORT.md", "tls_ca_file=PEM");
   Require_Text ("REMOTE_TRANSPORT.md", "remote_tls_ca_file=PEM");
   Require_Text ("REMOTE_TRANSPORT.md", "tls_client_cert=PEM");
   Require_Text ("src/backup-remote.ads", "TLS_CA_File");
   Require_Text ("src/backup-remote.ads", "TLS_Client_Cert_File");
   Require_Text ("src/backup-remote.adb", "Client_Certificate");
   Require_Text ("tests/src/backup_remote_tests.adb",
                 "tls_ca_file=/tmp/ca.pem");
   Require_Text ("tests/src/backup_remote_tests.adb",
                 "tls_client_cert=/tmp/client.pem");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "HTTPS upload, readback verify, and index publish succeed");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "HTTPS delete and index removal succeed");
   Require_Text ("src/windows/backup-platform.adb", "mklink");
   Require_Text ("src/windows/backup-platform.adb", "cmd.exe");
   Require_Text ("src/backup-remote.adb", "Stream_HTTP_Put_With_Retry");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb",
                 "HTTP upload retries a failed streaming PUT");
   Require_Text ("tools/tools.gpr", "../../project_tools/project_tools.gpr");
   Require_Text ("tools/src/check_all.adb", "Project_Tools.Release_Checks");
   Require_Text ("tools/src/check_all.adb", "Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr");
   Require_Text ("share/man/man1/backup.1", "Ada command-line backup utility");
   Require_Text ("share/completions/backup.bash", "complete -F _backup_complete backup");
   Require_Text ("share/completions/_backup", "#compdef backup");
   Require_Text ("share/examples/backup/example.conf", "schedule=external");
   Require_Text ("share/backup/messages.catalog", "en.help.title");
   Require_Text ("share/backup/messages.catalog", "--help-advanced");
   Require_Text ("share/backup/messages.catalog", "en.help.advanced.remote1");
   Require_Text ("share/backup/messages.catalog", "en.error.prefix");
   Require_Text ("src/backup-messages.adb", "I18N.Runtime.Initialize");
   Require_Text ("src/backup-cli.adb", "Backup.Messages");
   Require_Text ("src/backup-cli.adb", "Backup.CLI_Surface.Message_Key");
   Require_Text ("src/backup-cli_surface.ads", "with SPARK_Mode => On");
   Require_Text ("src/backup-zip.adb", "Internal_Attrs");
   Require_Text ("src/backup-zip.adb", "Compress_ZIP_External_File");
   Require_Text ("src/backup-zip.adb", "Zlib.ZIP_External_Method_Name");
   Require_Text ("src/backup-verify.adb", "Backup.Incremental_Syntax.Method_Name");
   Require_Text ("src/backup-incremental.adb", "Backup.Zip.Method_Number");
   Require_Text ("tests/src/backup_zip_tests.adb", "zstd compression uses ZIP method 93");
   Require_Text ("tests/src/backup_zip_tests.adb", "BZip2 central header uses method 12");
   Require_Text ("tests/src/backup_zip_tests.adb", "Zstd central header uses method 93");
   Require_Text ("tests/src/backup_zip_tests.adb", "LZMA central header uses method 14");
   Require_Text ("tools/cli_surface.conf", "auto store deflate bzip2 lzma zstd");
   Require_Text ("share/man/man1/backup.1", "bzip2, bounded ZIP-LZMA, and zstd ZIP creation and unencrypted verification/extraction for classic and ZIP64 metadata are in-process through zlib");
   Require_Text ("share/man/man1/backup.1", "ZIP PPMd (method 98) is not supported");
   Require_Text ("share/man/man1/backup.1", "ZIP method ids are stable: bzip2=12, lzma=14, zstd=93");
   Require_Text ("tests/src/backup_zip_tests.adb", "central internal attributes mark text payload");
   Require_Text ("tests/src/backup_zip_tests.adb", "binary payload unmarked");
   Require_Text ("tests/src/backup_suite.adb", "Backup_Legacy_Scripts_Tests");
   Require_Text ("tests/src/backup_legacy_scripts_tests.adb", "legacy shell launchers were removed");
   Require_Text ("docs/LEGACY_TESTS.md", "legacy script audit");
   Require_Text ("tools/src/package_release.adb", "backup-release-smoke.tar.gz");
   Require_Text ("tools/src/package_release.adb", "cksum");
   Require_Text ("README.md", "tools/bin/package_release");
   Require_Text ("docs/RELEASE.md", "release package smoke");
   Require_Text ("share/man/man1/backup.1", "--remote-config");
   Require_Text ("share/completions/backup.bash", "--remote-config");
   Require_Text ("share/completions/backup.bash", "--incremental-from-manifest");
   Require_Text ("share/completions/backup.bash", "auto store deflate bzip2 lzma zstd");
   Require_Text ("share/completions/backup.bash", "compgen -A variable");
   Require_Text ("share/completions/backup.fish", "complete -c backup");
   Require_Text ("share/completions/backup.fish", "auto store deflate bzip2 lzma zstd");
   Require_Text ("share/completions/backup.fish", "incremental-from-manifest");
   Require_Text ("share/completions/backup.ps1", "Register-ArgumentCompleter -Native -CommandName backup");
   Require_Text ("share/completions/backup.ps1", "deflate");
   Require_Text ("share/completions/backup.ps1", "bzip2");
   Require_Text ("share/completions/backup.ps1", "--incremental-from-manifest");
   Require_Text ("tools/src/check_bash_completion.adb", "backup completion check passed");
   Require_Text ("tools/src/check_s3_compatibility.adb", "backup S3 compatibility gate passed");
   Require_Text ("tools/src/check_s3_compatibility.adb", "BACKUP_S3_COMPAT_REMOTE");
   Require_Text ("tools/src/check_s3_compatibility.adb", "BACKUP_S3_COMPAT_STRICT");
   Require_Text ("tools/src/check_s3_compatibility.adb", "BACKUP_S3_COMPAT_ALLOW_FIXTURE");
   Require_Text ("tools/src/check_google_drive_compatibility.adb", "backup Google Drive compatibility gate passed");
   Require_Text ("tools/src/check_proton_drive_compatibility.adb", "backup Proton Drive compatibility gate passed");
   Require_Text ("tools/src/check_proton_drive_compatibility.adb", "BACKUP_PROTON_DRIVE_COMPAT_REMOTE");
   Require_Text ("tools/src/check_proton_drive_compatibility.adb", "BACKUP_PROTON_DRIVE_COMPAT_STRICT");
   Require_Text ("tools/src/check_proton_drive_compatibility.adb", "BACKUP_PROTON_DRIVE_COMPAT_ALLOW_FIXTURE");
   Require_Text ("tools/src/check_proton_drive_compatibility.adb", "BACKUP_PROTON_DRIVE_COMPAT_SESSION_FILE");
   Require_Text ("src/proton_drive.ads", "package Proton_Drive");
   Require_Text ("src/proton_drive.ads", "type Client is private");
   Require_Text ("src/proton_drive.ads", "function Load_Session");
   Require_Text ("src/proton_drive.ads", "function Resolve_User_Address");
   Require_Text ("src/proton_drive.ads", "function Load_Crypto_Context");
   Require_Text ("src/proton_drive.ads", "function Metadata_Authentication_Tag");
   Require_Text ("src/proton_drive.ads", "function Content_Block_Tag");
   Require_Text ("src/proton_drive.ads", "function Tagged_Content_Block");
   Require_Text ("src/proton_drive.ads", "function Streaming_Content_Block");
   Require_Text ("src/proton_drive.ads", "function Open_Streaming_Content_Block");
   Require_Text ("src/proton_drive.ads", "function Metadata_Envelope");
   Require_Text ("src/proton_drive.ads", "function Encrypted_Metadata_Envelope");
   Require_Text ("src/proton_drive.ads", "function Open_Encrypted_Metadata_Envelope");
   Require_Text ("src/proton_drive.ads", "function Supports_First_Party_Key_Unlock");
   Require_Text ("src/proton_drive.ads", "function First_Party_Key_Unlock_Status");
   Require_Text ("src/proton_drive.ads", "function Auth_Request_Envelope");
   Require_Text ("src/proton_drive.ads", "function Wire_Contract");
   Require_Text ("src/proton_drive.ads", "function Wire_Response_Valid");
   Require_Text ("src/proton_drive.ads", "function Has_Operation_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Large_Upload_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Folder_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Conflict_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Resume_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Trash_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Revision_Provider");
   Require_Text ("src/proton_drive.ads", "function Has_Event_Replay_Provider");
   Require_Text ("src/proton_drive.ads", "function Supports_Auth_Provider");
   Require_Text ("src/proton_drive.ads", "function Supports_Login_Provider");
   Require_Text ("src/proton_drive.ads", "function Supports_Native_Auth_Flow");
   Require_Text ("src/proton_drive.ads", "function Has_Wire_Contract");
   Require_Text ("src/proton_drive.ads", "function Supports_Live_Compatibility_Check");
   Require_Text ("src/proton_drive.ads", "function Requires_Chunked_Upload");
   Require_Text ("src/proton_drive.ads", "function Plan_Upload");
   Require_Text ("src/proton_drive.ads", "function Supports_Streaming_Transfer");
   Require_Text ("src/proton_drive.ads", "function Refresh_Session");
   Require_Text ("src/proton_drive.ads", "function Start_Login");
   Require_Text ("src/proton_drive.ads", "function Complete_MFA");
   Require_Text ("src/proton_drive.ads", "function Bootstrap_Session");
   Require_Text ("src/proton_drive.ads", "function Login_And_Save_Session");
   Require_Text ("src/proton_drive.ads", "function Upload_File");
   Require_Text ("src/proton_drive.ads", "function Create_Folder");
   Require_Text ("src/proton_drive.ads", "function Trash_Node");
   Require_Text ("src/proton_drive.ads", "function Resolve_Conflict");
   Require_Text ("src/proton_drive.ads", "function Latest_Revision");
   Require_Text ("src/proton_drive.ads", "function Resume_Upload");
   Require_Text ("src/proton_drive.ads", "function Get_Events");
   Require_Text ("src/proton_drive.adb", "external-drive-{name}");
   Require_Text ("src/proton_drive.adb", "stable");
   Require_Text ("src/proton_drive.adb", "beta");
   Require_Text ("src/proton_drive.adb", "alpha");
   Require_Text ("src/proton_drive.adb", "CryptoLib.Hashes.SHA256");
   Require_Text ("src/proton_drive.adb", "CryptoLib.Macs.HMAC_SHA256");
   Require_Text ("src/proton_drive.adb", "CryptoLib.ChaCha20_Poly1305.Seal");
   Require_Text ("src/proton_drive.adb", "CryptoLib.BCrypt_PBKDF.Derive");
   Require_Text ("src/proton_drive.adb", "PROTON-KEY-UNLOCK-V1");
   Require_Text ("src/proton_drive.adb", "first-party account key unlock is unavailable");
   Require_Text ("src/proton_drive.adb", "backup-proton-metadata-v2");
   Require_Text ("src/proton_drive.adb", "SDK_Crypto_Unavailable");
   Require_Text ("src/proton_drive.adb", "SDK_Operations_Unavailable");
   Require_Text ("src/proton_drive.adb", "metadata_hmac_key");
   Require_Text ("src/proton_drive.adb", "node_key_material");
   Require_Text ("src/proton_drive.adb", "content_key_material");
   Require_Text ("src/proton_drive.adb", "content_hmac_key");
   Require_Text ("src/proton_drive.adb", "proton_drive_descriptor_version");
   Require_Text ("src/proton_drive.adb", "proton_drive_sdk_generation");
   Require_Text ("src/proton_drive.adb", "proton_drive_wire_contract");
   Require_Text ("src/proton_drive.adb", "proton-drive-sdk-compat-v1");
   Require_Text ("src/proton_drive.adb", "proton_drive_live_check_url");
   Require_Text ("src/proton_drive.adb", "PROTON-BLOCK-TAG");
   Require_Text ("src/proton_drive.adb", "PROTON-STREAM-BLOCK-V1");
   Require_Text ("src/proton_drive.adb", "Open_Streaming_Content_Block");
   Require_Text ("src/proton_drive.adb", "backup-proton-metadata-v1");
   Require_Text ("src/proton_drive.adb", "Wire_Response_Valid");
   Require_Text ("src/proton_drive.adb", "create_folder");
   Require_Text ("src/proton_drive.adb", "conflict");
   Require_Text ("src/proton_drive.adb", "list_continue");
   Require_Text ("src/proton_drive.adb", "events_continue");
   Require_Text ("src/proton_drive.adb", "resume_upload");
   Require_Text ("src/proton_drive.adb", "session_bootstrap");
   Require_Text ("src/proton_drive.adb", "Auth_Operation_Template");
   Require_Text ("src/proton_drive.adb", "first-party auth is not implemented");
   Require_Text ("src/proton_drive.adb", "Session_Descriptor_Text");
   Require_Text ("src/proton_drive.adb", "trash");
   Require_Text ("src/proton_drive.adb", "revision");
   Require_Text ("src/proton_drive.adb", "bounded-memory threshold");
   Require_Text ("src/proton_drive.adb", "proton_drive_native_api");
   Require_Text ("src/proton_drive.adb", "upload_chunk");
   Require_Text ("src/proton_drive.adb", "proton_drive_operation_base_url");
   Require_Text ("src/proton_drive.adb", "Http_Client.Clients.Execute");
   Require_Text ("src/proton_drive.adb", "access_token");
   Require_Text ("src/proton_drive.adb", "address_key_id");
   Require_Text ("src/backup-remote.ads", "Transport_Proton_Drive");
   Require_Text ("src/backup-remote.adb", "Proton_Drive.Create");
   Require_Text ("src/backup-remote.adb", "Proton_Drive.Ready");
   Require_Text ("src/backup-cli.adb", "proton_drive_app_version");
   Require_Text ("src/backup-cli.adb", "--proton-drive-login");
   Require_Text ("docs/PROTON_DRIVE.md", "Proton Drive Remote Backend");
   Require_Text ("docs/PROTON_DRIVE.md", "fail-closed");
   Require_Text ("docs/PROTON_DRIVE.md", "authentication/login flows, session management, or a user address provider");
   Require_Text ("docs/PROTON_DRIVE.md", "CryptoLib.Macs.HMAC_SHA256");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_operation_base_url");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_native_api=true");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_descriptor_version=1");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_wire_contract=proton-drive-sdk-compat-v1");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_live_check_url");
   Require_Text ("docs/PROTON_DRIVE.md", "Content_Block_Tag");
   Require_Text ("docs/PROTON_DRIVE.md", "Tagged_Content_Block");
   Require_Text ("docs/PROTON_DRIVE.md", "Streaming_Content_Block");
   Require_Text ("docs/PROTON_DRIVE.md", "PROTON-STREAM-BLOCK-V1");
   Require_Text ("docs/PROTON_DRIVE.md", "Metadata_Envelope");
   Require_Text ("docs/PROTON_DRIVE.md", "Encrypted_Metadata_Envelope");
   Require_Text ("docs/PROTON_DRIVE.md", "Open_Encrypted_Metadata_Envelope");
   Require_Text ("docs/PROTON_DRIVE.md", "backup-proton-metadata-v2");
   Require_Text ("docs/PROTON_DRIVE.md", "encrypted_address_key_material");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_key_unlock_passphrase");
   Require_Text ("docs/PROTON_DRIVE.md", "Supports_First_Party_Key_Unlock");
   Require_Text ("docs/PROTON_DRIVE.md", "Start_Login");
   Require_Text ("docs/PROTON_DRIVE.md", "Login_And_Save_Session");
   Require_Text ("docs/PROTON_DRIVE.md", "--proton-drive-login");
   Require_Text ("docs/PROTON_DRIVE.md", "Direct first-party auth is unsupported");
   Require_Text ("docs/PROTON_DRIVE.md", "Create_Folder");
   Require_Text ("docs/PROTON_DRIVE.md", "Resume_Upload");
   Require_Text ("docs/PROTON_DRIVE.md", "Wire_Response_Valid");
   Require_Text ("docs/PROTON_DRIVE.md", "Plan_Upload");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_upload_chunk_url");
   Require_Text ("docs/PROTON_DRIVE.md", "proton_drive_session_bootstrap_url");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Crypto_Context");
   Require_Text ("tests/src/backup_remote_tests.adb", "SDK_Operations_Unavailable");
   Require_Text ("tests/src/backup_remote_tests.adb", "unsupported first-party auth");
   Require_Text ("tests/src/backup_remote_tests.adb", "Open_Encrypted_Metadata_Envelope");
   Require_Text ("tests/src/backup_remote_tests.adb", "backup-proton-metadata-v2");
   Require_Text ("tests/src/backup_remote_tests.adb", "Key_Unlock_Envelope");
   Require_Text ("tests/src/backup_remote_tests.adb", "wrong passphrase");
   Require_Text ("tests/src/backup_remote_tests.adb", "Supports_First_Party_Key_Unlock");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Operation_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Large_Upload_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Folder_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Conflict_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Resume_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Trash_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Revision_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Event_Replay_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Supports_Auth_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Supports_Login_Provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Has_Wire_Contract");
   Require_Text ("tests/src/backup_remote_tests.adb", "Supports_Live_Compatibility_Check");
   Require_Text ("tests/src/backup_remote_tests.adb", "Content_Block_Tag");
   Require_Text ("tests/src/backup_remote_tests.adb", "Tagged_Content_Block");
   Require_Text ("tests/src/backup_remote_tests.adb", "Streaming_Content_Block");
   Require_Text ("tests/src/backup_remote_tests.adb", "Open_Streaming_Content_Block");
   Require_Text ("tests/src/backup_remote_tests.adb", "Metadata_Envelope");
   Require_Text ("tests/src/backup_remote_tests.adb", "Encrypted_Metadata_Envelope");
   Require_Text ("tests/src/backup_remote_tests.adb", "Auth_Request_Envelope");
   Require_Text ("tests/src/backup_remote_tests.adb", "Start_Login");
   Require_Text ("tests/src/backup_remote_tests.adb", "Login_And_Save_Session");
   Require_Text ("tests/src/backup_remote_tests.adb", "Create_Folder");
   Require_Text ("tests/src/backup_remote_tests.adb", "Trash_Node");
   Require_Text ("tests/src/backup_remote_tests.adb", "Latest_Revision");
   Require_Text ("tests/src/backup_remote_tests.adb", "Resume_Upload");
   Require_Text ("tests/src/backup_remote_tests.adb", "Wire_Response_Valid");
   Require_Text ("tests/src/backup_remote_tests.adb", "Plan_Upload");
   Require_Text ("tests/src/backup_remote_tests.adb", "Requires_Chunked_Upload");
   Require_Text ("tests/src/backup_remote_tests.adb", "unsupported descriptor schema version");
   Require_Text ("tests/src/backup_remote_tests.adb", "without explicit wire contract");
   Require_Text ("tests/src/backup_remote_tests.adb", "native API mode fails closed");
   Require_Text ("tests/src/backup_remote_tests.adb", "SDK_Ok");
   Require_Text ("docs/PROTON_DRIVE.md", "external-drive-backup@0.1.0-alpha");
   Require_Text ("docs/PROTON_DRIVE.md", "external-drive-photo_backup@1.2.3-stable+abc123f");
   Require_Text ("docs/PROTON_DRIVE.md", "FilesApiClient");
   Require_Text ("docs/PROTON_DRIVE.md", "BlockUploadPreparationRequest");
   Require_Text ("docs/PROTON_DRIVE.md", "local provider descriptor");
   Require_Text ("docs/PROTON_DRIVE.md", "address_key_id");
   Require_Text ("README.md", "docs/PROTON_DRIVE.md");
   Require_Text ("REMOTE_TRANSPORT.md", "protondrive://SHARE_ID/PREFIX/");
   Require_Text ("tests/src/backup_remote_tests.adb", "Proton Drive Ada SDK loads session uid provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Proton Drive Ada SDK resolves configured user address provider");
   Require_Text ("tests/src/backup_remote_tests.adb", "Proton Drive Ada SDK upload fails closed without provider endpoints");
   Require_Text ("tests/src/backup_remote_tests.adb", "Proton Drive backend fails closed without provider endpoints");
   Require_Text ("tests/src/backup_remote_tests.adb", "remote config supplies Proton Drive app version");
   Require_Text ("src/backup-remote.ads", "Transport_PCloud");
   Require_Text ("src/backup-remote.adb", "PCloud_API_Base");
   Require_Text ("src/backup-cli.adb", "pcloud_access_token_env");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_access_token_env");
   Require_Text ("REMOTE_TRANSPORT.md", "pcloud://FOLDER_ID/PREFIX/");
   Require_Text ("REMOTE_TRANSPORT.md", "createfolderifnotexists");
   Require_Text ("REMOTE_TRANSPORT.md", "renamefile");
   Require_Text ("README.md", "pcloud_api_base=https://api.pcloud.com");
   Require_Text ("README.md", "docs/PCLOUD.md");
   Require_Text ("README.md", "OAuth token setup");
   Require_Text ("docs/PCLOUD.md", "pCloud Remote Backend");
   Require_Text ("docs/PCLOUD.md", "Creating And Rotating Tokens");
   Require_Text ("docs/PCLOUD.md", "--pcloud-oauth-url");
   Require_Text ("docs/PCLOUD.md", "--pcloud-oauth-token");
   Require_Text ("docs/PCLOUD.md", "pcloud_refresh_token");
   Require_Text ("docs/PCLOUD.md", "config snippets");
   Require_Text ("docs/PCLOUD.md", "Project_Tools.JSON");
   Require_Text ("docs/PCLOUD.md", "pcloud_region=auto");
   Require_Text ("docs/PCLOUD.md", "--pcloud-clean-temp");
   Require_Text ("docs/PCLOUD.md", "--pcloud-check");
   Require_Text ("docs/PCLOUD.md", "pcloud_upload_progress");
   Require_Text ("docs/PCLOUD.md", "pcloud_clean_recursive");
   Require_Text ("docs/PCLOUD.md", "progresshash");
   Require_Text ("docs/PCLOUD.md", "pcloud_poll_progress");
   Require_Text ("docs/PCLOUD.md", "pcloud_check_quota");
   Require_Text ("docs/PCLOUD.md", "pcloud_create_parents");
   Require_Text ("docs/PCLOUD.md", "pcloud_token_cache_file");
   Require_Text ("docs/PCLOUD.md", "permission-hardened to mode `0600`");
   Require_Text ("docs/PCLOUD.md", "best-effort live `uploadprogress` monitor");
   Require_Text ("docs/PCLOUD.md", "Native Windows builds keep the atomic temp-and-rename write path");
   Require_Text ("docs/PCLOUD.md", "icacls.exe /inheritance:r /grant:r CURRENT_USER:(R,W)");
   Require_Text ("src/windows/backup-platform.adb", "icacls.exe");
   Require_Text ("src/windows/backup-platform.adb", "User & "":(R,W)""");
   Require_Text ("docs/PCLOUD.md", "Backup does not manage pCloud revision history");
   Require_Text ("docs/PCLOUD.md", "matching temporary object is published with `renamefile`");
   Require_Text ("src/backup-remote.ads", "PCloud_Region");
   Require_Text ("src/backup-cli.adb", "pcloud_region");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_region");
   Require_Text ("src/backup-remote.ads", "Cleanup_Remote_Temporary_Objects");
   Require_Text ("src/backup-remote.adb", "Cleanup_PCloud_Temporary_Objects");
   Require_Text ("src/backup-remote.adb", "Check_PCloud_Remote");
   Require_Text ("src/backup-remote.adb", "PCloud_Progress_Hash");
   Require_Text ("src/backup-remote.adb", "Poll_PCloud_Upload_Progress");
   Require_Text ("src/backup-remote.adb", "PCloud_Quota_Allows");
   Require_Text ("src/backup-remote.adb", "Create_PCloud_Folder_Path");
   Require_Text ("src/backup-remote.adb", "PCloud_Token_Cache_File");
   Require_Text ("src/backup-remote.adb", "userinfo");
   Require_Text ("src/backup-remote.adb", "uploadprogress");
   Require_Text ("src/backup-remote.adb", "progresshash");
   Require_Text ("src/backup-remote.ads", "PCloud_Upload_Progress");
   Require_Text ("src/backup-remote.ads", "PCloud_Poll_Progress");
   Require_Text ("src/backup-remote.ads", "PCloud_Check_Quota");
   Require_Text ("src/backup-remote.ads", "PCloud_Create_Parents");
   Require_Text ("src/backup-remote.ads", "PCloud_Token_Cache_File");
   Require_Text ("src/backup-remote.ads", "PCloud_Clean_Recursive");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud temporary cleanup deletes stale upload objects");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud recursive temporary cleanup walks child folders");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud preflight checks auth, region, quota, and namespace");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "progresshash tracking");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud uploadprogress is polled when enabled");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud path URL creates missing parent folders");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud refresh-token auth writes token cache file");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud remote-resume reports reused provider object");
   Require_Text ("tests/src/backup_remote_tests.adb", "pCloud live progress monitor records provider sample count");
   Require_Text ("src/backup-remote.adb", "pcloud_progress_samples");
   Require_Text ("src/backup-remote.adb", "Set_Permissions (Temp_Path, 8#600#)");
   Require_Text ("src/backup-cli.adb", "Clean_PCloud_Temporary");
   Require_Text ("src/backup-cli.adb", "Check_PCloud_Remote");
   Require_Text ("src/backup-cli.adb", "pcloud_upload_progress");
   Require_Text ("src/backup-cli.adb", "pcloud_poll_progress");
   Require_Text ("src/backup-cli.adb", "pcloud_check_quota");
   Require_Text ("src/backup-cli.adb", "pcloud_create_parents");
   Require_Text ("src/backup-cli.adb", "pcloud_token_cache_file");
   Require_Text ("src/backup-cli.adb", "pcloud_clean_recursive");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_upload_progress");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_poll_progress");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_check_quota");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_create_parents");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_token_cache_file");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_clean_recursive");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "--pcloud-clean-temp");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "--pcloud-check");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "pcloud_poll_progress=true");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "pcloud_check_quota=true");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "pcloud_create_parents=true");
   Require_Text ("src/backup-cli.adb", "Print_PCloud_OAuth_URL");
   Require_Text ("src/backup-cli.adb", "Print_PCloud_OAuth_Token");
   Require_Text ("src/backup-cli.adb", "Print_PCloud_Token_Config_Hints");
   Require_Text ("src/backup-remote.adb", "Exchange_PCloud_Authorization_Code");
   Require_Text ("src/backup-remote.adb", "PCloud_Token_URI");
   Require_Text ("tools/cli_surface.conf", "pcloud-oauth-url");
   Require_Text ("tools/cli_surface.conf", "pcloud-oauth-token");
   Require_Text ("tools/cli_surface.conf", "proton-drive-login");
   Require_Text ("tools/cli_surface.conf", "pcloud-check");
   Require_Text ("docs/PCLOUD.md", "Troubleshooting");
   Require_Text ("docs/PCLOUD.md", "Provider Capabilities And Limits");
   Require_Text ("docs/PCLOUD.md", "checksumfile");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud upload, readback verify, and index publish succeed");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud token-file auth uploads and verifies");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud path URL creates folder path and uploads");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud upload publishes final objects through renamefile");
   Require_Text ("tools/src/check_google_drive_compatibility.adb", "BACKUP_GOOGLE_DRIVE_COMPAT_REMOTE");
   Require_Text ("tools/src/check_google_drive_compatibility.adb", "BACKUP_GOOGLE_DRIVE_COMPAT_STRICT");
   Require_Text ("tools/src/check_google_drive_compatibility.adb", "BACKUP_GOOGLE_DRIVE_COMPAT_ALLOW_FIXTURE");
   Require_Text ("tools/src/check_google_drive_compatibility.adb", "BACKUP_GOOGLE_DRIVE_COMPAT_TOKEN_FILE");
   Require_Text ("tools/src/check_google_drive_compatibility.adb", "BACKUP_GOOGLE_DRIVE_COMPAT_REFRESH_TOKEN");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "backup pCloud compatibility gate passed");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "BACKUP_PCLOUD_COMPAT_REMOTE");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "BACKUP_PCLOUD_COMPAT_STRICT");
   Require_Text ("docs/TESTING.md", "Release CI should run with `BACKUP_PCLOUD_COMPAT_STRICT=1`");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "BACKUP_PCLOUD_COMPAT_ALLOW_FIXTURE");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "BACKUP_PCLOUD_COMPAT_TOKEN_FILE");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "BACKUP_PCLOUD_COMPAT_PATH_REMOTE");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "BACKUP_PCLOUD_COMPAT_REGION");
   Require_Text (".github/workflows/ci.yml", "BACKUP_PCLOUD_COMPAT_PATH_REMOTE");
   Require_Text (".github/workflows/ci.yml", "BACKUP_PCLOUD_COMPAT_REGION");
   Require_Text (".github/workflows/ci.yml", "BACKUP_PCLOUD_COMPAT_STRICT");
   Require_Text ("src/backup-remote.adb", "Project_Tools.JSON");
   Require_Text ("../project_tools/src/project_tools-json.ads", "package Project_Tools.JSON");
   Require_Text ("../project_tools/src/project_tools-json.adb", "Find_Object_Field");
   Require_Text ("src/backup-remote.adb", "PCloud_JSON_Array_First_Number");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "checksumfile SHA-256");
   Require_Text ("src/backup-remote.adb", "Digest_File_SHA1_Hex");
   Require_Text ("src/backup-remote.adb", "pCloud remote archive SHA-1 mismatch");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud SHA-1-only checksum metadata verifies upload");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud SHA-1 checksum mismatch is rejected");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud temporary upload names include collision-resistant nonce");
   Require_Text ("src/backup-remote.adb", "account region");
   Require_Text ("src/backup-remote.adb", "PCloud_Error_Diagnostic");
   Require_Text ("src/backup-remote.adb", "PCloud_JSON_File_Object_Field");
   Require_Text ("src/backup-remote.adb", "PCloud_Checksum_Metadata");
   Require_Text ("src/backup-remote.ads", "PCloud_Refresh_Token");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_refresh_token");
   Require_Text ("src/backup-remote.ads", "PCloud_Large_Upload_Threshold");
   Require_Text ("src/backup-cli.adb", "pcloud_large_upload_threshold");
   Require_Text ("src/backup-jobs.adb", "remote_pcloud_large_upload_threshold");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "pCloud large upload uses streamed uploadfile path");
   Require_Text ("tools/src/check_pcloud_compatibility.adb", "--sync");
   Require_Text ("REMOTE_TRANSPORT.md", "checksumfile");
   Require_Text ("REMOTE_TRANSPORT.md", "uploadtransfer");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Google Drive token-file auth uploads and verifies");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Google Drive refresh-token auth uploads and verifies");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "backup_http_remote_live_tests-");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Usable_Temp");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "TMPDIR");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "TMP");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "TEMP");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Ada.Directories.Current_Directory");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Ada.Directories.Compose");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "function Path");
   Require_Text ("tests/src/backup_http_remote_live_tests.adb", "Current_Process_Id");
   Require_Text ("docs/TESTING.md", "BACKUP_S3_COMPAT_STRICT=1");
   Require_Text ("docs/TESTING.md", "BACKUP_S3_COMPAT_ALLOW_FIXTURE=1");
   Require_Text ("docs/TESTING.md", "BACKUP_GOOGLE_DRIVE_COMPAT_STRICT=1");
   Require_Text ("docs/TESTING.md", "Release CI should run with `BACKUP_GOOGLE_DRIVE_COMPAT_STRICT=1`");
   Require_Text ("docs/TESTING.md", "BACKUP_GOOGLE_DRIVE_COMPAT_ALLOW_FIXTURE=1");
   Require_Text ("README.md", "Bash completion can be enabled");
   Require_Text ("docs/RELEASE.md", "Bash completion smoke");
   Require_Text ("docs/CLI_COMPATIBILITY.md", "CLI Compatibility Policy");
   Require_Text ("docs/CLI_COMPATIBILITY.md", "major release");
   Require_Text ("docs/CLI_SURFACE.md", "## Command Modes");
   Require_Text ("docs/CLI_SURFACE.md", "## Conflict Groups");
   Require_Text ("docs/CLI_SURFACE.md", "remote-direction");
   Require_Text ("docs/CLI_SURFACE.md", "restore-conflict-policy");
   Require_Text
     ("docs/history/PHASE22_COMPLETENESS.md",
      "password-backed indexing or encrypted archive creation verifies");
   Require_Text ("share/man/man1/backup.1", "SHELL COMPLETION");
   Require_Text ("share/man/man1/backup.1", "--help-advanced");
   Require_Text ("share/man/man1/backup.1", "ADVANCED OPTIONS");
   Require_Text ("share/man/man1/backup.1", "--incremental-from ARCHIVE");
   Require_Text ("share/man/man1/backup.1", "Supported query fields include");
   Require_Text ("share/completions/_backup", "--remote-config");
   Require_Text ("share/completions/_backup", "--incremental-from-manifest");
   Require_Text ("share/completions/_backup", "aes256-gcm");
   Require_Text ("share/completions/_backup", "store-link");
   Require_Text ("tools/src/check_fish_completion.adb", "backup fish completion smoke");
   Require_Text ("tools/src/check_fish_completion.adb", "backup completion check passed");
   Require_Text ("tools/src/check_zsh_completion.adb", "backup zsh completion smoke");
   Require_Text ("tools/src/check_zsh_completion.adb", "backup completion check passed");
   Require_Text ("tools/src/check_powershell_completion.adb", "backup powershell completion smoke");
   Require_Text ("tools/src/check_powershell_completion.adb", "backup completion check passed");
   Require_Text ("tools/src/generate_manpage.adb", "ADVANCED OPTIONS");
   Require_Text ("tools/src/generate_cli_surface.adb", "messages.catalog");
   Require_Text ("tools/src/generate_cli_surface.adb", "backup-cli_surface.ads");
   Require_Text ("tools/src/generate_cli_surface.adb", "CLI_SURFACE.md");
   Require_Text ("tools/cli_surface.conf", "option|compression");
   Require_Text ("tools/cli_surface.conf", "mode|remote-restore");
   Require_Text ("tools/cli_surface.conf", "conflict|catalog-command");
   Require_Text ("tools/src/check_cli_surface.adb", "backup CLI surface generation check passed");
   Require_Text ("tools/src/check_cli_surface.adb", "src/backup-cli_surface.ads");
   Require_Text ("tools/src/check_cli_surface.adb", "docs/CLI_SURFACE.md");
   Require_Text ("tools/src/check_cli_surface.adb", "generated CLI surface artifact differs");
   Require_Text ("tools/src/check_manpage.adb", "backup man page generation check passed");
   Require_Text (".gitignore", "/obj/");
   Require_Text (".gitignore", "/bin/");
   Require_Text (".gitignore", "/alire/");
   Require_Text (".gitignore", "/config/");
   Require_Text (".gitignore", "/tools/obj/");
   Require_Text (".gitignore", "/tools/bin/");
   Require_Text (".gitignore", "/tests/obj/");
   Require_Text (".gitignore", "/tests/bin/");
   Require_Text (".gitignore", "/tests/alire/");
   Require_Text (".gitignore", "/tests/config/");
   Require_Text (".gitignore", "/tests/tmp*/");
   Require_Text (".gitignore", "/bin/gnatprove/");

   Run
     ("windows platform source check", Root, Env,
      [new String'("BACKUP_TARGET_OS=windows"), new String'(Alr),
       new String'("exec"), new String'("--"), new String'("gprbuild"),
       new String'("-f"), new String'("-P"), new String'("backup.gpr")]);
   Run ("alr build", Root, Alr, [new String'("build")]);
   if Ada.Directories.Exists (Root & "/obj/spark") then
      Project_Tools.Files.Delete_Tree (Root & "/obj/spark");
   end if;
   Run
     ("backup GNATprove", Root, Alr,
      [new String'("exec"), new String'("--"), new String'("gnatprove"),
       new String'("-P"), new String'("backup_spark.gpr"),
       new String'("--level=4")]);
   if Ada.Directories.Exists (Install_Prefix) then
      Project_Tools.Files.Delete_Tree (Install_Prefix);
   end if;

   Run
     ("install smoke", Root, Alr,
      [new String'("exec"), new String'("--"), new String'("gprinstall"),
       new String'("-p"), new String'("-P"), new String'("backup.gpr"),
       new String'("--prefix=" & Install_Prefix)]);
   Require_Absolute_Directory (Install_Prefix & "/bin");
   Require_Absolute_Directory (Install_Prefix & "/include/backup");
   Require_Absolute_Directory (Install_Prefix & "/share/gpr");
   Require_Absolute_File (Install_Prefix & "/bin/backup");
   Require_Absolute_File (Install_Prefix & "/include/backup/backup.ads");
   Require_Absolute_File (Install_Prefix & "/include/backup/backup-remote.ads");
   Require_Absolute_File (Install_Prefix & "/share/gpr/backup.gpr");
   Require_Absolute_File
     (Install_Prefix & "/share/backup/messages.catalog");
   Require_Absolute_Directory (Install_Prefix & "/share/backup");
   Require_Absolute_Directory (Install_Prefix & "/share/man");
   Require_Absolute_Directory (Install_Prefix & "/share/completions");
   Require_Absolute_Directory (Install_Prefix & "/share/examples/backup");
   Require_Absolute_File (Install_Prefix & "/share/man/man1/backup.1");
   Require_Absolute_File (Install_Prefix & "/share/completions/backup.bash");
   Require_Absolute_File (Install_Prefix & "/share/completions/backup.fish");
   Require_Absolute_File (Install_Prefix & "/share/completions/backup.ps1");
   Require_Absolute_File (Install_Prefix & "/share/completions/_backup");
   Require_Absolute_File (Install_Prefix & "/share/examples/backup/example.conf");
   Run
     ("installed backup version smoke", Root,
      Install_Prefix & "/bin/backup", [new String'("--version")]);

   if Ada.Directories.Exists (Package_Prefix) then
      Project_Tools.Files.Delete_Tree (Package_Prefix);
   end if;
   Run
     ("tools build", Root, Alr,
      [new String'("exec"), new String'("--"), new String'("gprbuild"),
       new String'("-P"), new String'("tools/tools.gpr")]);

   Run
     ("release package smoke", Root, "tools/bin/package_release",
      [new String'(Package_Prefix)]);
   Require_Absolute_File
     (Package_Prefix & "/backup-release-smoke.tar.gz");
   Require_Absolute_File
     (Package_Prefix & "/backup-release-smoke.tar.gz.cksum");
   Require_Absolute_File (Package_Prefix & "/MANIFEST.txt");

   Run
     ("CLI surface generation check", Root, "tools/bin/check_cli_surface",
      [new String'("tools/cli_surface.conf")]);

   Run
     ("man page generation check", Root, "tools/bin/check_manpage",
      [new String'("share/man/man1/backup.1")]);

   Run
     ("bash completion smoke", Root, "tools/bin/check_bash_completion", []);
   Run
     ("fish completion smoke", Root, "tools/bin/check_fish_completion", []);
   Run
     ("zsh completion smoke", Root, "tools/bin/check_zsh_completion", []);
   Run
     ("powershell completion smoke", Root, "tools/bin/check_powershell_completion", []);

   Run ("tests build", Root & "/tests", Alr, [new String'("build")]);
   Run ("active tests", Root & "/tests", "./bin/tests", []);
   Run
     ("HTTP remote live tests", Root & "/tests",
      "./bin/backup_http_remote_live_tests", []);
   Run
     ("S3 compatibility gate", Root, "tools/bin/check_s3_compatibility", []);
   Run
     ("Google Drive compatibility gate", Root, "tools/bin/check_google_drive_compatibility", []);
   Run
     ("pCloud compatibility gate", Root, "tools/bin/check_pcloud_compatibility", []);
   Run
     ("Proton Drive compatibility gate", Root, "tools/bin/check_proton_drive_compatibility", []);
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/tests/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/tools/obj");

   Ada.Text_IO.Put_Line ("backup release checklist passed");
exception
   when Program_Error =>
      Ada.Text_IO.Put_Line ("backup release checklist failed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Check_All;
