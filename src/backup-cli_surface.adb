--  Generated from tools/cli_surface.conf by tools/bin/generate_cli_surface.
package body Backup.CLI_Surface
  with SPARK_Mode => On
is
   function Message_Key (Line : Help_Line) return String is
   begin
      case Line is
         when Title => return "help.title";
         when Usage => return "help.usage";
         when Create => return "help.create";
         when List => return "help.list";
         when Verify => return "help.verify";
         when Extract => return "help.extract";
         when Job => return "help.job";
         when Common => return "help.common";
         when Common_Line1 => return "help.common.line1";
         when Common_Line2 => return "help.common.line2";
         when Common_Line3 => return "help.common.line3";
         when Restore => return "help.restore";
         when Restore_Line1 => return "help.restore.line1";
         when Remote => return "help.remote";
         when Diagnostics => return "help.diagnostics";
         when Json_Errors => return "help.json_errors";
         when Advanced => return "help.advanced";
         when Advanced_remote1 => return "help.advanced.remote1";
         when Advanced_remote2 => return "help.advanced.remote2";
         when Advanced_catalog1 => return "help.advanced.catalog1";
         when Advanced_catalog2 => return "help.advanced.catalog2";
         when Advanced_jobs => return "help.advanced.jobs";
         when Advanced_incremental => return "help.advanced.incremental";
         when Advanced_encryption => return "help.advanced.encryption";
         when Advanced_restore => return "help.advanced.restore";
         when Advanced_diagnostics => return "help.advanced.diagnostics";
         when Advanced_pcloud => return "help.advanced.pcloud";
         when Advanced_pcloud_token => return "help.advanced.pcloud_token";
         when Advanced_proton_drive_login => return "help.advanced.proton_drive_login";
         when Advanced_pcloud_clean => return "help.advanced.pcloud_clean";
         when Advanced_pcloud_check => return "help.advanced.pcloud_check";
      end case;
   end Message_Key;

   function Display_Role (Line : Help_Line) return Help_Role is
   begin
      case Line is
         when Title => return Role_Header;
         when Usage => return Role_Info;
         when Create => return Role_Muted;
         when List => return Role_Muted;
         when Verify => return Role_Muted;
         when Extract => return Role_Muted;
         when Job => return Role_Muted;
         when Common => return Role_Info;
         when Common_Line1 => return Role_Muted;
         when Common_Line2 => return Role_Muted;
         when Common_Line3 => return Role_Muted;
         when Restore => return Role_Info;
         when Restore_Line1 => return Role_Muted;
         when Remote => return Role_Muted;
         when Diagnostics => return Role_Info;
         when Json_Errors => return Role_Muted;
         when Advanced => return Role_Info;
         when Advanced_remote1 => return Role_Muted;
         when Advanced_remote2 => return Role_Muted;
         when Advanced_catalog1 => return Role_Muted;
         when Advanced_catalog2 => return Role_Muted;
         when Advanced_jobs => return Role_Muted;
         when Advanced_incremental => return Role_Muted;
         when Advanced_encryption => return Role_Muted;
         when Advanced_restore => return Role_Muted;
         when Advanced_diagnostics => return Role_Muted;
         when Advanced_pcloud => return Role_Muted;
         when Advanced_pcloud_token => return Role_Muted;
         when Advanced_proton_drive_login => return Role_Muted;
         when Advanced_pcloud_clean => return Role_Muted;
         when Advanced_pcloud_check => return Role_Muted;
      end case;
   end Display_Role;
end Backup.CLI_Surface;
