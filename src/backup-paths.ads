with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

package Backup.Paths is
   type Validation_Status is
     (Valid,
      Empty_Path,
      Absolute_Path,
      Empty_Component,
      Current_Component,
      Parent_Component,
      Escapes_Root,
      Invalid_Prefix);

   type File_System_Path is record
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Archive_Path is record
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Normalize_File_System_Path
     (Path : String)
      return File_System_Path;

   function To_String
     (Path : File_System_Path)
      return String;

   function Same_File_System_Path
     (Left  : File_System_Path;
      Right : File_System_Path)
      return Boolean;

   function Validate_Archive_Fragment
     (Path        : String;
      Allow_Empty : Boolean := False)
      return Validation_Status;

   function Validate_Prefix
     (Prefix : String)
      return Validation_Status;

   function Make_Archive_Path
     (Path   : String;
      Result : out Archive_Path)
      return Validation_Status;

   function To_String
     (Path : Archive_Path)
      return String;

   function "<"
     (Left  : Archive_Path;
      Right : Archive_Path)
      return Boolean;

   function "="
     (Left  : Archive_Path;
      Right : Archive_Path)
      return Boolean;

   function Join
     (Left   : Archive_Path;
      Right  : String;
      Result : out Archive_Path)
      return Validation_Status;

   function Apply_Prefix
     (Prefix : String;
      Path   : Archive_Path;
      Result : out Archive_Path)
      return Validation_Status;

   function Derive_Archive_Path
     (Input_Root : File_System_Path;
      Descendant : File_System_Path;
      Result     : out Archive_Path)
      return Validation_Status;

   package File_System_Path_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => File_System_Path);

   function Contains_Duplicate_File_System_Path
     (Paths : File_System_Path_Vectors.Vector)
      return Boolean;

   package Archive_Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => Archive_Path);

   function Insert_Archive_Path
     (Set  : in out Archive_Path_Sets.Set;
      Path : Archive_Path)
      return Boolean;

end Backup.Paths;
