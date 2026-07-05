--  Generated from tools/cli_surface.conf by tools/bin/generate_cli_surface.
package Backup.CLI_Surface
  with SPARK_Mode => On
is
   type Help_Role is (Role_Header, Role_Info, Role_Muted);

   type Help_Line is
     (Title,
      Usage,
      Create,
      List,
      Verify,
      Extract,
      Job,
      Common,
      Common_Line1,
      Common_Line2,
      Common_Line3,
      Restore,
      Restore_Line1,
      Remote,
      Diagnostics,
      Json_Errors,
      Advanced,
      Advanced_remote1,
      Advanced_remote2,
      Advanced_catalog1,
      Advanced_catalog2,
      Advanced_jobs,
      Advanced_incremental,
      Advanced_encryption,
      Advanced_restore,
      Advanced_diagnostics,
      Advanced_pcloud,
      Advanced_pcloud_token,
      Advanced_proton_drive_login,
      Advanced_pcloud_clean,
      Advanced_pcloud_check);

   subtype Basic_Help_Line is Help_Line range Title .. Json_Errors;
   subtype Advanced_Help_Line is Help_Line range Advanced .. Advanced_pcloud_check;

   function Message_Key (Line : Help_Line) return String;

   function Display_Role (Line : Help_Line) return Help_Role;
end Backup.CLI_Surface;
