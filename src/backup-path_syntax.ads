package Backup.Path_Syntax
  with SPARK_Mode => On
is
   function Is_Slash (Ch : Character) return Boolean;

   function Is_Control (Ch : Character) return Boolean;

   function Clean_Separator (Ch : Character) return Character
     with Post => (if Ch = '\' then Clean_Separator'Result = '/'
                   else Clean_Separator'Result = Ch);

   function Is_Windows_Absolute (Path : String) return Boolean;

   function Is_Absolute (Path : String) return Boolean;

   function Has_Path_Separator (Text : String) return Boolean;

   function Has_Control_Character (Text : String) return Boolean;

   function Is_Dot_Or_Dot_Dot (Text : String) return Boolean;

   function Ends_With
     (Value  : String;
      Suffix : String) return Boolean;

   function Safe_Object_Name (Name : String) return Boolean;

   function Looks_Like_Object (Name : String) return Boolean;

   function Looks_Like_Managed_Object (Name : String) return Boolean;
end Backup.Path_Syntax;
