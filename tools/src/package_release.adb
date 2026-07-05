with Ada.Command_Line;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
use type Ada.Directories.File_Kind;
with Interfaces;

with Backup_Tool_Support;

procedure Package_Release is
   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   Out_Dir  : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1)
      else "/tmp/backup-release-package");
   Stage    : constant String := Out_Dir & "/stage";
   Archive_Package : constant String := Out_Dir & "/backup-release-smoke.tar.gz";
   Checksum : constant String := Archive_Package & ".cksum";
   Manifest : constant String := Out_Dir & "/MANIFEST.txt";

   Files : String_Vectors.Vector;

   --  Emit POSIX cksum-compatible CRC and byte count without a shell script.
   function CRC32_CKSum (Path : String) return String is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
      Buf  : Ada.Streams.Stream_Element_Array (1 .. 8192);
      Last : Ada.Streams.Stream_Element_Offset;
      CRC  : Interfaces.Unsigned_32 := 0;
      Len  : Interfaces.Unsigned_64 := 0;
      use type Interfaces.Unsigned_32;
      use type Interfaces.Unsigned_64;

      procedure Update (Byte : Interfaces.Unsigned_8) is
      begin
         CRC := CRC xor Interfaces.Shift_Left (Interfaces.Unsigned_32 (Byte), 24);
         for Bit in 1 .. 8 loop
            if (CRC and 16#8000_0000#) /= 0 then
               CRC := Interfaces.Shift_Left (CRC, 1) xor 16#04C1_1DB7#;
            else
               CRC := Interfaces.Shift_Left (CRC, 1);
            end if;
         end loop;
      end Update;
   begin
      SIO.Open (File, SIO.In_File, Path);
      while not SIO.End_Of_File (File) loop
         SIO.Read (File, Buf, Last);
         for I in Buf'First .. Last loop
            Update (Interfaces.Unsigned_8 (Buf (I)));
            Len := Len + 1;
         end loop;
      end loop;
      SIO.Close (File);

      declare
         N : Interfaces.Unsigned_64 := Len;
      begin
         while N /= 0 loop
            Update (Interfaces.Unsigned_8 (N and 16#FF#));
            N := Interfaces.Shift_Right (N, 8);
         end loop;
      end;

      CRC := not CRC;
      return Interfaces.Unsigned_32'Image (CRC) & Interfaces.Unsigned_64'Image (Len) & " " & Path;
   end CRC32_CKSum;

   procedure Gather (Path : String) is
      Search : Ada.Directories.Search_Type;
      Dirent : Ada.Directories.Directory_Entry_Type;
   begin
      Ada.Directories.Start_Search (Search, Path, "*");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dirent);
         declare
            Full : constant String := Ada.Directories.Full_Name (Dirent);
            Name : constant String := Ada.Directories.Simple_Name (Dirent);
         begin
            if Ada.Directories.Kind (Dirent) = Ada.Directories.Ordinary_File then
               Files.Append (Full);
            elsif Ada.Directories.Kind (Dirent) = Ada.Directories.Directory
              and then Name /= "." and then Name /= ".."
            then
               Gather (Full);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Gather;

   function Less (Left, Right : String) return Boolean is (Left < Right);
   package Sorting is new String_Vectors.Generic_Sorting ("<" => Less);
begin
   Backup_Tool_Support.Remove_Tree (Out_Dir);
   Backup_Tool_Support.Write_Text (Out_Dir & "/.keep", "");
   Backup_Tool_Support.Run
     ("install backup", "alr",
      [1 => new String'("exec"), 2 => new String'("--"), 3 => new String'("gprinstall"),
       4 => new String'("-p"), 5 => new String'("-P"), 6 => new String'("backup.gpr"),
       7 => new String'("--prefix=" & Stage)]);
   Backup_Tool_Support.Require_File (Stage & "/bin/backup");
   Backup_Tool_Support.Require_File (Stage & "/share/gpr/backup.gpr");
   Backup_Tool_Support.Require_File (Stage & "/share/backup/messages.catalog");
   Backup_Tool_Support.Require_File (Stage & "/share/man/man1/backup.1");
   Backup_Tool_Support.Require_Contains (Stage & "/share/completions/backup.bash", "complete -F _backup_complete backup", "bash completion missing install content");
   Backup_Tool_Support.Require_Contains (Stage & "/share/completions/backup.fish", "complete -c backup", "fish completion missing install content");
   Backup_Tool_Support.Require_Contains (Stage & "/share/completions/backup.ps1", "Register-ArgumentCompleter -Native -CommandName backup", "PowerShell completion missing install content");
   Backup_Tool_Support.Require_File (Stage & "/share/completions/_backup");
   Backup_Tool_Support.Require_File (Stage & "/share/examples/backup/example.conf");

   Gather (Stage);
   Sorting.Sort (Files);
   declare
      Manifest_File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (Manifest_File, Ada.Text_IO.Out_File, Manifest);
      for Path of Files loop
         Ada.Text_IO.Put_Line (Manifest_File, Path);
      end loop;
      Ada.Text_IO.Close (Manifest_File);
   end;

   Backup_Tool_Support.Run ("package release", "tar", [1 => new String'("-C"), 2 => new String'(Stage), 3 => new String'("-czf"), 4 => new String'(Archive_Package), 5 => new String'(".")]);
   Backup_Tool_Support.Write_Text (Checksum, CRC32_CKSum (Archive_Package) & ASCII.LF);
   Backup_Tool_Support.Require_File (Archive_Package);
   Backup_Tool_Support.Require_File (Checksum);
   Ada.Text_IO.Put_Line (Archive_Package);
exception
   when Program_Error => null;
end Package_Release;
