with Ada.Command_Line;
with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Backup.Ignore;
with Backup.Paths;

procedure Backup_Ignore_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Backup.Ignore.Diagnostic_Kind;
   use type Backup.Ignore.Parse_Status;
   use type Backup.Ignore.Match_Result;
   use type Backup.Ignore.Match_Status;
   use type Backup.Ignore.Match_Kind;
   use type Backup.Paths.Validation_Status;

   Failures : Natural := 0;
   Rules    : Backup.Ignore.Rule_Vectors.Vector;
   Diags    : Backup.Ignore.Diagnostic_Vectors.Vector;

   procedure Check
     (Condition : Boolean;
      Name      : String)
   is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Name);
      end if;
   end Check;

   procedure Reset is
   begin
      Rules.Clear;
      Diags.Clear;
   end Reset;

   function Pattern_At
     (Index : Positive)
      return String
   is
   begin
      return To_String (Rules.Element (Index).Normalized_Pattern);
   end Pattern_At;

   function Original_At
     (Index : Positive)
      return String
   is
   begin
      return To_String (Rules.Element (Index).Original_Text);
   end Original_At;


   function Diagnostic_Message_At
     (Index : Positive)
      return String
   is
   begin
      return To_String (Diags.Element (Index).Message);
   end Diagnostic_Message_At;

   Status : Backup.Ignore.Parse_Status;
