with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Processes;

package body Backup_Tool_Support is
   function Env (Name : String; Default : String := "") return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         return Ada.Environment_Variables.Value (Name);
      end if;
      return Default;
   end Env;

   function Contains (Path : String; Pattern : String) return Boolean is
   begin
      return Project_Tools.Files.File_Contains (Path, Pattern);
   exception
      when others =>
         return False;
   end Contains;

   function Same_File (Left, Right : String) return Boolean is
   begin
      return Project_Tools.Files.Read_Raw_File (Left) =
        Project_Tools.Files.Read_Raw_File (Right);
   exception
      when others =>
         return False;
   end Same_File;

   function Tool_Path (Name : String) return String is
   begin
      return "tools/bin/" & Name;
   end Tool_Path;

   procedure Fail (Message : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Message);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end Fail;

   procedure Require_File (Path : String; Message : String := "required file is missing") is
   begin
      if not Project_Tools.Files.File_Exists (Path) then
         Fail (Message & ": " & Path);
      end if;
   end Require_File;

   procedure Require_Contains (Path : String; Pattern : String; Message : String) is
   begin
      if not Contains (Path, Pattern) then
         Fail (Message & ": " & Path);
      end if;
   end Require_Contains;

   procedure Ensure_Parent (Path : String) is
      Dir : constant String := Ada.Directories.Containing_Directory (Path);
   begin
      if Dir'Length > 0 and then Dir /= "." then
         Ada.Directories.Create_Path (Dir);
      end if;
   exception
      when Ada.Directories.Name_Error =>
         null;
   end Ensure_Parent;

   procedure Copy_File_To (Source, Target : String) is
   begin
      Ensure_Parent (Target);
      Ada.Directories.Copy_File (Source, Target);
   end Copy_File_To;

   procedure Write_Text (Path : String; Content : String) is
   begin
      Ensure_Parent (Path);
      Project_Tools.Files.Write_Text_File (Path, Content);
   end Write_Text;

   procedure Write_Zero_File (Path : String; Size : Natural) is
      package SIO renames Ada.Streams.Stream_IO;
      File  : SIO.File_Type;
      Chunk : constant Ada.Streams.Stream_Element_Array (1 .. 8192) := (others => 0);
      Left  : Natural := Size;
   begin
      Ensure_Parent (Path);
      SIO.Create (File, SIO.Out_File, Path);
      while Left > 0 loop
         declare
            Count : constant Natural := Natural'Min (Left, Chunk'Length);
         begin
            SIO.Write (File, Chunk (1 .. Ada.Streams.Stream_Element_Offset (Count)));
            Left := Left - Count;
         end;
      end loop;
      SIO.Close (File);
   end Write_Zero_File;

   procedure Remove_Tree (Path : String) is
   begin
      Project_Tools.Files.Delete_Tree (Path);
   end Remove_Tree;

   procedure Run
     (Label   : String;
      Program : String;
      Args    : GNAT.OS_Lib.Argument_List;
      Dir     : String := ".";
      Quiet   : Boolean := False) is
   begin
      declare
         Resolved : constant String :=
           (if Program'Length > 0 and then Program (Program'First) = '.' then Program
            elsif Program'Length > 0 and then Program (Program'First) = '/' then Program
            else Project_Tools.Processes.Locate_Command (Program));
      begin
         if Resolved = "" then
            Fail ("required executable not found: " & Program);
         end if;
         Project_Tools.Processes.Run (Label, Dir, Resolved, Args, Quiet);
      end;
   end Run;
end Backup_Tool_Support;
