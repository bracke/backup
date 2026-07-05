with Ada.Containers;
with Ada.Directories;
with Ada.Text_IO;


package body Backup.Ignore is
   use Ada.Strings.Unbounded;

   function Normalize_Separators
     (Text : String)
      return String
   is
   begin
      if Text'Length = 0 then
         return "";
      end if;

      declare
         Result : String (1 .. Text'Length);
         Last   : Natural := 0;
      begin
         for Ch of Text loop
            Last := Last + 1;
            if Ch = '\' then
               Result (Last) := '/';
            else
               Result (Last) := Ch;
            end if;
         end loop;

         return Result (1 .. Last);
      end;
   end Normalize_Separators;

   function Normalize_Pattern
     (Text : String)
      return String
   is
   begin
      if Text'Length = 0 then
         return "";
      end if;

      declare
         Result : String (1 .. Text'Length * 2);
         Last   : Natural := 0;
         Index  : Natural := Text'First;

         procedure Append_Char (Ch : Character) is
         begin
            Last := Last + 1;
            Result (Last) := Ch;
         end Append_Char;
      begin
         while Index <= Text'Last loop
            if Text (Index) = '\'
              and then Index < Text'Last
              and then Text (Index + 1) in '[' | ']' | '?' | '!' | '#' | ' '
            then
               Append_Char ('\');
               Append_Char (Text (Index + 1));
               Index := Index + 2;
            else
               if Text (Index) = '\' then
                  Append_Char ('/');
               else
                  Append_Char (Text (Index));
               end if;
               Index := Index + 1;
            end if;
         end loop;

         return Result (1 .. Last);
      end;
   end Normalize_Pattern;

   function Strip_Line_Ending
     (Text : String)
      return String
   is
      Last : Natural := Text'Last;
   begin
      if Text'Length = 0 then
         return "";
      end if;

      while Last >= Text'First
        and then (Text (Last) = ASCII.LF or else Text (Last) = ASCII.CR)
      loop
         if Last = Text'First then
            return "";
         end if;
         Last := Last - 1;
      end loop;

      return Text (Text'First .. Last);
   end Strip_Line_Ending;

   function Has_Separator
     (Text : String)
      return Boolean
   is
   begin
      for Ch of Text loop
         if Ch = '/' then
            return True;
         end if;
      end loop;
      return False;
   end Has_Separator;

   function Ends_With_Unescaped_Slash
     (Text : String)
      return Boolean
   is
   begin
      return Text'Length > 0 and then Text (Text'Last) = '/';
   end Ends_With_Unescaped_Slash;

   procedure Add_Diagnostic
     (Ignore_File_Path : String;
      Line_Number      : Positive;
      Original_Text    : String;
      Kind             : Diagnostic_Kind;
      Message          : String;
      Diagnostics      : in out Diagnostic_Vectors.Vector)
   is
   begin
      Diagnostics.Append
        (Diagnostic'(Ignore_File_Path => To_Unbounded_String (Ignore_File_Path),
          Line_Number      => Line_Number,
          Original_Text    => To_Unbounded_String (Original_Text),
          Kind             => Kind,
          Message          => To_Unbounded_String (Message)));
   end Add_Diagnostic;

   function Validate_Double_Star
     (Pattern : String)
      return Boolean
   is
      Start : Positive := Pattern'First;
      Stop  : Natural;
   begin
      if Pattern'Length = 0 then
         return False;
      end if;

      loop
         Stop := Start;
         while Stop <= Pattern'Last and then Pattern (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         declare
            Component : constant String := Pattern (Start .. Stop - 1);
         begin
            if Component'Length > 0 then
               for Index in Component'Range loop
                  if Component (Index) = '*' then
                     if Component = "**" then
                        null;
                     elsif Index < Component'Last
                       and then Component (Index + 1) = '*'
                     then
                        return False;
                     end if;
                  end if;
               end loop;
            end if;
         end;

         exit when Stop > Pattern'Last;
         Start := Stop + 1;
      end loop;

      return True;
   end Validate_Double_Star;

   function Validate_Components
     (Pattern : String;
      Kind    : out Diagnostic_Kind;
      Message : out Unbounded_String)
      return Boolean
   is
      Start : Positive := Pattern'First;
      Stop  : Natural;
   begin
      if Pattern'Length = 0 then
         Kind := Empty_Effective_Pattern;
         Message := To_Unbounded_String ("ignore rule has no pattern text");
         return False;
      end if;

      loop
         Stop := Start;
         while Stop <= Pattern'Last and then Pattern (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         declare
            Component : constant String := Pattern (Start .. Stop - 1);
         begin
            if Component = "" then
               Kind := Empty_Path_Component;
               Message := To_Unbounded_String
                 ("ignore pattern contains an empty path component");
               return False;
            elsif Component = "." then
               Kind := Current_Path_Component;
               Message := To_Unbounded_String
                 ("ignore pattern contains unsupported . component");
               return False;
            elsif Component = ".." then
               Kind := Parent_Path_Component;
               Message := To_Unbounded_String
                 ("ignore pattern contains unsupported .. component");
               return False;
            end if;
         end;

         exit when Stop > Pattern'Last;
         Start := Stop + 1;
      end loop;

      Kind := Empty_Effective_Pattern;
      Message := Null_Unbounded_String;
      return True;
   end Validate_Components;

   function Has_Unsupported_Escape
     (Text : String)
      return Boolean
   is
   begin
      for Index in Text'Range loop
         if Text (Index) = '\'
           and then (Index = Text'Last
                     or else Text (Index + 1) not in '[' | ']' | '?' | '!' | '#' | ' ')
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Unsupported_Escape;

   function Bracket_Globs_Are_Valid
     (Pattern : String)
      return Boolean
   is
      Index : Natural := Pattern'First;
   begin
      while Index <= Pattern'Last loop
         if Pattern (Index) = '\' then
            Index := Index + 2;
         elsif Pattern (Index) = '[' then
            declare
               Cursor    : Natural := Index + 1;
               Had_Item  : Boolean := False;
               Last_Item : Character := Character'Val (0);
            begin
               if Cursor <= Pattern'Last
                 and then Pattern (Cursor) in '!' | '^'
               then
                  Cursor := Cursor + 1;
               end if;

               if Cursor <= Pattern'Last and then Pattern (Cursor) = ']' then
                  Had_Item := True;
                  Last_Item := ']';
                  Cursor := Cursor + 1;
               end if;

               while Cursor <= Pattern'Last and then Pattern (Cursor) /= ']' loop
                  declare
                     Current : Character := Pattern (Cursor);
                  begin
                     if Current = '\' and then Cursor < Pattern'Last then
                        Cursor := Cursor + 1;
                        Current := Pattern (Cursor);
                     end if;

                     if Current = '-'
                       and then Had_Item
                       and then Cursor < Pattern'Last
                       and then Pattern (Cursor + 1) /= ']'
                     then
                        Cursor := Cursor + 1;
                        if Pattern (Cursor) = '\' and then Cursor < Pattern'Last then
                           Cursor := Cursor + 1;
                        end if;
                        if Last_Item > Pattern (Cursor) then
                           return False;
                        end if;
                     else
                        Had_Item := True;
                        Last_Item := Current;
                     end if;
                  end;
                  Cursor := Cursor + 1;
               end loop;

               if Cursor > Pattern'Last or else not Had_Item then
                  return False;
               end if;
               Index := Cursor + 1;
            end;
         else
            Index := Index + 1;
         end if;
      end loop;

      return True;
   end Bracket_Globs_Are_Valid;


   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   function Is_Valid_Relative_Path
     (Text        : String;
      Allow_Empty : Boolean)
      return Boolean
   is
      Start : Positive;
      Stop  : Natural;
   begin
      if Text'Length = 0 then
         return Allow_Empty;
      end if;

      if Text (Text'First) = '/' then
         return False;
      end if;

      Start := Text'First;
      loop
         Stop := Start;
         while Stop <= Text'Last and then Text (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         declare
            Component : constant String := Text (Start .. Stop - 1);
         begin
            if Component = ""
              or else Component = "."
              or else Component = ".."
            then
               return False;
            end if;
         end;

         exit when Stop > Text'Last;
         Start := Stop + 1;
      end loop;

      return True;
   end Is_Valid_Relative_Path;

   function Split_Path
     (Text : String)
      return String_Vectors.Vector
   is
      Parts : String_Vectors.Vector;
      Start : Positive;
      Stop  : Natural;
   begin
      if Text'Length = 0 then
         return Parts;
      end if;

      Start := Text'First;
      loop
         Stop := Start;
         while Stop <= Text'Last and then Text (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;
         Parts.Append (Text (Start .. Stop - 1));
         exit when Stop > Text'Last;
         Start := Stop + 1;
      end loop;

      return Parts;
   end Split_Path;

   function Component_Glob_Matches
     (Pattern       : String;
      Pattern_Index : Positive;
      Text          : String;
      Text_Index    : Positive)
      return Boolean
   is
   begin
      if Pattern_Index > Pattern'Last then
         return Text_Index > Text'Last;
      end if;

      if Pattern (Pattern_Index) = '*' then
         if Component_Glob_Matches
              (Pattern,
               Pattern_Index + 1,
               Text,
               Text_Index)
         then
            return True;
         end if;

         return Text_Index <= Text'Last
           and then Component_Glob_Matches
             (Pattern,
              Pattern_Index,
              Text,
              Text_Index + 1);
      elsif Pattern (Pattern_Index) = '?' then
         return Text_Index <= Text'Last
           and then Component_Glob_Matches
             (Pattern,
              Pattern_Index + 1,
              Text,
              Text_Index + 1);
      elsif Pattern (Pattern_Index) = '\'
        and then Pattern_Index < Pattern'Last
      then
         return Text_Index <= Text'Last
           and then Pattern (Pattern_Index + 1) = Text (Text_Index)
           and then Component_Glob_Matches
             (Pattern,
              Pattern_Index + 2,
              Text,
              Text_Index + 1);
      elsif Pattern (Pattern_Index) = '[' then
         declare
            Cursor  : Natural := Pattern_Index + 1;
            Negated : Boolean := False;
            Matched : Boolean := False;
            Had     : Boolean := False;
            Last_Ch : Character := Character'Val (0);
         begin
            if Text_Index > Text'Last then
               return False;
            end if;

            if Cursor <= Pattern'Last and then Pattern (Cursor) in '!' | '^' then
               Negated := True;
               Cursor := Cursor + 1;
            end if;

            if Cursor <= Pattern'Last and then Pattern (Cursor) = ']' then
               Had := True;
               Last_Ch := ']';
               Matched := Text (Text_Index) = ']';
               Cursor := Cursor + 1;
            end if;

            while Cursor <= Pattern'Last and then Pattern (Cursor) /= ']' loop
               declare
                  Current : Character := Pattern (Cursor);
               begin
                  if Current = '\' and then Cursor < Pattern'Last then
                     Cursor := Cursor + 1;
                     Current := Pattern (Cursor);
                  end if;

                  if Current = '-'
                    and then Had
                    and then Cursor < Pattern'Last
                    and then Pattern (Cursor + 1) /= ']'
                  then
                     Cursor := Cursor + 1;
                     declare
                        Range_End : Character := Pattern (Cursor);
                     begin
                        if Range_End = '\' and then Cursor < Pattern'Last then
                           Cursor := Cursor + 1;
                           Range_End := Pattern (Cursor);
                        end if;
                        if Last_Ch <= Text (Text_Index)
                          and then Text (Text_Index) <= Range_End
                        then
                           Matched := True;
                        end if;
                        Last_Ch := Range_End;
                     end;
                  else
                     Had := True;
                     Last_Ch := Current;
                     if Text (Text_Index) = Current then
                        Matched := True;
                     end if;
                  end if;
               end;
               Cursor := Cursor + 1;
            end loop;

            return Cursor <= Pattern'Last
              and then Had
              and then (if Negated then not Matched else Matched)
              and then Component_Glob_Matches
                (Pattern,
                 Cursor + 1,
                 Text,
                 Text_Index + 1);
         end;
      else
         return Text_Index <= Text'Last
           and then Pattern (Pattern_Index) = Text (Text_Index)
           and then Component_Glob_Matches
             (Pattern,
              Pattern_Index + 1,
              Text,
              Text_Index + 1);
      end if;
   end Component_Glob_Matches;

   function Component_Glob_Matches
     (Pattern : String;
      Text    : String)
      return Boolean
   is
   begin
      if Pattern'Length = 0 then
         return Text'Length = 0;
      elsif Text'Length = 0 then
         return Component_Glob_Matches
           (Pattern,
            Pattern'First,
            Text,
            Text'Last + 1);
      else
         return Component_Glob_Matches
           (Pattern,
            Pattern'First,
            Text,
            Text'First);
      end if;
   end Component_Glob_Matches;

   function Path_Glob_Matches
     (Pattern_Parts : String_Vectors.Vector;
      Pattern_Index : Positive;
      Path_Parts    : String_Vectors.Vector;
      Path_Index    : Positive)
      return Boolean
   is
      Pattern_Last : constant Natural := Natural (Pattern_Parts.Length);
      Path_Last    : constant Natural := Natural (Path_Parts.Length);
   begin
      if Pattern_Index > Pattern_Last then
         return Path_Index > Path_Last;
      end if;

      if Pattern_Parts.Element (Pattern_Index) = "**" then
         if Pattern_Index = Pattern_Last then
            return True;
         end if;

         for Candidate in Path_Index .. Path_Last + 1 loop
            if Path_Glob_Matches
                 (Pattern_Parts,
                  Pattern_Index + 1,
                  Path_Parts,
                  Candidate)
            then
               return True;
            end if;
         end loop;

         return False;
      end if;

      return Path_Index <= Path_Last
        and then Component_Glob_Matches
          (Pattern_Parts.Element (Pattern_Index),
           Path_Parts.Element (Path_Index))
        and then Path_Glob_Matches
          (Pattern_Parts,
           Pattern_Index + 1,
           Path_Parts,
           Path_Index + 1);
   end Path_Glob_Matches;

   function Path_Glob_Matches
     (Pattern : String;
      Path    : String)
      return Boolean
   is
      Pattern_Parts : constant String_Vectors.Vector := Split_Path (Pattern);
      Path_Parts    : constant String_Vectors.Vector := Split_Path (Path);
   begin
      return Path_Glob_Matches (Pattern_Parts, 1, Path_Parts, 1);
   end Path_Glob_Matches;

   function Has_Base_Prefix
     (Path      : String;
      Base_Path : String)
      return Boolean
   is
   begin
      if Base_Path'Length = 0 then
         return True;
      elsif Path'Length < Base_Path'Length then
         return False;
      elsif Path (Path'First .. Path'First + Base_Path'Length - 1) /=
        Base_Path
      then
         return False;
      elsif Path'Length = Base_Path'Length then
         return True;
      else
         return Path (Path'First + Base_Path'Length) = '/';
      end if;
   end Has_Base_Prefix;

   function Strip_Base
     (Path      : String;
      Base_Path : String)
      return String
   is
   begin
      if Base_Path'Length = 0 then
         return Path;
      elsif Path'Length = Base_Path'Length then
         return "";
      else
         return Path (Path'First + Base_Path'Length + 1 .. Path'Last);
      end if;
   end Strip_Base;

   function Rule_Matches
     (Item          : Rule;
      Relative_Path : String;
      Is_Directory  : Boolean)
      return Boolean
   is
      Pattern : constant String := To_String (Item.Normalized_Pattern);
      Parts   : constant String_Vectors.Vector := Split_Path (Relative_Path);
   begin
      pragma Assert (Pattern'Length > 0, "matching rule has pattern text");

      if Relative_Path'Length = 0 then
         return False;
      end if;

      if Item.Directory_Only and then not Is_Directory then
         return False;
      end if;

      if Item.Anchored or else Item.Contains_Separator then
         return Path_Glob_Matches (Pattern, Relative_Path);
      end if;

      for Index in 1 .. Natural (Parts.Length) loop
         if Component_Glob_Matches (Pattern, Parts.Element (Index)) then
            return True;
         end if;
      end loop;

      return False;
   end Rule_Matches;

   function Parse_Line
     (Ignore_File_Path : String;
      Line_Number      : Positive;
      Text             : String;
      Rules            : in out Rule_Vectors.Vector;
      Diagnostics      : in out Diagnostic_Vectors.Vector)
      return Parse_Status
   is
      Original     : constant String := Strip_Line_Ending (Text);
      Work_First   : Positive;
      Work_Last    : Natural;
      Negated      : Boolean := False;
      Anchored     : Boolean := False;
      Dir_Only     : Boolean := False;
      Kind         : Diagnostic_Kind;
      Message      : Unbounded_String;
   begin
      if Original'Length = 0 then
         return Parse_Ok;
      end if;

      if Original (Original'First) = '#' then
         return Parse_Ok;
      end if;

      Work_First := Original'First;
      Work_Last := Original'Last;

      if Original'Length >= 2
        and then Original (Original'First) = '\'
        and then Original (Original'First + 1) in '#' | '!'
      then
         Work_First := Original'First + 1;
      elsif Original (Original'First) = '!' then
         Negated := True;
         if Original'Length = 1 then
            Add_Diagnostic
              (Ignore_File_Path,
               Line_Number,
               Original,
               Empty_Effective_Pattern,
               "negation marker is not followed by a pattern",
               Diagnostics);
            return Parse_With_Diagnostics;
         end if;
         Work_First := Original'First + 1;
      end if;

      if Work_First <= Work_Last and then Original (Work_First) = '/' then
         Anchored := True;
         Work_First := Work_First + 1;
      end if;

      if Work_First > Work_Last then
         Add_Diagnostic
           (Ignore_File_Path,
            Line_Number,
            Original,
            Empty_Effective_Pattern,
            "ignore rule has no pattern text",
            Diagnostics);
         return Parse_With_Diagnostics;
      end if;

      declare
         Raw_Pattern : constant String := Original (Work_First .. Work_Last);
         Normalized  : constant String := Normalize_Pattern (Raw_Pattern);
      begin
         if Ends_With_Unescaped_Slash (Normalized) then
            Dir_Only := True;
            if Normalized'Length = 1 then
               Add_Diagnostic
                 (Ignore_File_Path,
                  Line_Number,
                  Original,
                  Empty_Effective_Pattern,
                  "directory-only marker is not preceded by a pattern",
                  Diagnostics);
               return Parse_With_Diagnostics;
            end if;
            Work_Last := Normalized'Last - 1;
         else
            Work_Last := Normalized'Last;
         end if;

         declare
            Pattern : constant String :=
              Normalized (Normalized'First .. Work_Last);
         begin
            if Pattern'Length = 0 then
               Add_Diagnostic
                 (Ignore_File_Path,
                  Line_Number,
                  Original,
                  Empty_Effective_Pattern,
                  "ignore rule has no pattern text",
                  Diagnostics);
               return Parse_With_Diagnostics;
            elsif not Bracket_Globs_Are_Valid (Pattern) then
               Add_Diagnostic
                 (Ignore_File_Path,
                  Line_Number,
                  Original,
                  Unsupported_Bracket_Glob,
                  "bracket glob syntax is malformed",
                  Diagnostics);
               return Parse_With_Diagnostics;
            elsif Has_Unsupported_Escape (Pattern) then
               Add_Diagnostic
                 (Ignore_File_Path,
                  Line_Number,
                  Original,
                  Unsupported_Escape,
                  "unsupported ignore pattern escape",
                  Diagnostics);
               return Parse_With_Diagnostics;
            elsif not Validate_Double_Star (Pattern) then
               Add_Diagnostic
                 (Ignore_File_Path,
                  Line_Number,
                  Original,
                  Invalid_Double_Star,
                  "** must occupy a complete path component",
                  Diagnostics);
               return Parse_With_Diagnostics;
            elsif not Validate_Components (Pattern, Kind, Message) then
               Add_Diagnostic
                 (Ignore_File_Path,
                  Line_Number,
                  Original,
                  Kind,
                  To_String (Message),
                  Diagnostics);
               return Parse_With_Diagnostics;
            end if;

            Rules.Append
              (Rule'(Ignore_File_Path   => To_Unbounded_String (Ignore_File_Path),
                Line_Number        => Line_Number,
                Original_Text      => To_Unbounded_String (Original),
                Normalized_Pattern => To_Unbounded_String (Pattern),
                Negated            => Negated,
                Anchored           => Anchored,
                Directory_Only     => Dir_Only,
                Contains_Separator => Has_Separator (Pattern)));

            pragma Assert
              (Length (Rules.Last_Element.Normalized_Pattern) > 0,
               "parsed ignore rule has non-empty normalized pattern");
            return Parse_Ok;
         end;
      end;
   end Parse_Line;

   function Parse_Text
     (Ignore_File_Path : String;
      Text             : String;
      Rules            : in out Rule_Vectors.Vector;
      Diagnostics      : in out Diagnostic_Vectors.Vector)
      return Parse_Status
   is
      Line_Start : Positive := Text'First;
      Line_No    : Positive := 1;
      Status     : Parse_Status := Parse_Ok;
   begin
      if Text'Length = 0 then
         return Parse_Ok;
      end if;

      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            declare
               Line_Status : Parse_Status;
            begin
               if Index = Line_Start then
                  Line_Status :=
                    Parse_Line
                      (Ignore_File_Path,
                       Line_No,
                       "",
                       Rules,
                       Diagnostics);
               else
                  Line_Status :=
                    Parse_Line
                      (Ignore_File_Path,
                       Line_No,
                       Text (Line_Start .. Index - 1),
                       Rules,
                       Diagnostics);
               end if;

               if Line_Status = Parse_With_Diagnostics then
                  Status := Parse_With_Diagnostics;
               end if;
            end;
            Line_No := Line_No + 1;
            if Index < Text'Last then
               Line_Start := Index + 1;
            end if;
         end if;
      end loop;

      if Line_Start <= Text'Last and then Text (Text'Last) /= ASCII.LF then
         declare
            Line_Status : constant Parse_Status :=
              Parse_Line
                (Ignore_File_Path,
                 Line_No,
                 Text (Line_Start .. Text'Last),
                 Rules,
                 Diagnostics);
         begin
            if Line_Status = Parse_With_Diagnostics then
               Status := Parse_With_Diagnostics;
            end if;
         end;
      end if;

      return Status;
   end Parse_Text;

   function Parse_File
     (Path        : String;
      Rules       : in out Rule_Vectors.Vector;
      Diagnostics : in out Diagnostic_Vectors.Vector)
      return Parse_Status
   is
      File      : Ada.Text_IO.File_Type;
      Line      : String (1 .. 4096);
      Last      : Natural;
      Line_No   : Positive := 1;
      Status    : Parse_Status := Parse_Ok;
   begin
      if not Ada.Directories.Exists (Path) then
         Add_Diagnostic
           (Path,
            1,
            "",
            Empty_Effective_Pattern,
            "ignore file does not exist",
            Diagnostics);
         return Parse_With_Diagnostics;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);
         declare
            Line_Status : constant Parse_Status :=
              Parse_Line
                (Path,
                 Line_No,
                 Line (1 .. Last),
                 Rules,
                 Diagnostics);
         begin
            if Line_Status = Parse_With_Diagnostics then
               Status := Parse_With_Diagnostics;
            end if;
         end;
         Line_No := Line_No + 1;
      end loop;
      Ada.Text_IO.Close (File);
      return Status;
   exception
      when Ada.Text_IO.Name_Error |
           Ada.Text_IO.Use_Error |
           Ada.Text_IO.Device_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Add_Diagnostic
           (Path,
            Line_No,
            "",
            Empty_Effective_Pattern,
            "could not read ignore file",
            Diagnostics);
         return Parse_With_Diagnostics;
   end Parse_File;




   function Evaluate
     (Rules        : Rule_Vectors.Vector;
      Path         : Backup.Paths.Archive_Path;
      Is_Directory : Boolean;
      Base_Path    : String := "")
      return Decision
   is
   begin
      return Evaluate
        (Rules,
         Backup.Paths.To_String (Path),
         Is_Directory,
         Base_Path);
   end Evaluate;

   function Evaluate
     (Rules        : Rule_Vectors.Vector;
      Path         : String;
      Is_Directory : Boolean;
      Base_Path    : String := "")
      return Decision
   is
      Normalized_Path : constant String := Normalize_Separators (Path);
      Normalized_Base : constant String := Normalize_Separators (Base_Path);
      Result          : Decision;
   begin
      Result.Path := To_Unbounded_String (Normalized_Path);
      Result.Base_Path := To_Unbounded_String (Normalized_Base);
      Result.Is_Directory := Is_Directory;

      if not Is_Valid_Relative_Path
        (Normalized_Path, Allow_Empty => False)
      then
         Result.Status := Match_Invalid_Path;
         return Result;
      elsif not Is_Valid_Relative_Path
        (Normalized_Base, Allow_Empty => True)
      then
         Result.Status := Match_Invalid_Base_Path;
         return Result;
      elsif not Has_Base_Prefix (Normalized_Path, Normalized_Base) then
         Result.Relative_Path := Null_Unbounded_String;
         return Result;
      end if;

      declare
         Relative_Path : constant String :=
           Strip_Base (Normalized_Path, Normalized_Base);
      begin
         Result.Relative_Path := To_Unbounded_String (Relative_Path);

         for Index in 1 .. Natural (Rules.Length) loop
            declare
               Item : constant Rule := Rules.Element (Index);
            begin
               if Rule_Matches (Item, Relative_Path, Is_Directory) then
                  Result.Has_Matching_Rule := True;
                  Result.Matching_Rule := Item;

                  if Item.Negated then
                     Result.Result := Not_Ignored;
                     Result.Kind := Rule_Reincludes;
                     Result.Prunes_Descendants := False;
                     Result.Descendants_Unreachable := False;
                  else
                     Result.Result := Ignored;
                     Result.Kind := Rule_Ignores;
                     Result.Prunes_Descendants := Is_Directory;
                     Result.Descendants_Unreachable := Is_Directory;
                  end if;
               end if;
            end;
         end loop;
      end;

      return Result;
   end Evaluate;

end Backup.Ignore;