begin
   Reset;
   Status := Backup.Ignore.Parse_Line ("root.gitignore", 1, "", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "blank line parses cleanly");
   Check (Rules.Length = 0, "blank line does not produce rule");
   Check (Diags.Length = 0, "blank line does not produce diagnostic");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 2, "# comment", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "comment parses cleanly");
   Check (Rules.Length = 0, "comment does not produce rule");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 3, "\#literal", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "escaped comment parses");
   Check (Rules.Length = 1, "escaped comment emits one rule");
   Check (Pattern_At (1) = "#literal", "escaped comment keeps leading hash");
   Check (not Rules.Element (1).Negated, "escaped comment is not negated");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 4, "!keep.txt", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "negation parses");
   Check (Rules.Length = 1, "negation emits one rule");
   Check (Rules.Element (1).Negated, "negation flag set");
   Check (Pattern_At (1) = "keep.txt", "negation pattern stripped");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 5, "\!literal", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "escaped negation parses");
   Check (not Rules.Element (1).Negated, "escaped negation not negated");
   Check (Pattern_At (1) = "!literal", "escaped negation keeps bang");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 6, "/build/output.o", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "anchored rule parses");
   Check (Rules.Element (1).Anchored, "anchored flag set");
   Check (Rules.Element (1).Contains_Separator, "anchored path separator set");
   Check (Pattern_At (1) = "build/output.o", "anchored slash stripped");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 7, "cache/", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "directory-only rule parses");
   Check (Rules.Element (1).Directory_Only, "directory-only flag set");
   Check (Pattern_At (1) = "cache", "directory slash stripped");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 8, "src/generated/*.adb", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "path pattern parses");
   Check (Rules.Element (1).Contains_Separator, "path pattern has separator");
   Check (Pattern_At (1) = "src/generated/*.adb", "path pattern preserved");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 9, "obj\*.o", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "host separator normalizes");
   Check (Pattern_At (1) = "obj/*.o", "backslash normalized to slash");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 10, "**/*.ali", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "double-star glob parses");
   Check (Pattern_At (1) = "**/*.ali", "double-star pattern preserved");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 11, "file?.txt", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "question glob parses");
   Check (Pattern_At (1) = "file?.txt", "question pattern preserved");

   Reset;
   Status := Backup.Ignore.Parse_Text
     ("root.gitignore",
      "first" & ASCII.LF & "!second" & ASCII.LF & "/third/" & ASCII.LF,
      Rules,
      Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "multiple rules parse");
   Check (Rules.Length = 3, "multiple rules count");
   Check (Pattern_At (1) = "first", "order first preserved");
   Check (Original_At (2) = "!second", "original text preserved");
   Check (Rules.Element (2).Negated, "second negated preserved");
   Check (Rules.Element (3).Anchored, "third anchored preserved");
   Check (Rules.Element (3).Directory_Only, "third directory preserved");
   Check (Rules.Element (3).Line_Number = 3, "line number preserved");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 12, "!", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "empty negation produces diagnostic status");
   Check (Rules.Length = 0, "malformed negation emits no rule");
   Check (Diags.Length = 1, "malformed negation emits one diagnostic");
   Check
     (Diags.Element (1).Kind = Backup.Ignore.Empty_Effective_Pattern,
      "malformed negation diagnostic kind");
   Check (Diags.Element (1).Line_Number = 12, "diagnostic line preserved");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 13, "a//b", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "empty component rejected");
   Check
     (Diags.Element (1).Kind = Backup.Ignore.Empty_Path_Component,
      "empty component diagnostic kind");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 14, "a/../b", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "parent component rejected");
   Check
     (Diags.Element (1).Kind = Backup.Ignore.Parent_Path_Component,
      "parent component diagnostic kind");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 15, "foo[0-9].txt", Rules, Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "bracket glob parses");
   Check (Pattern_At (1) = "foo[0-9].txt", "bracket glob preserved");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 15, "foo[0-9.txt", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "malformed bracket glob rejected");
   Check
     (Diags.Element (1).Kind = Backup.Ignore.Unsupported_Bracket_Glob,
      "malformed bracket glob diagnostic kind");

   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 16, "ab**cd", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "invalid double-star rejected");
   Check
     (Diags.Element (1).Kind = Backup.Ignore.Invalid_Double_Star,
      "double-star diagnostic kind");



   Reset;
   Status := Backup.Ignore.Parse_Line
     ("root.gitignore", 17, "./local", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "current directory component rejected");
   Check (Rules.Length = 0, "current component emits no rule");
   Check
     (Diags.Element (1).Kind = Backup.Ignore.Current_Path_Component,
      "current component diagnostic kind");

   Reset;
   Status := Backup.Ignore.Parse_Text
     ("root.gitignore",
      "good" & ASCII.LF & "bad//path" & ASCII.LF & "later" & ASCII.LF,
      Rules,
      Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "mixed parse text reports diagnostics");
   Check (Rules.Length = 2, "mixed parse keeps valid rules");
   Check (Pattern_At (1) = "good", "mixed parse keeps first valid rule");
   Check (Pattern_At (2) = "later", "mixed parse keeps later valid rule");
   Check (Diags.Length = 1, "mixed parse emits one diagnostic");
   Check (Diags.Element (1).Line_Number = 2, "mixed diagnostic line number");
   Check
     (To_String (Diags.Element (1).Ignore_File_Path) = "root.gitignore",
      "mixed diagnostic source path");
   Check
     (To_String (Diags.Element (1).Original_Text) = "bad//path",
      "mixed diagnostic original text");
   Check
     (Diagnostic_Message_At (1)'Length > 0,
      "mixed diagnostic has message");

   Reset;
   declare
      Path : constant String := "backup_ignore_parse_file_test.gitignore";
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, "alpha");
      Ada.Text_IO.Put_Line (File, "# comment");
      Ada.Text_IO.Put_Line (File, "!beta");
      Ada.Text_IO.Close (File);

      Status := Backup.Ignore.Parse_File (Path, Rules, Diags);
      Check (Status = Backup.Ignore.Parse_Ok, "parse file reports ok");
      Check (Rules.Length = 2, "parse file rule count");
      Check (Pattern_At (1) = "alpha", "parse file first pattern");
      Check (Rules.Element (2).Negated, "parse file second negated");
      Check (Rules.Element (2).Line_Number = 3, "parse file line number");
      Check
        (To_String (Rules.Element (1).Ignore_File_Path) = Path,
         "parse file rule source path");

      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end;

   Reset;
   Status := Backup.Ignore.Parse_File
     ("definitely_missing_ignore_file.gitignore", Rules, Diags);
   Check
     (Status = Backup.Ignore.Parse_With_Diagnostics,
      "missing parse file reports diagnostics");
   Check (Rules.Length = 0, "missing parse file emits no rules");
   Check (Diags.Length = 1, "missing parse file emits diagnostic");
   Check
     (To_String (Diags.Element (1).Ignore_File_Path) =
      "definitely_missing_ignore_file.gitignore",
      "missing parse file diagnostic source path");


   Reset;
   Status := Backup.Ignore.Parse_Text
     ("root.gitignore",
      "target.txt" & ASCII.LF &
      "*.o" & ASCII.LF &
      "file?.txt" & ASCII.LF &
      "file[0-9].dat" & ASCII.LF &
      "name[!0-9].dat" & ASCII.LF &
      "literal\?.txt" & ASCII.LF &
      "literal\[name].txt" & ASCII.LF &
      "**/*.ali" & ASCII.LF &
      "/root-only.log" & ASCII.LF &
      "generated/" & ASCII.LF &
      "build/*.tmp" & ASCII.LF &
      "*.log" & ASCII.LF &
      "!keep.log" & ASCII.LF &
      "*.cache" & ASCII.LF &
      "!*.cache" & ASCII.LF,
      Rules,
      Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "phase 5 matcher rules parse");

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "target.txt", False);
   begin
      Check (D.Status = Backup.Ignore.Match_Ok, "exact match status ok");
      Check (D.Result = Backup.Ignore.Ignored, "exact pattern ignores file");
      Check (D.Has_Matching_Rule, "exact match reports rule");
      Check (D.Kind = Backup.Ignore.Rule_Ignores, "exact match kind ignores");
      Check
        (To_String (D.Matching_Rule.Original_Text) = "target.txt",
         "exact match reports source rule");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "obj/main.o", False);
   begin
      Check
        (D.Result = Backup.Ignore.Ignored,
         "star basename matches descendant");
      Check
        (To_String (D.Matching_Rule.Original_Text) = "*.o",
         "star basename diagnostic source");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "notes/file1.txt", False);
   begin
      Check
        (D.Result = Backup.Ignore.Ignored,
         "question glob matches one char");
   end;

   declare
      In_Range : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "tmp/file7.dat", False);
      Out_Of_Range : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "tmp/filex.dat", False);
   begin
      Check
        (In_Range.Result = Backup.Ignore.Ignored,
         "bracket range glob matches matching char");
      Check
        (To_String (In_Range.Matching_Rule.Original_Text) = "file[0-9].dat",
         "bracket range reports source rule");
      Check
        (Out_Of_Range.Result = Backup.Ignore.Not_Ignored,
         "bracket range glob rejects nonmatching char");
   end;

   declare
      Negated_Class : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "tmp/namex.dat", False);
      Excluded_Class : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "tmp/name3.dat", False);
   begin
      Check
        (Negated_Class.Result = Backup.Ignore.Ignored,
         "negated bracket class matches excluded range complement");
      Check
        (Excluded_Class.Result = Backup.Ignore.Not_Ignored,
         "negated bracket class rejects listed range");
   end;

   declare
      Escaped_Question : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "literal?.txt", False);
      Question_Glob : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "literalx.txt", False);
      Escaped_Bracket : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "literal[name].txt", False);
   begin
      Check
        (Escaped_Question.Result = Backup.Ignore.Ignored,
         "escaped question matches literal question");
      Check
        (Question_Glob.Result = Backup.Ignore.Not_Ignored,
         "escaped question does not behave as glob");
      Check
        (Escaped_Bracket.Result = Backup.Ignore.Ignored,
         "escaped bracket matches literal bracket");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "obj/deep/main.ali", False);
   begin
      Check
        (D.Result = Backup.Ignore.Ignored,
         "double-star path glob matches");
      Check
        (To_String (D.Matching_Rule.Original_Text) = "**/*.ali",
         "double-star diagnostic source");
   end;

   declare
      Root_D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "root-only.log", False);
      Nested_D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "logs/root-only.log", False);
   begin
      Check
        (Root_D.Result = Backup.Ignore.Ignored,
         "anchored rule matches root path");
      Check
        (Nested_D.Result = Backup.Ignore.Ignored,
         "nested log still ignored by later basename rule");
      Check
        (To_String (Nested_D.Matching_Rule.Original_Text) = "*.log",
         "anchored rule does not win for nested path");
   end;

   declare
      Dir_D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/generated", True);
      File_D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/generated", False);
   begin
      Check
        (Dir_D.Result = Backup.Ignore.Ignored,
         "directory-only matches directory");
      Check (Dir_D.Prunes_Descendants, "ignored directory prunes descendants");
      Check
        (Dir_D.Descendants_Unreachable,
         "ignored directory records unreachable descendants");
      Check
        (File_D.Result = Backup.Ignore.Not_Ignored,
         "directory-only does not match file");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "build/a.tmp", False);
   begin
      Check
        (D.Result = Backup.Ignore.Ignored,
         "path-containing rule matches path");
      Check
        (To_String (D.Matching_Rule.Original_Text) = "build/*.tmp",
         "path-containing diagnostic source");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "logs/keep.log", False);
   begin
      Check
        (D.Result = Backup.Ignore.Not_Ignored,
         "negation overrides previous ignore");
      Check (D.Kind = Backup.Ignore.Rule_Reincludes, "negation match kind");
      Check
        (To_String (D.Matching_Rule.Original_Text) = "!keep.log",
         "negation reports source rule");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "x.cache", False);
   begin
      Check
        (D.Result = Backup.Ignore.Not_Ignored,
         "later negation overrides earlier cache ignore");
      Check
        (To_String (D.Matching_Rule.Original_Text) = "!*.cache",
         "later overriding source rule reported");
   end;

   declare
      D : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/main.adb", False);
   begin
      Check
        (D.Result = Backup.Ignore.Not_Ignored,
         "nonmatching path is not ignored");
      Check (not D.Has_Matching_Rule, "nonmatching path has no rule source");
      Check (D.Kind = Backup.Ignore.No_Rule_Matched, "nonmatching kind");
   end;

   Reset;
   Status := Backup.Ignore.Parse_Text
     ("src/.gitignore",
      "/local.o" & ASCII.LF & "nested/*.tmp" & ASCII.LF,
      Rules,
      Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "scoped rules parse");

   declare
      In_Scope : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/local.o", False, "src");
      Below_Scope : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/nested/a.tmp", False, "src");
      Out_Of_Scope : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "other/local.o", False, "src");
   begin
      Check
        (In_Scope.Result = Backup.Ignore.Ignored,
         "scoped anchored rule matches below base path");
      Check
        (To_String (In_Scope.Relative_Path) = "local.o",
         "scoped decision records relative path");
      Check
        (Below_Scope.Result = Backup.Ignore.Ignored,
         "scoped path rule matches below base path");
      Check
        (Out_Of_Scope.Result = Backup.Ignore.Not_Ignored,
         "scoped rules do not apply outside base path");
   end;

   declare
      Bad_Path : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "../escape", False, "src");
      Bad_Base : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/file", False, "../src");
   begin
      Check
        (Bad_Path.Status = Backup.Ignore.Match_Invalid_Path,
         "invalid match path rejected");
      Check
        (Bad_Base.Status = Backup.Ignore.Match_Invalid_Base_Path,
         "invalid base path rejected");
   end;


   Reset;
   Status := Backup.Ignore.Parse_Text
     ("root.gitignore",
      "**/*.ads" & ASCII.LF &
      "/only-root.txt" & ASCII.LF &
      "middle/name.tmp" & ASCII.LF &
      "cache" & ASCII.LF &
      "!cache/keep.txt" & ASCII.LF,
      Rules,
      Diags);
   Check (Status = Backup.Ignore.Parse_Ok, "extra matcher rules parse");

   declare
      Root_Ads : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "root.ads", False);
      Deep_Ads : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/root.ads", False);
   begin
      Check
        (Root_Ads.Result = Backup.Ignore.Ignored,
         "double-star may match zero path components");
      Check
        (Deep_Ads.Result = Backup.Ignore.Ignored,
         "double-star may match one or more path components");
   end;

   declare
      Root_Only : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "only-root.txt", False);
      Nested_Only : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "nested/only-root.txt", False);
   begin
      Check
        (Root_Only.Result = Backup.Ignore.Ignored,
         "anchored basename matches only at rule base");
      Check
        (Nested_Only.Result = Backup.Ignore.Not_Ignored,
         "anchored basename does not match descendants");
   end;

   declare
      Direct_Path : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "middle/name.tmp", False);
      Deep_Path : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "src/middle/name.tmp", False);
   begin
      Check
        (Direct_Path.Result = Backup.Ignore.Ignored,
         "path-containing unanchored rule matches relative path");
      Check
        (Deep_Path.Result = Backup.Ignore.Not_Ignored,
         "path-containing unanchored rule is scoped to rule base");
   end;

   declare
      Cache_Dir : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "cache", True);
      Cache_Keep : constant Backup.Ignore.Decision :=
        Backup.Ignore.Evaluate (Rules, "cache/keep.txt", False);
   begin
      Check
        (Cache_Dir.Result = Backup.Ignore.Ignored,
         "basename rule ignores matching directory");
      Check
        (Cache_Dir.Prunes_Descendants,
         "basename directory ignore records pruning");
      Check
        (Cache_Keep.Result = Backup.Ignore.Not_Ignored,
         "explicit evaluation can reinclude descendant after entry");
      Check
        (Cache_Keep.Kind = Backup.Ignore.Rule_Reincludes,
         "descendant reinclude reports negation rule");
   end;

   declare
      Archive_Path : Backup.Paths.Archive_Path;
      Path_Status  : Backup.Paths.Validation_Status;
   begin
      Path_Status := Backup.Paths.Make_Archive_Path
        ("src/root.ads", Archive_Path);
      Check
        (Path_Status = Backup.Paths.Valid,
         "archive path test fixture is valid");

      declare
         D : constant Backup.Ignore.Decision :=
           Backup.Ignore.Evaluate (Rules, Archive_Path, False);
      begin
         Check
           (D.Result = Backup.Ignore.Ignored,
            "strong archive path overload evaluates rules");
      end;
   end;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup ignore tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup ignore test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Ignore_Tests;
