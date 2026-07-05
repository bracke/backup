with GNAT.OS_Lib;

package Backup_Tool_Support is
   function Env (Name : String; Default : String := "") return String;
   function Contains (Path : String; Pattern : String) return Boolean;
   function Same_File (Left, Right : String) return Boolean;
   function Tool_Path (Name : String) return String;

   procedure Fail (Message : String);
   procedure Require_File (Path : String; Message : String := "required file is missing");
   procedure Require_Contains (Path : String; Pattern : String; Message : String);
   procedure Ensure_Parent (Path : String);
   procedure Copy_File_To (Source, Target : String);
   procedure Write_Text (Path : String; Content : String);
   procedure Write_Zero_File (Path : String; Size : Natural);
   procedure Remove_Tree (Path : String);
   procedure Run
     (Label   : String;
      Program : String;
      Args    : GNAT.OS_Lib.Argument_List;
      Dir     : String := ".";
      Quiet   : Boolean := False);
end Backup_Tool_Support;
