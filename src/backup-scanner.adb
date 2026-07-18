with Ada.Containers;
with Ada.Directories;
with Hostkit.Fs;
with GNAT.OS_Lib;

with Backup.Ignore;
with Backup.Platform;

package body Backup.Scanner is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Backup.CLI.Symlink_Mode;
   use type Backup.Ignore.Match_Result;
   use type Backup.Ignore.Match_Status;
   use type Backup.Ignore.Parse_Status;
   use type Backup.Paths.Validation_Status;
   use type Ada.Directories.File_Kind;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   type Scoped_Rule is record
      Base_Path : Unbounded_String;
      Rule      : Backup.Ignore.Rule;
   end record;

   package Scoped_Rule_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Scoped_Rule);

   package Ancestor_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   package Root_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   function Contains_Path
     (Items : Ancestor_Vectors.Vector;
      Path  : String)
      return Boolean
   is
   begin
      for Item of Items loop
         if Item = Path then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Path;

   function Normalized (Path : String) return String is
   begin
      return Backup.Paths.To_String
        (Backup.Paths.Normalize_File_System_Path (Path));
   end Normalized;

   function Full_Normalized (Path : String) return String is
      Resolved : constant String := Hostkit.Fs.Real_Path (Path);
   begin
      --  Real_Path follows links and reparse points -- the point of the exercise, and what
      --  Ada.Directories.Full_Name fails to do on Windows. It resolves only a path that
      --  exists, so it returns "" for a path that does not (a proposed output, a broken or
      --  cyclic link target); there is nothing to resolve there, so fall back to Full_Name,
      --  which still makes such a path absolute -- the form the containment and cycle checks
      --  need, and the form the old Full_Name gave every path on POSIX.
      if Resolved = "" then
         return Normalized (Ada.Directories.Full_Name (Path));
      else
         return Normalized (Resolved);
      end if;
   exception
      when others =>
         return Normalized (Path);
   end Full_Normalized;

   function Is_Symbolic_Link (Path : String) return Boolean is
   begin
      --  Not GNAT.OS_Lib.Is_Symbolic_Link: it answers False for every path on Windows,
      --  which would make every link invisible to the scanner -- so it would follow a
      --  reparse point into a cycle, or out of the input roots, exactly what this guards.
      return Hostkit.Fs.Is_Link (Path);
   exception
      when others =>
         return False;
   end Is_Symbolic_Link;

   function Read_Link_Target
     (Path   : String;
      Target : out Unbounded_String)
      return Boolean renames Backup.Platform.Read_Link_Target;

   function Directory_Of (Path : String) return String is
   begin
      for Index in reverse Path'Range loop
         if Path (Index) = '/' then
            if Index = Path'First then
               return "/";
            else
               return Path (Path'First .. Index - 1);
            end if;
         end if;
      end loop;
      return ".";
   end Directory_Of;

   function Resolve_Link_Target
     (Link_Path : String;
      Target    : String)
      return String
   is
   begin
      if Target'Length > 0 and then Target (Target'First) = '/' then
         return Target;
      else
         return Directory_Of (Link_Path) & "/" & Target;
      end if;
   end Resolve_Link_Target;

   function Is_Readable_File (Path : String) return Boolean is
   begin
      return GNAT.OS_Lib.Is_Readable_File (Path);
   exception
      when others =>
         return False;
   end Is_Readable_File;

   function Is_Contained_In
     (Child  : String;
      Parent : String)
      return Boolean
   is
   begin
      return Child = Parent
        or else
          (Child'Length > Parent'Length
           and then Child
             (Child'First .. Child'First + Parent'Length - 1) = Parent
           and then Child (Child'First + Parent'Length) = '/');
   end Is_Contained_In;

   function Is_Contained_In_Any_Root
     (Child : String;
      Roots : Root_Vectors.Vector)
      return Boolean
   is
   begin
      for Root of Roots loop
         if Is_Contained_In (Child, Root) then
            return True;
         end if;
      end loop;
      return False;
   end Is_Contained_In_Any_Root;

   function Output_Is_Inside_Input
     (Output_Path : String;
      Input_Path  : String)
      return Boolean
   is
   begin
      return Ada.Directories.Exists (Input_Path)
        and then Ada.Directories.Kind (Input_Path) = Ada.Directories.Directory
        and then Is_Contained_In
          (Full_Normalized (Output_Path), Full_Normalized (Input_Path));
   exception
      when others =>
         return False;
   end Output_Is_Inside_Input;

   procedure Sort_Strings (Items : in out String_Vectors.Vector) is
      Changed : Boolean := True;
   begin
      if Items.Length <= 1 then
         return;
      end if;

      while Changed loop
         Changed := False;
         for Index in Items.First_Index
           .. Positive'Pred (Items.Last_Index)
         loop
            if Items.Element (Index + 1) < Items.Element (Index) then
               declare
                  Left  : constant String := Items.Element (Index);
                  Right : constant String := Items.Element (Index + 1);
               begin
                  Items.Replace_Element (Index, Right);
                  Items.Replace_Element (Index + 1, Left);
                  Changed := True;
               end;
            end if;
         end loop;
      end loop;
   end Sort_Strings;

   function Directory_Children
     (Directory_Path : String;
      Children       : out String_Vectors.Vector;
      Diagnostic     : out Unbounded_String)
      return Scan_Status
   is
      Search  : Ada.Directories.Search_Type;
      Started : Boolean := False;
   begin
      Children.Clear;
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Directory_Path,
         Pattern   => "*");
      Started := True;

      while Ada.Directories.More_Entries (Search) loop
         declare
            Item : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Get_Next_Entry (Search, Item);
            declare
               Name : constant String := Ada.Directories.Simple_Name (Item);
            begin
               if Name /= "." and then Name /= ".." then
                  Children.Append (Directory_Path & "/" & Name);
               end if;
            end;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      Sort_Strings (Children);
      return Scan_Ok;
   exception
      when others =>
         if Started then
            begin
               Ada.Directories.End_Search (Search);
            exception
               when others =>
                  null;
            end;
         end if;
         Diagnostic := To_Unbounded_String
           ("unreadable directory: " & Directory_Path);
         return Scan_Unreadable_Directory;
   end Directory_Children;

   function Archive_Path_For
     (Input_Root : Backup.Paths.File_System_Path;
      Path       : String;
      Prefix     : String;
      Result     : out Backup.Paths.Archive_Path;
      Diagnostic : out Unbounded_String)
      return Scan_Status
   is
      Source        : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (Path);
      Raw_Archive   : Backup.Paths.Archive_Path;
      Path_Status   : Backup.Paths.Validation_Status;
   begin
      Path_Status := Backup.Paths.Derive_Archive_Path
        (Input_Root, Source, Raw_Archive);
      if Path_Status /= Backup.Paths.Valid then
         Diagnostic := To_Unbounded_String
           ("invalid archive path for input: " & Path);
         return Scan_Invalid_Archive_Path;
      end if;

      Path_Status := Backup.Paths.Apply_Prefix
        (Prefix, Raw_Archive, Result);
      if Path_Status /= Backup.Paths.Valid then
         Diagnostic := To_Unbounded_String
           ("invalid prefixed archive path for input: " & Path);
         return Scan_Invalid_Archive_Path;
      end if;

      pragma Assert
        (Backup.Paths.To_String (Result)'Length > 0,
         "scanner evaluates non-empty archive paths");
      return Scan_Ok;
   end Archive_Path_For;

   procedure Append_Rules
     (Base_Path : String;
      Rules     : Backup.Ignore.Rule_Vectors.Vector;
      Scoped    : in out Scoped_Rule_Vectors.Vector)
   is
   begin
      for Item of Rules loop
         Scoped.Append
           (Scoped_Rule'(Base_Path => To_Unbounded_String (Base_Path), Rule => Item));
      end loop;
   end Append_Rules;

   function Load_Ignore_File
     (Path       : String;
      Base_Path  : String;
      Rules      : in out Scoped_Rule_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Scan_Status
   is
      Parsed      : Backup.Ignore.Rule_Vectors.Vector;
      Diagnostics : Backup.Ignore.Diagnostic_Vectors.Vector;
      Status      : Backup.Ignore.Parse_Status;
   begin
      Status := Backup.Ignore.Parse_File (Path, Parsed, Diagnostics);
      if Status /= Backup.Ignore.Parse_Ok then
         if Diagnostics.Length > 0 then
            declare
               First : constant Backup.Ignore.Diagnostic :=
                 Diagnostics.Element (Diagnostics.First_Index);
            begin
               Diagnostic := To_Unbounded_String
                 ("ignore file error: " &
                  To_String (First.Ignore_File_Path) & ":" &
                  Positive'Image (First.Line_Number) & ": " &
                  To_String (First.Message));
            end;
         else
            Diagnostic := To_Unbounded_String ("ignore file error: " & Path);
         end if;
         return Scan_Ignore_File_Error;
      end if;

      Append_Rules (Base_Path, Parsed, Rules);
      return Scan_Ok;
   end Load_Ignore_File;

   function Evaluate_Ignored
     (Rules        : Scoped_Rule_Vectors.Vector;
      Archive_Path : String;
      Is_Directory : Boolean)
      return Backup.Ignore.Decision
   is
      Best : Backup.Ignore.Decision;
      One  : Backup.Ignore.Rule_Vectors.Vector;
   begin
      for Item of Rules loop
         One.Clear;
         One.Append (Item.Rule);
         declare
            Decision : constant Backup.Ignore.Decision :=
              Backup.Ignore.Evaluate
                (One,
                 Archive_Path,
                 Is_Directory,
                 To_String (Item.Base_Path));
         begin
            if Decision.Status /= Backup.Ignore.Match_Ok then
               return Decision;
            elsif Decision.Has_Matching_Rule then
               Best := Decision;
            end if;
         end;
      end loop;
      return Best;
   end Evaluate_Ignored;

   procedure Record_Symlink
     (Report       : in out Scan_Report;
      Archive_Path : String;
      Source_Path  : String;
      Target_Text  : String;
      Action       : Symlink_Action)
   is
   begin
      Report.Symlink_Diagnostics.Append
        (Symlink_Diagnostic'(Archive_Path => To_Unbounded_String (Archive_Path),
          Source_Path  => To_Unbounded_String (Source_Path),
          Target_Text  => To_Unbounded_String (Target_Text),
          Action       => Action));
   end Record_Symlink;

   procedure Record_Ignored
     (Report       : in out Scan_Report;
      Archive_Path : String;
      Kind         : Ignored_Kind;
      Decision     : Backup.Ignore.Decision)
   is
   begin
      pragma Assert
        (Decision.Has_Matching_Rule,
         "ignored diagnostics require a matching rule");
      Report.Ignored_Diagnostics.Append
        (Ignored_Diagnostic'(Archive_Path            => To_Unbounded_String (Archive_Path),
          Kind                    => Kind,
          Matching_Ignore_File    =>
            Decision.Matching_Rule.Ignore_File_Path,
          Matching_Line_Number    => Decision.Matching_Rule.Line_Number,
          Matching_Original_Text  => Decision.Matching_Rule.Original_Text,
          Pruned_Descendants      => Decision.Prunes_Descendants,
          Descendants_Unreachable => Decision.Descendants_Unreachable));
   end Record_Ignored;

   function Add_File
     (Input_Root   : Backup.Paths.File_System_Path;
      File_Path    : String;
      Archive_Path : Backup.Paths.Archive_Path;
      Seen         : in out Backup.Paths.Archive_Path_Sets.Set;
      Report       : in out Scan_Report;
      Diagnostic   : out Unbounded_String)
      return Scan_Status
   is
      Source       : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (File_Path);
      Size_Value   : Interfaces.Unsigned_64 := 0;
      Has_Time     : Boolean := False;
      Time_Value   : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
      pragma Unreferenced (Input_Root);
   begin
      if not Is_Readable_File (File_Path) then
         Diagnostic := To_Unbounded_String
           ("unreadable input path: " & File_Path);
         return Scan_Unreadable_Input;
      end if;

      if not Backup.Paths.Insert_Archive_Path (Seen, Archive_Path) then
         Diagnostic := To_Unbounded_String
           ("duplicate archive entry: " &
            Backup.Paths.To_String (Archive_Path));
         return Scan_Duplicate_Archive_Path;
      end if;

      begin
         Size_Value := Interfaces.Unsigned_64
           (Ada.Directories.Size (File_Path));
      exception
         when others =>
            Size_Value := 0;
      end;

      begin
         Time_Value := Ada.Directories.Modification_Time (File_Path);
         Has_Time := True;
      exception
         when others =>
            Has_Time := False;
      end;

      Report.Entries.Append
        (Discovered_Entry'(Source_Path           => Source,
          Archive_Path          => Archive_Path,
          Kind                  => Entry_File,
          Byte_Size             => Size_Value,
          Has_Modification_Time => Has_Time,
          Modification_Time     => Time_Value,
          Compression_Method    => Backup.Zip.Deflated,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Link_Target           => Null_Unbounded_String));
      return Scan_Ok;
   end Add_File;

   function Add_Symlink
     (Link_Path    : String;
      Archive_Path : Backup.Paths.Archive_Path;
      Target_Text  : String;
      Seen         : in out Backup.Paths.Archive_Path_Sets.Set;
      Report       : in out Scan_Report;
      Diagnostic   : out Unbounded_String)
      return Scan_Status
   is
      Source : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (Link_Path);
   begin
      if not Backup.Paths.Insert_Archive_Path (Seen, Archive_Path) then
         Diagnostic := To_Unbounded_String
           ("duplicate archive entry: " &
            Backup.Paths.To_String (Archive_Path));
         return Scan_Duplicate_Archive_Path;
      end if;

      Report.Entries.Append
        (Discovered_Entry'(Source_Path           => Source,
          Archive_Path          => Archive_Path,
          Kind                  => Entry_Symlink,
          Byte_Size             => Interfaces.Unsigned_64 (Target_Text'Length),
          Has_Modification_Time => False,
          Modification_Time     => Ada.Calendar.Time_Of (1901, 1, 1),
          Compression_Method    => Backup.Zip.Stored,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Link_Target           => To_Unbounded_String (Target_Text)));
      return Scan_Ok;
   end Add_Symlink;

   function Traverse
     (Input_Root      : Backup.Paths.File_System_Path;
      Input_Roots     : Root_Vectors.Vector;
      Current         : String;
      Archive_Current : String;
      Prefix          : String;
      Rules           : Scoped_Rule_Vectors.Vector;
      Seen            : in out Backup.Paths.Archive_Path_Sets.Set;
      Ancestors       : Ancestor_Vectors.Vector;
      Mode            : Backup.CLI.Symlink_Mode;
      Report          : in out Scan_Report;
      Diagnostic      : out Unbounded_String)
      return Scan_Status
   is
      Children     : String_Vectors.Vector;
      Local_Rules  : Scoped_Rule_Vectors.Vector := Rules;
      Status       : Scan_Status;
      Archive      : Backup.Paths.Archive_Path;
      Archive_Text : Unbounded_String;
      Decision     : Backup.Ignore.Decision;
   begin
      if Is_Symbolic_Link (Current) then
         Status := Archive_Path_For
           (Input_Root, Archive_Current, Prefix, Archive, Diagnostic);
         if Status /= Scan_Ok then
            return Status;
         end if;
         Archive_Text := To_Unbounded_String (Backup.Paths.To_String (Archive));
         Decision := Evaluate_Ignored
           (Local_Rules, To_String (Archive_Text), Is_Directory => False);
         if Decision.Status /= Backup.Ignore.Match_Ok then
            Diagnostic := To_Unbounded_String
              ("invalid ignore match path: " & To_String (Archive_Text));
            return Scan_Invalid_Archive_Path;
         elsif Decision.Result = Backup.Ignore.Ignored then
            Record_Ignored
              (Report, To_String (Archive_Text), Ignored_Symlink, Decision);
            return Scan_Ok;
         end if;

         declare
            Target_Text : Unbounded_String;
         begin
            if not Read_Link_Target (Current, Target_Text) then
               Record_Symlink
                 (Report,
                  To_String (Archive_Text),
                  Current,
                  "",
                  Symlink_Broken);
               Diagnostic := To_Unbounded_String
                 ("broken symlink or unreadable link target: " & Current);
               return Scan_Symlink_Broken;
            end if;

            if Mode = Backup.CLI.Symlinks_Skip then
               Record_Symlink
                 (Report,
                  To_String (Archive_Text),
                  Current,
                  To_String (Target_Text),
                  Symlink_Skipped);
               return Scan_Ok;
            elsif Mode = Backup.CLI.Symlinks_Store_Link then
               Record_Symlink
                 (Report,
                  To_String (Archive_Text),
                  Current,
                  To_String (Target_Text),
                  Symlink_Stored);
               return Add_Symlink
                 (Current,
                  Archive,
                  To_String (Target_Text),
                  Seen,
                  Report,
                  Diagnostic);
            else
               declare
                  Target_Path : constant String :=
                    Resolve_Link_Target (Current, To_String (Target_Text));
                  Normal_Link : constant String := Full_Normalized (Current);
                  Normal_Target : constant String := Full_Normalized (Target_Path);
                  Follow_Ancestors : Ancestor_Vectors.Vector := Ancestors;
               begin
                  if Contains_Path (Ancestors, Normal_Link)
                    or else Contains_Path (Ancestors, Normal_Target)
                  then
                     Record_Symlink
                       (Report,
                        To_String (Archive_Text),
                        Current,
                        To_String (Target_Text),
                        Symlink_Cycle);
                     Diagnostic := To_Unbounded_String
                       ("symlink traversal cycle: " & Current);
                     return Scan_Symlink_Cycle;
                  end if;
                  Follow_Ancestors.Append (Normal_Link);
                  if not Is_Contained_In_Any_Root (Normal_Target, Input_Roots) then
                     Record_Symlink
                       (Report,
                        To_String (Archive_Text),
                        Current,
                        To_String (Target_Text),
                        Symlink_Outside_Input);
                     Diagnostic := To_Unbounded_String
                       ("symlink target outside input roots: " & Current);
                     return Scan_Symlink_Target_Outside_Input;
                  end if;
                  if not Ada.Directories.Exists (Target_Path)
                    and then not Is_Symbolic_Link (Target_Path)
                  then
                     Record_Symlink
                       (Report,
                        To_String (Archive_Text),
                        Current,
                        To_String (Target_Text),
                        Symlink_Broken);
                     Diagnostic := To_Unbounded_String
                       ("broken symlink: " & Current);
                     return Scan_Symlink_Broken;
                  end if;
                  Record_Symlink
                    (Report,
                     To_String (Archive_Text),
                     Current,
                     To_String (Target_Text),
                     Symlink_Followed);
                  return Traverse
                    (Input_Root, Input_Roots, Target_Path, Archive_Current, Prefix,
                     Local_Rules, Seen, Follow_Ancestors, Mode, Report,
                     Diagnostic);
               end;
            end if;
         end;
      end if;

      if not Ada.Directories.Exists (Current) then
         Diagnostic := To_Unbounded_String ("missing input path: " & Current);
         return Scan_Missing_Input;
      end if;

      Status := Archive_Path_For
        (Input_Root, Archive_Current, Prefix, Archive, Diagnostic);
      if Status /= Scan_Ok then
         return Status;
      end if;
      Archive_Text := To_Unbounded_String (Backup.Paths.To_String (Archive));

      case Ada.Directories.Kind (Current) is
         when Ada.Directories.Ordinary_File =>
            Decision := Evaluate_Ignored
              (Local_Rules, To_String (Archive_Text), Is_Directory => False);
            if Decision.Status /= Backup.Ignore.Match_Ok then
               Diagnostic := To_Unbounded_String
                 ("invalid ignore match path: " & To_String (Archive_Text));
               return Scan_Invalid_Archive_Path;
            elsif Decision.Result = Backup.Ignore.Ignored then
               Record_Ignored
                 (Report, To_String (Archive_Text), Ignored_File, Decision);
               return Scan_Ok;
            end if;

            return Add_File
              (Input_Root, Current, Archive, Seen, Report, Diagnostic);

         when Ada.Directories.Directory =>
            Decision := Evaluate_Ignored
              (Local_Rules, To_String (Archive_Text), Is_Directory => True);
            if Decision.Status /= Backup.Ignore.Match_Ok then
               Diagnostic := To_Unbounded_String
                 ("invalid ignore match path: " & To_String (Archive_Text));
               return Scan_Invalid_Archive_Path;
            elsif Decision.Result = Backup.Ignore.Ignored then
               Record_Ignored
                 (Report, To_String (Archive_Text), Ignored_Directory, Decision);
               return Scan_Ok;
            end if;

            declare
               Ignore_Path : constant String := Current & "/.gitignore";
            begin
               if Ada.Directories.Exists (Ignore_Path) then
                  Status := Load_Ignore_File
                    (Ignore_Path,
                     To_String (Archive_Text),
                     Local_Rules,
                     Diagnostic);
                  if Status /= Scan_Ok then
                     return Status;
                  end if;
               end if;
            end;

            declare
               Normal_Current : constant String := Full_Normalized (Current);
               Child_Ancestors : Ancestor_Vectors.Vector := Ancestors;
            begin
               if Contains_Path (Ancestors, Normal_Current) then
                  Diagnostic := To_Unbounded_String
                    ("symlink traversal cycle: " & Current);
                  return Scan_Symlink_Cycle;
               end if;
               Child_Ancestors.Append (Normal_Current);

               Status := Directory_Children (Current, Children, Diagnostic);
               if Status /= Scan_Ok then
                  return Status;
               end if;

               for Child of Children loop
                  declare
                     Name : constant String :=
                       Child (Child'First + Current'Length + 1 .. Child'Last);
                     Archive_Child : constant String :=
                       Archive_Current & "/" & Name;
                  begin
                     Status := Traverse
                       (Input_Root,
                        Input_Roots,
                        Child,
                        Archive_Child,
                        Prefix,
                        Local_Rules,
                        Seen,
                        Child_Ancestors,
                        Mode,
                        Report,
                        Diagnostic);
                  end;
                  if Status /= Scan_Ok then
                     return Status;
                  end if;
               end loop;
            end;
            return Scan_Ok;

         when others =>
            return Scan_Ok;
      end case;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("unreadable input path: " & Current);
         return Scan_Unreadable_Input;
   end Traverse;

   function Scan
     (Config     : Backup.CLI.Configuration;
      Report     : out Scan_Report;
      Diagnostic : out Unbounded_String)
      return Scan_Status
   is
      Seen        : Backup.Paths.Archive_Path_Sets.Set;
      Prefix_Text : constant String := To_String (Config.Prefix);
      Status      : Scan_Status;
      Root_Rules  : Scoped_Rule_Vectors.Vector;
      Input_Roots : Root_Vectors.Vector;
   begin
      Report.Entries.Clear;
      Report.Ignored_Diagnostics.Clear;
      Report.Symlink_Diagnostics.Clear;
      Diagnostic := Null_Unbounded_String;


      for Ignore_File of Config.Ignore_Files loop
         Status := Load_Ignore_File
           (Ignore_File, "", Root_Rules, Diagnostic);
         if Status /= Scan_Ok then
            return Status;
         end if;
      end loop;

      for Input_Path of Config.Input_Paths loop
         if Output_Is_Inside_Input
           (To_String (Config.Output_Path), Input_Path)
         then
            Diagnostic := To_Unbounded_String
              ("output ZIP path is inside input directory: " &
               To_String (Config.Output_Path));
            return Scan_Output_Inside_Input;
         end if;
      end loop;

      for Input_Path of Config.Input_Paths loop
         Input_Roots.Append (Full_Normalized (Input_Path));
      end loop;

      for Input_Path of Config.Input_Paths loop
         declare
            Root : constant Backup.Paths.File_System_Path :=
              Backup.Paths.Normalize_File_System_Path (Input_Path);
         begin
            declare
               Empty_Ancestors : Ancestor_Vectors.Vector;
            begin
               Status := Traverse
                 (Root,
                  Input_Roots,
                  Input_Path,
                  Input_Path,
                  Prefix_Text,
                  Root_Rules,
                  Seen,
                  Empty_Ancestors,
                  Config.Symlinks,
                  Report,
                  Diagnostic);
            end;
            if Status /= Scan_Ok then
               Report.Entries.Clear;
               return Status;
            end if;
         end;
      end loop;

      return Scan_Ok;
   end Scan;

   function Scan
     (Config     : Backup.CLI.Configuration;
      Entries    : out Entry_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Scan_Status
   is
      Report : Scan_Report;
      Status : Scan_Status;
   begin
      Status := Scan (Config, Report, Diagnostic);
      Entries := Report.Entries;
      return Status;
   end Scan;

end Backup.Scanner;
