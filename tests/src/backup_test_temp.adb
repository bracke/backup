with Ada.Environment_Variables;

with GNAT.OS_Lib;

package body Backup_Test_Temp is

   function Env (Name : String) return String is
   begin
      if Ada.Environment_Variables.Exists (Name)
        and then Ada.Environment_Variables.Value (Name) /= ""
      then
         return Ada.Environment_Variables.Value (Name);
      end if;

      return "";
   exception
      when others =>
         return "";
   end Env;

   function Base return String is
      Raw : constant String :=
        (if Env ("TMPDIR") /= "" then Env ("TMPDIR")
         elsif Env ("TEMP") /= "" then Env ("TEMP")
         elsif Env ("TMP") /= "" then Env ("TMP")
         else "/tmp");

      --  Resolve_Links so the base matches the canonical form backup produces -- on macOS
      --  this is what turns /tmp into /private/tmp.
      Resolved : constant String :=
        GNAT.OS_Lib.Normalize_Pathname (Raw, Resolve_Links => True);
   begin
      if Resolved'Length > 1
        and then (Resolved (Resolved'Last) = '/' or else Resolved (Resolved'Last) = '\')
      then
         return Resolved (Resolved'First .. Resolved'Last - 1);
      end if;

      return Resolved;
   end Base;

end Backup_Test_Temp;
