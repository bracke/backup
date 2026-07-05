with Ada.Command_Line;
with Ada.Containers;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with GNAT.Directory_Operations;
with GNAT.OS_Lib;

with Backup.CLI;
with Backup.Paths;
with Backup.Platform;
with Backup.Scanner;
with Backup.Zip;

procedure Backup_Scanner_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Directories.File_Kind;
   use type Ada.Containers.Count_Type;
   use type Interfaces.Unsigned_64;
   use type Backup.Scanner.Scan_Status;
   use type Backup.Scanner.Ignored_Kind;
   use type Backup.Scanner.Entry_Kind;
   use type Backup.Zip.Compression_Method;

   Failures : Natural := 0;
   Root     : constant String := "tmp_scanner_tests";

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

   procedure Try_Delete_File (Path : String) is
      Removed : Boolean := False;
   begin
      begin
         Ada.Directories.Delete_File (Path);
      exception
         when others =>
            GNAT.OS_Lib.Delete_File (Path, Removed);
      end;
   end Try_Delete_File;

   procedure Try_Delete_Directory (Path : String) is
   begin
      begin
         Ada.Directories.Delete_Directory (Path);
      exception
         when others =>
            null;
      end;
   end Try_Delete_Directory;

   procedure Remove_Tree (Path : String);

   procedure Remove_Tree (Path : String) is
      Dir     : GNAT.Directory_Operations.Dir_Type;
      Name    : String (1 .. 4096);
      Last    : Natural := 0;
      Started : Boolean := False;
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Path) then
         Try_Delete_File (Path);
         return;
      end if;

      if not Ada.Directories.Exists (Path) then
         Try_Delete_File (Path);
         return;
      end if;

      if Ada.Directories.Kind (Path) = Ada.Directories.Directory then
         GNAT.Directory_Operations.Open (Dir, Path);
         Started := GNAT.Directory_Operations.Is_Open (Dir);
         while Started loop
            GNAT.Directory_Operations.Read (Dir, Name, Last);
            exit when Last = 0;
            declare
               Simple : constant String := Name (Name'First .. Last);
               Child  : constant String := Path & "/" & Simple;
            begin
               if Simple /= "." and then Simple /= ".." then
                  if GNAT.OS_Lib.Is_Symbolic_Link (Child) then
                     Try_Delete_File (Child);
                  else
                     Remove_Tree (Child);
                  end if;
               end if;
            end;
         end loop;
         GNAT.Directory_Operations.Close (Dir);
         Started := False;
         begin
            Ada.Directories.Delete_Directory (Path);
         exception
            when others =>
               Try_Delete_Directory (Path);
         end;
      else
         Try_Delete_File (Path);
      end if;
   exception
      when others =>
         if Started then
            begin
               GNAT.Directory_Operations.Close (Dir);
            exception
               when others =>
                  null;
            end;
         end if;
         Try_Delete_File (Path);
         Try_Delete_Directory (Path);
   end Remove_Tree;

   procedure Cleanup_Root is
   begin
      Remove_Tree (Root);
   end Cleanup_Root;

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Directory (Path);
      end if;
   end Ensure_Directory;

   procedure Write_File
     (Path : String;
      Text : String)
   is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      if Text'Length > 0 then
         declare
            Data : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
            Pos  : Ada.Streams.Stream_Element_Offset := Data'First;
         begin
            for Ch of Text loop
               Data (Pos) := Ada.Streams.Stream_Element (Character'Pos (Ch));
               Pos := Pos + Ada.Streams.Stream_Element_Offset (1);
            end loop;
            Ada.Streams.Stream_IO.Write (File, Data);
         end;
      end if;
      Ada.Streams.Stream_IO.Close (File);
   end Write_File;

   function Base_Config return Backup.CLI.Configuration is
      Config : Backup.CLI.Configuration;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/out.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Skip;
      return Config;
   end Base_Config;

   function Archive_At
     (Entries : Backup.Scanner.Entry_Vectors.Vector;
      Index   : Positive)
      return String
   is
   begin
      return Backup.Paths.To_String (Entries.Element (Index).Archive_Path);
   end Archive_At;

   function Set_Permissions
     (Path : String;
      Mode : Interfaces.Unsigned_32)
      return Boolean
   is
   begin
      return Backup.Platform.Set_Permissions (Path, Mode);
   end Set_Permissions;

   function Create_Symlink
     (Target    : String;
      Link_Path : String)
      return Boolean
   is
   begin
      return Backup.Platform.Create_Symlink (Target, Link_Path);
   end Create_Symlink;

   Entries    : Backup.Scanner.Entry_Vectors.Vector;
   Diagnostic : Unbounded_String;
   Status     : Backup.Scanner.Scan_Status;
begin
   Cleanup_Root;
   Ensure_Directory (Root);

   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Write_File (Root & "/single.txt", "one");
      Config.Input_Paths.Append (Root & "/single.txt");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "single file scan succeeds");
      Check (Entries.Length = 1, "single file emits one entry");
      Check
        (Archive_At (Entries, 1) = "single.txt",
         "single file archive path");
      Check (Entries.Element (1).Byte_Size = 3, "single file size captured");
      Check (Entries.Element (1).Has_Modification_Time, "mtime captured");
      Check
        (Entries.Element (1).Compression_Method = Backup.Zip.Deflated,
         "scanner leaves initial method metadata for later policy pass");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Write_File (Root & "/store-request.txt", "one");
      Config.Compression := Backup.CLI.Compression_Store;
      Config.Input_Paths.Append (Root & "/store-request.txt");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "scanner succeeds when compression option is set");
      Check
        (Entries.Element (1).Compression_Method = Backup.Zip.Deflated,
         "scanner does not apply compression policy directly");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/tree");
   Ensure_Directory (Root & "/tree/b");
   Ensure_Directory (Root & "/tree/a");
   Write_File (Root & "/tree/b/two.txt", "two");
   Write_File (Root & "/tree/a/one.txt", "one");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/tree");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "nested directory scan succeeds");
      Check (Entries.Length = 2, "nested directory emits files only");
      Check (Archive_At (Entries, 1) = "tree/a/one.txt", "sorted first entry");
      Check
        (Archive_At (Entries, 2) = "tree/b/two.txt",
         "sorted second entry");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/left");
   Ensure_Directory (Root & "/right");
   Write_File (Root & "/left/a.txt", "a");
   Write_File (Root & "/right/b.txt", "b");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Input_Paths.Append (Root & "/left");
      Config.Input_Paths.Append (Root & "/right");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "multiple roots scan succeeds");
      Check (Entries.Length = 2, "multiple roots emit entries");
      Check (Archive_At (Entries, 1) = "left/a.txt", "first root entry");
      Check (Archive_At (Entries, 2) = "right/b.txt", "second root entry");
   end;

   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Prefix := To_Unbounded_String ("prefix/root");
      Config.Input_Paths.Append (Root & "/left/a.txt");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "prefix scan succeeds");
      Check
        (Archive_At (Entries, 1) = "prefix/root/a.txt",
         "prefix applied to scanned entry");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/a");
   Ensure_Directory (Root & "/b");
   Ensure_Directory (Root & "/a/root");
   Ensure_Directory (Root & "/b/root");
   Write_File (Root & "/a/root/same.txt", "a");
   Write_File (Root & "/b/root/same.txt", "b");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Input_Paths.Append (Root & "/a/root");
      Config.Input_Paths.Append (Root & "/b/root");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Duplicate_Archive_Path,
         "duplicate archive entry rejected during scan");
   end;

   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Input_Paths.Append (Root & "/missing.txt");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Missing_Input,
         "missing input diagnostic status");
   end;

   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/a/root/out.zip");
      Config.Input_Paths.Append (Root & "/a/root");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Output_Inside_Input,
         "output inside input directory rejected");
   end;

   declare
      Config : Backup.CLI.Configuration := Base_Config;
   begin
      Config.Output_Path := To_Unbounded_String
        (Ada.Directories.Full_Name (Root & "/a/root/out.zip"));
      Config.Input_Paths.Append (Root & "/a/root");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Output_Inside_Input,
         "absolute output inside relative input rejected");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/links");
   Write_File (Root & "/links/real.txt", "real");
   declare
      Config       : Backup.CLI.Configuration := Base_Config;
      Link_Created : constant Boolean :=
        Create_Symlink ("real.txt", Root & "/links/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/links");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "symlink directory scan succeeds");
      if Link_Created then
         Check (Entries.Length = 1, "default symlink mode skips symlink");
         Check
           (Archive_At (Entries, 1) = "links/real.txt",
            "symlink target file remains included");
      end if;
   end;

   declare
      Config         : Backup.CLI.Configuration := Base_Config;
      Link_Available : constant Boolean :=
        GNAT.OS_Lib.Is_Symbolic_Link (Root & "/links/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Store_Link;
      Config.Input_Paths.Append (Root & "/links");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "store-link symlink mode scan succeeds");
      if Link_Available then
         Check (Entries.Length = 2, "store-link includes file and symlink");
         if Entries.Length = 2 then
            declare
               Found : Boolean := False;
            begin
               for Item of Entries loop
                  if Item.Kind = Backup.Scanner.Entry_Symlink then
                     Found := True;
                     Check
                       (To_String (Item.Link_Target) = "real.txt",
                        "store-link preserves target text");
                     Check
                       (Item.Compression_Method = Backup.Zip.Stored,
                        "store-link forces stored method metadata");
                  end if;
               end loop;
               Check (Found, "store-link records symlink entry kind");
            end;
         end if;
      end if;
   end;

   declare
      Config         : Backup.CLI.Configuration := Base_Config;
      Link_Available : constant Boolean :=
        GNAT.OS_Lib.Is_Symbolic_Link (Root & "/links/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Follow;
      Config.Input_Paths.Append (Root & "/links");
      Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "follow symlink mode scan succeeds");
      if Link_Available then
         Check
           (Entries.Length = 2,
            "follow mode includes real file and followed link target");
         if Entries.Length = 2 then
            declare
               Found : Boolean := False;
            begin
               for Index in Entries.First_Index .. Entries.Last_Index loop
                  if Archive_At (Entries, Index) = "links/link.txt" then
                     Found := True;
                     Check
                       (Entries.Element (Index).Kind = Backup.Scanner.Entry_File,
                        "follow mode emits followed symlink as regular file entry");
                  end if;
               end loop;
               Check (Found, "follow mode archives target under link path");
            end;
         end if;
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/broken");
   declare
      Config       : Backup.CLI.Configuration := Base_Config;
      Link_Created : constant Boolean :=
        Create_Symlink ("missing.txt", Root & "/broken/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Follow;
      Config.Input_Paths.Append (Root & "/broken/link.txt");
      if Link_Created then
         Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Symlink_Broken,
            "follow mode reports broken symlink: " & Backup.Scanner.Scan_Status'Image (Status));
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/outside_target");
   Ensure_Directory (Root & "/with_outside_link");
   Write_File (Root & "/outside_target/file.txt", "x");
   declare
      Config       : Backup.CLI.Configuration := Base_Config;
      Link_Created : constant Boolean :=
        Create_Symlink
          ("../outside_target/file.txt",
           Root & "/with_outside_link/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Follow;
      Config.Input_Paths.Append (Root & "/with_outside_link");
      if Link_Created then
         Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Symlink_Target_Outside_Input,
            "follow mode rejects symlink targets outside input root");
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/multi_left");
   Ensure_Directory (Root & "/multi_right");
   Write_File (Root & "/multi_right/target.txt", "x");
   declare
      Config       : Backup.CLI.Configuration := Base_Config;
      Link_Created : constant Boolean :=
        Create_Symlink
          ("../multi_right/target.txt",
           Root & "/multi_left/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Follow;
      Config.Input_Paths.Append (Root & "/multi_left");
      Config.Input_Paths.Append (Root & "/multi_right");
      if Link_Created then
         Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Ok,
            "follow mode allows target inside another scanned input root");
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/chain");
   Write_File (Root & "/chain/real.txt", "real");
   declare
      Config       : Backup.CLI.Configuration := Base_Config;
      First_Link   : constant Boolean :=
        Create_Symlink ("second.txt", Root & "/chain/first.txt");
      Second_Link  : constant Boolean :=
        Create_Symlink ("real.txt", Root & "/chain/second.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Follow;
      Config.Input_Paths.Append (Root & "/chain/first.txt");
      if First_Link and then Second_Link then
         Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Symlink_Cycle,
            "follow mode rejects symlink chain cycle: " & Backup.Scanner.Scan_Status'Image (Status));
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/cycle");
   declare
      Config      : Backup.CLI.Configuration := Base_Config;
      First_Link  : constant Boolean :=
        Create_Symlink ("b", Root & "/cycle/a");
      Second_Link : constant Boolean :=
        Create_Symlink ("a", Root & "/cycle/b");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Follow;
      Config.Input_Paths.Append (Root & "/cycle/a");
      if First_Link and then Second_Link then
         Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Symlink_Cycle,
            "follow mode rejects tight symlink loop as cycle: " & Backup.Scanner.Scan_Status'Image (Status));
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/dangling_store");
   declare
      Config       : Backup.CLI.Configuration := Base_Config;
      Link_Created : constant Boolean :=
        Create_Symlink ("missing.txt", Root & "/dangling_store/link.txt");
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Symlinks := Backup.CLI.Symlinks_Store_Link;
      Config.Input_Paths.Append (Root & "/dangling_store/link.txt");
      if Link_Created then
         Status := Backup.Scanner.Scan (Config, Entries, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Ok,
            "store-link mode archives dangling symlink text");
         Check (Entries.Length = 1, "dangling stored symlink emits one entry");
         if Entries.Length = 1 then
            Check
              (Entries.Element (1).Kind = Backup.Scanner.Entry_Symlink,
               "dangling stored entry is symlink kind");
            Check
              (To_String (Entries.Element (1).Link_Target) = "missing.txt",
               "dangling stored entry preserves target text");
         end if;
      end if;
   end;




   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/root_ignore");
   Write_File (Root & "/root_rules.txt", "root_ignore/drop.txt" & ASCII.LF);
   Write_File (Root & "/root_ignore/drop.txt", "drop");
   Write_File (Root & "/root_ignore/keep.txt", "keep");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Ignore_Files.Append (Root & "/root_rules.txt");
      Config.Input_Paths.Append (Root & "/root_ignore");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "CLI root ignore scan succeeds");
      Check (Report.Entries.Length = 1, "CLI root ignore excludes file");
      Check
        (Backup.Paths.To_String (Report.Entries.Element (1).Archive_Path)
         = "root_ignore/keep.txt",
         "CLI root ignore keeps unmatched file");
      Check
        (Report.Ignored_Diagnostics.Length = 1,
         "CLI root ignore records ignored diagnostic");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/order");
   Write_File (Root & "/first.ignore", "order/item.txt" & ASCII.LF);
   Write_File (Root & "/second.ignore", "!order/item.txt" & ASCII.LF);
   Write_File (Root & "/order/item.txt", "item");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Ignore_Files.Append (Root & "/first.ignore");
      Config.Ignore_Files.Append (Root & "/second.ignore");
      Config.Input_Paths.Append (Root & "/order");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "repeated CLI ignore files scan succeeds");
      Check
        (Report.Entries.Length = 1,
         "later CLI ignore file re-includes earlier ignored path");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/local");
   Write_File (Root & "/local/.gitignore", "*.tmp" & ASCII.LF);
   Write_File (Root & "/local/a.tmp", "tmp");
   Write_File (Root & "/local/a.txt", "txt");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/local");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "discovered .gitignore scan succeeds");
      Check
        (Report.Entries.Length = 2,
         "discovered .gitignore excludes matching descendant only");
      Check
        (Report.Ignored_Diagnostics.Length = 1,
         "discovered .gitignore records ignored file");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/inherit");
   Ensure_Directory (Root & "/inherit/sub");
   Write_File (Root & "/inherit/.gitignore", "*.log" & ASCII.LF);
   Write_File (Root & "/inherit/sub/a.log", "log");
   Write_File (Root & "/inherit/sub/a.txt", "txt");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/inherit");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "inherited .gitignore scan succeeds");
      Check (Report.Ignored_Diagnostics.Length = 1, "inherited rule ignores child file");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/override");
   Ensure_Directory (Root & "/override/sub");
   Write_File (Root & "/override/.gitignore", "*.log" & ASCII.LF);
   Write_File (Root & "/override/sub/.gitignore", "!keep.log" & ASCII.LF);
   Write_File (Root & "/override/sub/keep.log", "keep");
   Write_File (Root & "/override/sub/drop.log", "drop");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/override");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "local override scan succeeds");
      Check
        (Report.Ignored_Diagnostics.Length = 1,
         "local negation overrides inherited rule for one file");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/prune");
   Ensure_Directory (Root & "/prune/build");
   Write_File (Root & "/prune/.gitignore", "build/" & ASCII.LF & "!build/keep.txt" & ASCII.LF);
   Write_File (Root & "/prune/build/keep.txt", "keep");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/prune");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "ignored directory prune scan succeeds");
      Check
        (Report.Ignored_Diagnostics.Length = 1,
         "ignored directory has one prune diagnostic");
      Check
        (Report.Ignored_Diagnostics.Element (1).Pruned_Descendants,
         "ignored directory diagnostic marks pruning");
      Check
        (Report.Entries.Length = 1,
         "descendant of pruned directory is not re-included");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/badignore");
   Write_File (Root & "/badignore/.gitignore", "bad[glob" & ASCII.LF);
   Write_File (Root & "/badignore/file.txt", "x");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/badignore");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ignore_File_Error,
         "parse error in discovered .gitignore is reported");
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/dup_ignore_left");
   Ensure_Directory (Root & "/dup_ignore_right");
   Ensure_Directory (Root & "/dup_ignore_left/root");
   Ensure_Directory (Root & "/dup_ignore_right/root");
   Write_File (Root & "/dup_ignore_left/root/same.txt", "a");
   Write_File (Root & "/dup_ignore_right/root/same.txt", "b");
   Write_File (Root & "/dup_rules.txt", "root/same.txt" & ASCII.LF);
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Ignore_Files.Append (Root & "/dup_rules.txt");
      Config.Input_Paths.Append (Root & "/dup_ignore_left/root");
      Config.Input_Paths.Append (Root & "/dup_ignore_right/root");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "ignored duplicate candidate does not trigger duplicate archive error");
      Check
        (Report.Entries.Length = 0,
         "ignored duplicate archive paths are not emitted");
   end;


   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/reinclude");
   Ensure_Directory (Root & "/reinclude/build");
   Write_File
     (Root & "/reinclude/.gitignore",
      "build/*" & ASCII.LF & "!build/keep.txt" & ASCII.LF);
   Write_File (Root & "/reinclude/build/keep.txt", "keep");
   Write_File (Root & "/reinclude/build/drop.txt", "drop");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/reinclude");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "negation re-inclusion scan succeeds when parent is not pruned");
      Check
        (Report.Ignored_Diagnostics.Length = 1,
         "non-pruned negation leaves one ignored file");
      Check
        (Report.Entries.Length = 2,
         "non-pruned negation includes .gitignore and re-included file");
      if Report.Entries.Length = 2 then
         Check
           (Backup.Paths.To_String (Report.Entries.Element (2).Archive_Path)
            = "reinclude/build/keep.txt",
            "non-pruned negation re-includes descendant file");
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/diag");
   Write_File (Root & "/diag/.gitignore", "ignored.txt" & ASCII.LF);
   Write_File (Root & "/diag/ignored.txt", "ignored");
   Write_File (Root & "/diag/kept.txt", "kept");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/diag");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check (Status = Backup.Scanner.Scan_Ok, "ignored diagnostic scan succeeds");
      Check
        (Report.Ignored_Diagnostics.Length = 1,
         "ignored file diagnostic is retained");
      if Report.Ignored_Diagnostics.Length = 1 then
         Check
           (To_String
              (Report.Ignored_Diagnostics.Element (1).Archive_Path)
            = "diag/ignored.txt",
            "ignored diagnostic stores archive path");
         Check
           (Report.Ignored_Diagnostics.Element (1).Kind
            = Backup.Scanner.Ignored_File,
            "ignored diagnostic stores file kind");
         Check
           (Report.Ignored_Diagnostics.Element (1).Matching_Line_Number = 1,
            "ignored diagnostic stores matching line number");
         Check
           (To_String
              (Report.Ignored_Diagnostics.Element (1).Matching_Original_Text)
            = "ignored.txt",
            "ignored diagnostic stores matching original text");
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/stable");
   Ensure_Directory (Root & "/stable/a");
   Ensure_Directory (Root & "/stable/b");
   Write_File (Root & "/stable/.gitignore", "*.drop" & ASCII.LF);
   Write_File (Root & "/stable/b/2.keep", "2");
   Write_File (Root & "/stable/a/1.keep", "1");
   Write_File (Root & "/stable/a/0.drop", "0");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/stable");
      Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
      Check
        (Status = Backup.Scanner.Scan_Ok,
         "deterministic ordering with discovered ignore succeeds");
      Check
        (Report.Entries.Length = 3,
         "deterministic ordering emits expected kept entries");
      if Report.Entries.Length = 3 then
         Check
           (Backup.Paths.To_String (Report.Entries.Element (1).Archive_Path)
            = "stable/.gitignore",
            "discovered ignore file keeps sorted position");
         Check
           (Backup.Paths.To_String (Report.Entries.Element (2).Archive_Path)
            = "stable/a/1.keep",
            "first kept descendant is sorted");
         Check
           (Backup.Paths.To_String (Report.Entries.Element (3).Archive_Path)
            = "stable/b/2.keep",
            "second kept descendant is sorted");
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/unreadable_root_ignore");
   Write_File (Root & "/unreadable.ignore", "*.tmp" & ASCII.LF);
   Write_File (Root & "/unreadable_root_ignore/file.txt", "x");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
      Permission_Changed : constant Boolean :=
        Set_Permissions (Root & "/unreadable.ignore", 8#000#);
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Ignore_Files.Append (Root & "/unreadable.ignore");
      Config.Input_Paths.Append (Root & "/unreadable_root_ignore");
      if Permission_Changed
        and then not GNAT.OS_Lib.Is_Readable_File (Root & "/unreadable.ignore")
      then
         Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Ignore_File_Error,
            "unreadable CLI root ignore file is reported");
      end if;
      if Permission_Changed then
         Check
           (Set_Permissions (Root & "/unreadable.ignore", 8#600#),
            "unreadable CLI root ignore permissions restored");
      end if;
   end;

   Cleanup_Root;
   Ensure_Directory (Root);
   Ensure_Directory (Root & "/unreadable_local_ignore");
   Write_File (Root & "/unreadable_local_ignore/.gitignore", "*.tmp" & ASCII.LF);
   Write_File (Root & "/unreadable_local_ignore/file.txt", "x");
   declare
      Config : Backup.CLI.Configuration := Base_Config;
      Report : Backup.Scanner.Scan_Report;
      Permission_Changed : constant Boolean :=
        Set_Permissions (Root & "/unreadable_local_ignore/.gitignore", 8#000#);
   begin
      Config.Output_Path := To_Unbounded_String (Root & "/outside.zip");
      Config.Input_Paths.Append (Root & "/unreadable_local_ignore");
      if Permission_Changed
        and then not GNAT.OS_Lib.Is_Readable_File
          (Root & "/unreadable_local_ignore/.gitignore")
      then
         Status := Backup.Scanner.Scan (Config, Report, Diagnostic);
         Check
           (Status = Backup.Scanner.Scan_Ignore_File_Error,
            "unreadable discovered .gitignore is reported");
      end if;
      if Permission_Changed then
         Check
           (Set_Permissions
              (Root & "/unreadable_local_ignore/.gitignore", 8#600#),
            "unreadable discovered .gitignore permissions restored");
      end if;
   end;

   Cleanup_Root;
   Check (not Ada.Directories.Exists (Root), "scanner scratch root is removed");

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup scanner tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup scanner test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Scanner_Tests;
