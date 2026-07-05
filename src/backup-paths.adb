with Ada.Containers;
with Backup.Path_Syntax;

package body Backup.Paths is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   function Clean_Separators (Path : String) return String is
      Buffer : String (1 .. Path'Length);
      Last   : Natural := 0;
   begin
      for Ch of Path loop
         Last := Last + 1;
         Buffer (Last) := Backup.Path_Syntax.Clean_Separator (Ch);
      end loop;

      if Last = 0 then
         return "";
      end if;

      return Buffer (1 .. Last);
   end Clean_Separators;

   procedure Append_Component
     (Parts : in out String_Vectors.Vector;
      Part  : String)
   is
   begin
      if Part = "" or else Part = "." then
         null;
      elsif Part = ".." then
         if not Parts.Is_Empty and then Parts.Last_Element /= ".." then
            Parts.Delete_Last;
         else
            Parts.Append (Part);
         end if;
      else
         Parts.Append (Part);
      end if;
   end Append_Component;

   function Join_Parts (Parts : String_Vectors.Vector) return String is
      Result : Unbounded_String;
      First  : Boolean := True;
   begin
      for Part of Parts loop
         if First then
            First := False;
         else
            Append (Result, "/");
         end if;
         Append (Result, Part);
      end loop;

      if Result = Null_Unbounded_String then
         return ".";
      end if;

      return To_String (Result);
   end Join_Parts;

   function Normalize_File_System_Path
     (Path : String)
      return File_System_Path
   is
      Raw         : constant String := Clean_Separators (Path);
      Parts       : String_Vectors.Vector;
      Prefix_Text : Unbounded_String;
      Start       : Positive;
      Index       : Positive;
   begin
      if Raw'Length = 0 then
         return (Value => To_Unbounded_String ("."));
      end if;

      if Raw (Raw'First) = '/' then
         Prefix_Text := To_Unbounded_String ("/");
         if Raw'Length = 1 then
            return (Value => Prefix_Text);
         end if;
         Start := Raw'First + 1;
      elsif Backup.Path_Syntax.Is_Windows_Absolute (Raw) then
         Prefix_Text := To_Unbounded_String
           (Raw (Raw'First .. Raw'First + 2));
         if Raw'Length = 3 then
            return (Value => Prefix_Text);
         end if;
         Start := Raw'First + 3;
      else
         Prefix_Text := Null_Unbounded_String;
         Start := Raw'First;
      end if;

      Index := Start;
      while Index <= Raw'Last loop
         if Raw (Index) = '/' then
            if Index > Start then
               Append_Component (Parts, Raw (Start .. Index - 1));
            end if;
            if Index < Raw'Last then
               Start := Index + 1;
            end if;
         end if;
         Index := Index + 1;
      end loop;

      if Start <= Raw'Last and then not Backup.Path_Syntax.Is_Slash (Raw (Raw'Last)) then
         Append_Component (Parts, Raw (Start .. Raw'Last));
      end if;

      declare
         Relative_Text : constant String := Join_Parts (Parts);
         Normalized   : Unbounded_String := Prefix_Text;
      begin
         if Relative_Text /= "." then
            declare
               Current : constant String := To_String (Normalized);
            begin
               if Current /= ""
                 and then Current /= "/"
                 and then Current (Current'Last) /= '/'
               then
                  Append (Normalized, "/");
               end if;
            end;

            Append (Normalized, Relative_Text);
         elsif Normalized = Null_Unbounded_String then
            Normalized := To_Unbounded_String (".");
         end if;

         pragma Assert
           (Length (Normalized) > 0,
            "filesystem path is non-empty");
         return (Value => Normalized);
      end;
   end Normalize_File_System_Path;

   function To_String
     (Path : File_System_Path)
      return String
   is
   begin
      return Ada.Strings.Unbounded.To_String (Path.Value);
   end To_String;

   function Same_File_System_Path
     (Left  : File_System_Path;
      Right : File_System_Path)
      return Boolean
   is
   begin
      return To_String (Left) = To_String (Right);
   end Same_File_System_Path;

   function Validate_Archive_Fragment
     (Path        : String;
      Allow_Empty : Boolean := False)
      return Validation_Status
   is
      Normalized     : constant String := Clean_Separators (Path);
      Segment_Start  : Positive;
      Segment_Length : Natural := 0;
   begin
      if Normalized'Length = 0 then
         if Allow_Empty then
            return Valid;
         end if;
         return Empty_Path;
      end if;

      if Backup.Path_Syntax.Is_Absolute (Normalized) then
         return Absolute_Path;
      end if;

      if Normalized (Normalized'First) = '/'
        or else Normalized (Normalized'Last) = '/'
      then
         return Empty_Component;
      end if;

      Segment_Start := Normalized'First;
      for Index in Normalized'Range loop
         if Normalized (Index) = '/' then
            if Segment_Length = 0 then
               return Empty_Component;
            end if;

            declare
               Segment : constant String :=
                 Normalized (Segment_Start .. Index - 1);
            begin
               if Segment = "." then
                  return Current_Component;
               elsif Segment = ".." then
                  return Parent_Component;
               end if;
            end;

            Segment_Length := 0;
            if Index < Normalized'Last then
               Segment_Start := Index + 1;
            end if;
         else
            Segment_Length := Segment_Length + 1;
         end if;
      end loop;

      if Segment_Length = 0 then
         return Empty_Component;
      end if;

      declare
         Segment : constant String :=
           Normalized (Segment_Start .. Normalized'Last);
      begin
         if Segment = "." then
            return Current_Component;
         elsif Segment = ".." then
            return Parent_Component;
         end if;
      end;

      return Valid;
   end Validate_Archive_Fragment;


   function Validate_Prefix
     (Prefix : String)
      return Validation_Status
   is
   begin
      for Ch of Prefix loop
         if Ch = '\' then
            return Invalid_Prefix;
         end if;
      end loop;

      return Validate_Archive_Fragment (Prefix);
   end Validate_Prefix;

   function Make_Archive_Path
     (Path   : String;
      Result : out Archive_Path)
      return Validation_Status
   is
      Status     : constant Validation_Status :=
        Validate_Archive_Fragment (Path);
      Normalized : constant String := Clean_Separators (Path);
   begin
      if Status /= Valid then
         Result := (Value => Null_Unbounded_String);
         return Status;
      end if;

      pragma Assert (Normalized'Length > 0, "archive path is non-empty");
      pragma Assert
        (Normalized (Normalized'First) /= '/',
         "archive path is relative");
      Result := (Value => To_Unbounded_String (Normalized));
      return Valid;
   end Make_Archive_Path;

   function To_String
     (Path : Archive_Path)
      return String
   is
   begin
      return Ada.Strings.Unbounded.To_String (Path.Value);
   end To_String;

   function "<"
     (Left  : Archive_Path;
      Right : Archive_Path)
      return Boolean
   is
   begin
      return To_String (Left) < To_String (Right);
   end "<";

   function "="
     (Left  : Archive_Path;
      Right : Archive_Path)
      return Boolean
   is
   begin
      return To_String (Left) = To_String (Right);
   end "=";

   function Join
     (Left   : Archive_Path;
      Right  : String;
      Result : out Archive_Path)
      return Validation_Status
   is
      Status : constant Validation_Status := Validate_Archive_Fragment (Right);
   begin
      if Status /= Valid then
         Result := (Value => Null_Unbounded_String);
         return Status;
      end if;

      return Make_Archive_Path
        (To_String (Left) & "/" & Clean_Separators (Right), Result);
   end Join;

   function Apply_Prefix
     (Prefix : String;
      Path   : Archive_Path;
      Result : out Archive_Path)
      return Validation_Status
   is
      Prefix_Status : constant Validation_Status :=
        Validate_Prefix (Prefix);
   begin
      if Prefix'Length = 0 then
         Result := Path;
         return Valid;
      end if;

      if Prefix_Status /= Valid then
         Result := (Value => Null_Unbounded_String);
         return Invalid_Prefix;
      end if;

      return Make_Archive_Path
        (Clean_Separators (Prefix) & "/" & To_String (Path), Result);
   end Apply_Prefix;

   function Base_Name (Path : File_System_Path) return String is
      Value : constant String := To_String (Path);
   begin
      for Index in reverse Value'Range loop
         if Value (Index) = '/' then
            if Index = Value'Last then
               return "";
            end if;
            return Value (Index + 1 .. Value'Last);
         end if;
      end loop;
      return Value;
   end Base_Name;

   function Relative_To
     (Root       : File_System_Path;
      Descendant : File_System_Path)
      return String
   is
      Root_Text : constant String := To_String (Root);
      Desc_Text : constant String := To_String (Descendant);
   begin
      if Desc_Text = Root_Text then
         return "";
      end if;

      if Desc_Text'Length > Root_Text'Length
        and then Desc_Text
          (Desc_Text'First .. Desc_Text'First + Root_Text'Length - 1)
          = Root_Text
        and then Desc_Text (Desc_Text'First + Root_Text'Length) = '/'
      then
         return Desc_Text
           (Desc_Text'First + Root_Text'Length + 1 .. Desc_Text'Last);
      end if;

      return Desc_Text;
   end Relative_To;

   function Derive_Archive_Path
     (Input_Root : File_System_Path;
      Descendant : File_System_Path;
      Result     : out Archive_Path)
      return Validation_Status
   is
      Root_Name : constant String := Base_Name (Input_Root);
      Relative  : constant String := Relative_To (Input_Root, Descendant);
   begin
      if Root_Name = "" or else Root_Name = "." or else Root_Name = ".." then
         Result := (Value => Null_Unbounded_String);
         return Empty_Path;
      end if;

      if Relative = "" then
         return Make_Archive_Path (Root_Name, Result);
      end if;

      declare
         Root_Text : constant String := To_String (Input_Root);
         Desc_Text : constant String := To_String (Descendant);
      begin
         if Desc_Text'Length <= Root_Text'Length
           or else Desc_Text
             (Desc_Text'First .. Desc_Text'First + Root_Text'Length - 1)
             /= Root_Text
           or else Desc_Text (Desc_Text'First + Root_Text'Length) /= '/'
         then
            Result := (Value => Null_Unbounded_String);
            return Escapes_Root;
         end if;
      end;

      return Make_Archive_Path (Root_Name & "/" & Relative, Result);
   end Derive_Archive_Path;

   function Contains_Duplicate_File_System_Path
     (Paths : File_System_Path_Vectors.Vector)
      return Boolean
   is
   begin
      if Paths.Length <= 1 then
         return False;
      end if;

      for Left_Index in Paths.First_Index .. Paths.Last_Index loop
         for Right_Index in Left_Index + 1 .. Paths.Last_Index loop
            if Same_File_System_Path
              (Paths.Element (Left_Index), Paths.Element (Right_Index))
            then
               return True;
            end if;
         end loop;
      end loop;

      return False;
   end Contains_Duplicate_File_System_Path;

   function Insert_Archive_Path
     (Set  : in out Archive_Path_Sets.Set;
      Path : Archive_Path)
      return Boolean
   is
   begin
      if Set.Contains (Path) then
         return False;
      end if;

      Set.Insert (Path);
      return True;
   end Insert_Archive_Path;

end Backup.Paths;
