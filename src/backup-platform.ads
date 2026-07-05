with Ada.Strings.Unbounded;
with Interfaces;

package Backup.Platform is
   function Prompt_Password return String;

   function Read_Link_Target
     (Path   : String;
      Target : out Ada.Strings.Unbounded.Unbounded_String)
      return Boolean;

   function Create_Symlink
     (Target : String;
      Link   : String)
      return Boolean;

   procedure Owner_Ids
     (Path    : String;
      Present : out Boolean;
      UID     : out Interfaces.Unsigned_32;
      GID     : out Interfaces.Unsigned_32);

   procedure Apply_Owner
     (Path : String;
      UID  : Interfaces.Unsigned_32;
      GID  : Interfaces.Unsigned_32);

   function Set_Permissions
     (Path : String;
      Mode : Interfaces.Unsigned_32)
      return Boolean;

   procedure Apply_Mode
     (Path : String;
      Mode : Interfaces.Unsigned_32);

   function Xattr_Blob (Path : String)
      return Ada.Strings.Unbounded.Unbounded_String;

   function Set_Xattr
     (Path  : String;
      Name  : String;
      Value : String)
      return Boolean;

   function Get_Xattr
     (Path : String;
      Name : String)
      return String;
end Backup.Platform;
