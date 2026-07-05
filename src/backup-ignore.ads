with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Backup.Paths;

package Backup.Ignore is
   type Match_Result is
     (Not_Ignored,
      Ignored);

   type Parse_Status is
     (Parse_Ok,
      Parse_With_Diagnostics);

   type Match_Status is
     (Match_Ok,
      Match_Invalid_Path,
      Match_Invalid_Base_Path);

   type Diagnostic_Kind is
     (Empty_Effective_Pattern,
      Unsupported_Bracket_Glob,
      Unsupported_Escape,
      Empty_Path_Component,
      Current_Path_Component,
      Parent_Path_Component,
      Invalid_Double_Star);

   type Diagnostic is record
      Ignore_File_Path : Ada.Strings.Unbounded.Unbounded_String;
      Line_Number      : Positive;
      Original_Text    : Ada.Strings.Unbounded.Unbounded_String;
      Kind             : Diagnostic_Kind;
      Message          : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Diagnostic_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Diagnostic);

   type Rule is record
      Ignore_File_Path   : Ada.Strings.Unbounded.Unbounded_String;
      Line_Number        : Positive := 1;
      Original_Text      : Ada.Strings.Unbounded.Unbounded_String;
      Normalized_Pattern : Ada.Strings.Unbounded.Unbounded_String;
      Negated            : Boolean := False;
      Anchored           : Boolean := False;
      Directory_Only     : Boolean := False;
      Contains_Separator : Boolean := False;
   end record;

   package Rule_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Rule);

   type Match_Kind is
     (No_Rule_Matched,
      Rule_Ignores,
      Rule_Reincludes);

   type Decision is record
      Status                  : Match_Status := Match_Ok;
      Result                  : Match_Result := Not_Ignored;
      Has_Matching_Rule       : Boolean := False;
      Matching_Rule           : Rule;
      Kind                    : Match_Kind := No_Rule_Matched;
      Path                    : Ada.Strings.Unbounded.Unbounded_String;
      Base_Path               : Ada.Strings.Unbounded.Unbounded_String;
      Relative_Path           : Ada.Strings.Unbounded.Unbounded_String;
      Is_Directory            : Boolean := False;
      Prunes_Descendants      : Boolean := False;
      Descendants_Unreachable : Boolean := False;
   end record;

   function Parse_Line
     (Ignore_File_Path : String;
      Line_Number      : Positive;
      Text             : String;
      Rules            : in out Rule_Vectors.Vector;
      Diagnostics      : in out Diagnostic_Vectors.Vector)
      return Parse_Status;

   function Parse_Text
     (Ignore_File_Path : String;
      Text             : String;
      Rules            : in out Rule_Vectors.Vector;
      Diagnostics      : in out Diagnostic_Vectors.Vector)
      return Parse_Status;

   function Parse_File
     (Path        : String;
      Rules       : in out Rule_Vectors.Vector;
      Diagnostics : in out Diagnostic_Vectors.Vector)
      return Parse_Status;

   function Evaluate
     (Rules        : Rule_Vectors.Vector;
      Path         : String;
      Is_Directory : Boolean;
      Base_Path    : String := "")
      return Decision;

   function Evaluate
     (Rules        : Rule_Vectors.Vector;
      Path         : Backup.Paths.Archive_Path;
      Is_Directory : Boolean;
      Base_Path    : String := "")
      return Decision;
end Backup.Ignore;
