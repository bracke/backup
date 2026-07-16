with Ada.Environment_Variables;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Hostkit.Fs;

package body Backup.Platform is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;

   function Windows_User_Name return String is
   begin
      if Ada.Environment_Variables.Exists ("USERDOMAIN")
        and then Ada.Environment_Variables.Exists ("USERNAME")
        and then Ada.Environment_Variables.Value ("USERDOMAIN")'Length > 0
        and then Ada.Environment_Variables.Value ("USERNAME")'Length > 0
      then
         return Ada.Environment_Variables.Value ("USERDOMAIN") & "\" &
           Ada.Environment_Variables.Value ("USERNAME");
      elsif Ada.Environment_Variables.Exists ("USERNAME")
        and then Ada.Environment_Variables.Value ("USERNAME")'Length > 0
      then
         return Ada.Environment_Variables.Value ("USERNAME");
      end if;
      return "";
   exception
      when others =>
         return "";
   end Windows_User_Name;

   function Prompt_Password return String is
      Line : String (1 .. 1024);
      Last : Natural := 0;
   begin
      Ada.Text_IO.Put ("backup password: ");
      Ada.Text_IO.Get_Line (Line, Last);
      return Line (Line'First .. Last);
   exception
      when others =>
         return "";
   end Prompt_Password;

   function Read_Link_Target
     (Path   : String;
      Target : out Unbounded_String)
      return Boolean
   is
      pragma Unreferenced (Path);
   begin
      Target := Null_Unbounded_String;
      return False;
   end Read_Link_Target;

   function Create_Symlink
     (Target : String;
      Link   : String)
      return Boolean
   is
   begin
      --  Delegate to hostkit's CreateSymbolicLinkW (with the allow-unprivileged flag)
      --  rather than spawning "cmd.exe /C mklink", which needs elevation, is brittle to
      --  quote, and failed restore on the CI runner. Hostkit picks the directory-vs-file
      --  flag from the target itself.
      return Hostkit.Fs.Create_Link (Target, Link);
   end Create_Symlink;

   procedure Owner_Ids
     (Path    : String;
      Present : out Boolean;
      UID     : out Interfaces.Unsigned_32;
      GID     : out Interfaces.Unsigned_32)
   is
      pragma Unreferenced (Path);
   begin
      Present := False;
      UID := 0;
      GID := 0;
   end Owner_Ids;

   procedure Apply_Owner
     (Path : String;
      UID  : Interfaces.Unsigned_32;
      GID  : Interfaces.Unsigned_32)
   is
      pragma Unreferenced (Path, UID, GID);
   begin
      null;
   end Apply_Owner;

   function Set_Permissions
     (Path : String;
      Mode : Interfaces.Unsigned_32)
      return Boolean
   is
      User : constant String := Windows_User_Name;
      Status : Integer;
   begin
      if Path'Length = 0 or else User'Length = 0 then
         return False;
      end if;

      if Mode = 8#600# then
         declare
            Args : constant GNAT.OS_Lib.Argument_List :=
              [new String'(Path),
               new String'("/inheritance:r"),
               new String'("/grant:r"),
               new String'(User & ":(R,W)")];
         begin
            Status := GNAT.OS_Lib.Spawn ("icacls.exe", Args);
            return Status = 0;
         end;
      end if;

      return False;
   exception
      when others =>
         return False;
   end Set_Permissions;

   procedure Apply_Mode
     (Path : String;
      Mode : Interfaces.Unsigned_32)
   is
      pragma Unreferenced (Path, Mode);
   begin
      null;
   end Apply_Mode;

   function Xattr_Blob (Path : String) return Unbounded_String is
      pragma Unreferenced (Path);
   begin
      return Null_Unbounded_String;
   end Xattr_Blob;

   function Set_Xattr
     (Path  : String;
      Name  : String;
      Value : String)
      return Boolean
   is
      pragma Unreferenced (Path, Name, Value);
   begin
      return False;
   end Set_Xattr;

   function Get_Xattr
     (Path : String;
      Name : String)
      return String
   is
      pragma Unreferenced (Path, Name);
   begin
      return "";
   end Get_Xattr;
end Backup.Platform;
