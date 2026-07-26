--  Bundle the i18n dependency's generated locale data (share/i18n) into this
--  crate's share tree, so a deployed bin/backup finds it at Exe/../share/i18n.
--  The load-only i18n serves formatting from those files at runtime; i18n ships
--  no committed data (its own pre-build action regenerates share/i18n from the
--  pinned CLDR subset), so this copies the freshly generated tree from wherever
--  Alire resolved i18n to.
--
--  Its own standalone project (tools/i18n_bundle/bundle_i18n_data.gpr) so it
--  builds with plain gprbuild and stays out of the app's bin; the backup
--  post-build actions build then run it (see alire.toml). It runs from the
--  backup crate root, so the relative paths below resolve there. Idempotent: it
--  re-copies only when the source is newer. When no source is found it warns
--  and leaves the tree alone; the release check (tools/release_check) then
--  fails the release if share/i18n is absent, so a broken package cannot ship
--  silently.

with Ada.Calendar;             use type Ada.Calendar.Time;
with Ada.Directories;          use Ada.Directories;
with Ada.Environment_Variables;
with Ada.Text_IO;              use Ada.Text_IO;

with GNAT.OS_Lib;

procedure Bundle_I18n_Data is

   Dest   : constant String := "share/i18n";
   Marker : constant String := "formats.i18ndata";

   function File_Present (Path : String) return Boolean is
     (Exists (Path) and then Kind (Path) = Ordinary_File);

   function Env (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name)
      else "");

   --  The i18n crate root -- the directory carrying i18n.gpr -- is on
   --  GPR_PROJECT_PATH during the build, whether i18n is a workspace pin or a
   --  published crate in the Alire build cache. Its data is the sibling
   --  <i18n-root>/share/i18n. Return that directory if Dir qualifies.
   function Dependency_Data (Dir : String) return String is
   begin
      if Dir /= ""
        and then File_Present (Dir & "/i18n.gpr")
        and then File_Present (Dir & "/" & Dest & "/" & Marker)
      then
         return Dir & "/" & Dest;
      end if;
      return "";
   end Dependency_Data;

   --  The generated data directory to copy from, or "" when none is found.
   function Find_Source return String is
      Override : constant String := Env ("I18N_DATA_DIR");
      Path     : constant String := Env ("GPR_PROJECT_PATH");
      Sep      : constant Character := GNAT.OS_Lib.Path_Separator;
      First    : Positive := Path'First;
   begin
      --  1. Explicit override pointing straight at a share/i18n tree.
      if Override /= "" and then File_Present (Override & "/" & Marker) then
         return Override;
      end if;

      --  2. The resolved i18n dependency on GPR_PROJECT_PATH.
      if Path /= "" then
         for Index in Path'Range loop
            if Path (Index) = Sep then
               declare
                  Hit : constant String :=
                    Dependency_Data (Path (First .. Index - 1));
               begin
                  if Hit /= "" then
                     return Hit;
                  end if;
               end;
               First := Index + 1;
            end if;
         end loop;

         declare
            Hit : constant String := Dependency_Data (Path (First .. Path'Last));
         begin
            if Hit /= "" then
               return Hit;
            end if;
         end;
      end if;

      --  3. Workspace sibling, for running the tool outside a build.
      if File_Present ("../i18n/" & Dest & "/" & Marker) then
         return "../i18n/" & Dest;
      elsif File_Present ("../../i18n/" & Dest & "/" & Marker) then
         return "../../i18n/" & Dest;
      end if;

      return "";
   end Find_Source;

   procedure Copy_Tree (Source, Target : String) is
      Search : Search_Type;
      Item   : Directory_Entry_Type;
   begin
      Create_Path (Target);
      Start_Search (Search, Source, "");
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               if Kind (Item) = Directory then
                  Copy_Tree (Full_Name (Item), Target & "/" & Name);
               else
                  Copy_File (Full_Name (Item), Target & "/" & Name);
               end if;
            end if;
         end;
      end loop;
      End_Search (Search);
   end Copy_Tree;

   Source : constant String := Find_Source;

begin
   if Source = "" then
      Put_Line
        (Standard_Error,
         "bundle_i18n_data: i18n share/i18n not found (I18N_DATA_DIR, the i18n");
      Put_Line
        (Standard_Error,
         "  dependency on GPR_PROJECT_PATH, or a workspace sibling); locale data");
      Put_Line
        (Standard_Error,
         "  NOT bundled. release_check enforces its presence before a release.");
      return;
   end if;

   --  Idempotent: skip when the bundled marker is at least as new as the source.
   if File_Present (Dest & "/" & Marker)
     and then Modification_Time (Source & "/" & Marker)
                <= Modification_Time (Dest & "/" & Marker)
   then
      return;
   end if;

   if Exists (Dest) then
      Delete_Tree (Dest);
   end if;
   Copy_Tree (Source, Dest);
   Put_Line ("bundle_i18n_data: bundled " & Source & " -> " & Dest);
end Bundle_I18n_Data;
