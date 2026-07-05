with Ada.Command_Line;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Backup_Tool_Support;

procedure Generate_CLI_Surface is
   use Ada.Strings.Unbounded;

   type Row is record
      Tag, F2, F3, F4, F5, F6 : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Row);

   Model : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1)
      else "tools/cli_surface.conf");
   Out_Dir : constant String :=
     (if Ada.Command_Line.Argument_Count >= 2 then Ada.Command_Line.Argument (2)
      else ".");
   Rows : Row_Vectors.Vector;

   function S (U : Unbounded_String) return String renames To_String;

   function Field (Line : String; N : Positive) return String is
      Start : Positive := Line'First;
      Count : Positive := 1;
   begin
      for I in Line'Range loop
         if Line (I) = '|' then
            if Count = N then
               return Line (Start .. I - 1);
            end if;
            Count := Count + 1;
            Start := I + 1;
         end if;
      end loop;
      if Count = N then
         return Line (Start .. Line'Last);
      end if;
      return "";
   end Field;

   procedure Load is
      F : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Model);
      while not Ada.Text_IO.End_Of_File (F) loop
         declare
            L : constant String := Ada.Text_IO.Get_Line (F);
         begin
            if L'Length > 0 and then L (L'First) /= '#' then
               Rows.Append
                 (Row'
                    (Tag => To_Unbounded_String (Field (L, 1)),
                     F2  => To_Unbounded_String (Field (L, 2)),
                     F3  => To_Unbounded_String (Field (L, 3)),
                     F4  => To_Unbounded_String (Field (L, 4)),
                     F5  => To_Unbounded_String (Field (L, 5)),
                     F6  => To_Unbounded_String (Field (L, 6))));
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (F);
   end Load;

   procedure Emit (Path : String; Text : String) is
   begin
      Backup_Tool_Support.Write_Text (Out_Dir & "/" & Path, Text);
   end Emit;

   procedure Emit_Trimmed (Path : String; Text : String) is
   begin
      if Text'Length > 0 and then Text (Text'Last) = ASCII.LF then
         Backup_Tool_Support.Write_Text
           (Out_Dir & "/" & Path, Text (Text'First .. Text'Last - 1));
      else
         Backup_Tool_Support.Write_Text (Out_Dir & "/" & Path, Text);
      end if;
   end Emit_Trimmed;

   procedure Copy (Path : String) is
   begin
      if Out_Dir = "." then
         return;
      end if;
      Backup_Tool_Support.Copy_File_To (Path, Out_Dir & "/" & Path);
   end Copy;

   procedure Generate_Doc is
      T : Unbounded_String;
   begin
      Append (T, "# CLI Surface Contract" & ASCII.LF & ASCII.LF);
      Append (T, "This file is generated from `tools/cli_surface.conf` by `tools/bin/generate_cli_surface`." & ASCII.LF);
      Append (T, "Do not edit it directly." & ASCII.LF & ASCII.LF);
      Append (T, "## Command Modes" & ASCII.LF & ASCII.LF);
      Append (T, "| Mode | Selector | Positionals | Notes |" & ASCII.LF);
      Append (T, "| --- | --- | --- | --- |" & ASCII.LF);
      for R of Rows loop
         if S (R.Tag) = "mode" then
            Append (T, "| `" & S (R.F2) & "` | `" & S (R.F3) & "` | `" & S (R.F4) & "` | " & S (R.F5) & " |" & ASCII.LF);
         end if;
      end loop;
      Append (T, ASCII.LF & "## Conflict Groups" & ASCII.LF & ASCII.LF);
      Append (T, "| Group | Rule | Members | Diagnostic |" & ASCII.LF);
      Append (T, "| --- | --- | --- | --- |" & ASCII.LF);
      for R of Rows loop
         if S (R.Tag) = "conflict" then
            Append (T, "| `" & S (R.F2) & "` | `" & S (R.F3) & "` | `" & S (R.F4) & "` | " & S (R.F5) & " |" & ASCII.LF);
         end if;
      end loop;
      Append (T, ASCII.LF & "## Options" & ASCII.LF & ASCII.LF);
      Append (T, "| Option | Value kind | Values | Description |" & ASCII.LF);
      Append (T, "| --- | --- | --- | --- |" & ASCII.LF);
      for R of Rows loop
         if S (R.Tag) = "option" then
            Append (T, "| `--" & S (R.F2) & "` | `" & S (R.F4) & "` | ");
            if S (R.F5) /= "" then
               Append (T, "`" & S (R.F5) & "`");
            end if;
            Append (T, " | " & S (R.F6) & " |" & ASCII.LF);
         end if;
      end loop;
      Emit_Trimmed ("docs/CLI_SURFACE.md", S (T));
   end Generate_Doc;

   procedure Generate_Catalog is
      T : Unbounded_String;
   begin
      Append (T, "default_locale = en" & ASCII.LF);
      for R of Rows loop
         if S (R.Tag) = "help" then
            Append (T, "en." & S (R.F3) & " = " & S (R.F5) & ASCII.LF);
         elsif S (R.Tag) = "advanced" then
            Append (T, "en.help.advanced." & S (R.F2) & " = " & S (R.F3) & ASCII.LF);
         end if;
      end loop;
      Append (T, "en.error.prefix = backup: {message}");
      Emit ("share/backup/messages.catalog", S (T));
   end Generate_Catalog;

   procedure Generate_Ada is
      Ads, Adb, Last_Advanced : Unbounded_String;
      First : Boolean := True;
   begin
      Append (Ads, "--  Generated from tools/cli_surface.conf by tools/bin/generate_cli_surface." & ASCII.LF);
      Append (Ads, "package Backup.CLI_Surface" & ASCII.LF & "  with SPARK_Mode => On" & ASCII.LF & "is" & ASCII.LF);
      Append (Ads, "   type Help_Role is (Role_Header, Role_Info, Role_Muted);" & ASCII.LF & ASCII.LF);
      Append (Ads, "   type Help_Line is" & ASCII.LF & "     (");
      for R of Rows loop
         if S (R.Tag) = "help" or else S (R.Tag) = "advanced" then
            if not First then
               Append (Ads, "," & ASCII.LF & "      ");
            end if;
            if S (R.Tag) = "help" then
               Append (Ads, S (R.F2));
            else
               Append (Ads, "Advanced_" & S (R.F2));
               Last_Advanced := To_Unbounded_String ("Advanced_" & S (R.F2));
            end if;
            First := False;
         end if;
      end loop;
      Append (Ads, ");" & ASCII.LF & ASCII.LF);
      Append (Ads, "   subtype Basic_Help_Line is Help_Line range Title .. Json_Errors;" & ASCII.LF);
      Append (Ads, "   subtype Advanced_Help_Line is Help_Line range Advanced .. " & S (Last_Advanced) & ";" & ASCII.LF & ASCII.LF);
      Append (Ads, "   function Message_Key (Line : Help_Line) return String;" & ASCII.LF & ASCII.LF);
      Append (Ads, "   function Display_Role (Line : Help_Line) return Help_Role;" & ASCII.LF);
      Append (Ads, "end Backup.CLI_Surface;");
      Emit ("src/backup-cli_surface.ads", S (Ads));

      Append (Adb, "--  Generated from tools/cli_surface.conf by tools/bin/generate_cli_surface." & ASCII.LF);
      Append (Adb, "package body Backup.CLI_Surface" & ASCII.LF & "  with SPARK_Mode => On" & ASCII.LF & "is" & ASCII.LF);
      Append (Adb, "   function Message_Key (Line : Help_Line) return String is" & ASCII.LF & "   begin" & ASCII.LF & "      case Line is" & ASCII.LF);
      for R of Rows loop
         if S (R.Tag) = "help" then
            Append (Adb, "         when " & S (R.F2) & " => return """ & S (R.F3) & """;" & ASCII.LF);
         elsif S (R.Tag) = "advanced" then
            Append (Adb, "         when Advanced_" & S (R.F2) & " => return ""help.advanced." & S (R.F2) & """;" & ASCII.LF);
         end if;
      end loop;
      Append (Adb, "      end case;" & ASCII.LF & "   end Message_Key;" & ASCII.LF & ASCII.LF);
      Append (Adb, "   function Display_Role (Line : Help_Line) return Help_Role is" & ASCII.LF & "   begin" & ASCII.LF & "      case Line is" & ASCII.LF);
      for R of Rows loop
         if S (R.Tag) = "help" then
            Append (Adb, "         when " & S (R.F2) & " => return Role_" & S (R.F4) & ";" & ASCII.LF);
         elsif S (R.Tag) = "advanced" then
            Append (Adb, "         when Advanced_" & S (R.F2) & " => return Role_Muted;" & ASCII.LF);
         end if;
      end loop;
      Append (Adb, "      end case;" & ASCII.LF & "   end Display_Role;" & ASCII.LF & "end Backup.CLI_Surface;");
      Emit ("src/backup-cli_surface.adb", S (Adb));
   end Generate_Ada;
begin
   Load;
   Copy ("share/completions/backup.bash");
   Copy ("share/completions/backup.fish");
   Copy ("share/completions/backup.ps1");
   Copy ("share/completions/_backup");
   Generate_Doc;
   Generate_Catalog;
   Generate_Ada;
   Backup_Tool_Support.Run
     ("generate man page", "tools/bin/generate_manpage",
      [1 => new String'(Out_Dir & "/share/man/man1/backup.1")], Quiet => True);
exception
   when Program_Error => null;
end Generate_CLI_Surface;
