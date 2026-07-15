with Ada.Characters.Handling;


package body Backup.Compression is
   use type Backup.CLI.Compression_Mode;
   use type Backup.Scanner.Entry_Kind;

   function Lowercase_Extension (Archive_Path : String) return String is
      Last_Slash : Natural := 0;
      Last_Dot   : Natural := 0;
   begin
      for Index in Archive_Path'Range loop
         if Archive_Path (Index) = '/' then
            Last_Slash := Index;
            Last_Dot := 0;
         elsif Archive_Path (Index) = '.' then
            Last_Dot := Index;
         end if;
      end loop;

      if Last_Dot = 0
        or else Last_Dot <= Last_Slash
        or else Last_Dot = Archive_Path'Last
      then
         return "";
      end if;

      return Ada.Characters.Handling.To_Lower
        (Archive_Path (Last_Dot + 1 .. Archive_Path'Last));
   end Lowercase_Extension;

   function Is_Stored_Extension (Extension : String) return Boolean is
   begin
      return Extension = "jpg"
        or else Extension = "jpeg"
        or else Extension = "png"
        or else Extension = "gif"
        or else Extension = "webp"
        or else Extension = "mp3"
        or else Extension = "mp4"
        or else Extension = "mov"
        or else Extension = "mkv"
        or else Extension = "avi"
        or else Extension = "zip"
        or else Extension = "gz"
        or else Extension = "xz"
        or else Extension = "bz2"
        or else Extension = "7z"
        or else Extension = "rar"
        or else Extension = "pdf"
        or else Extension = "docx"
        or else Extension = "xlsx"
        or else Extension = "pptx"
        or else Extension = "odt"
        or else Extension = "ods"
        or else Extension = "odp"
        or else Extension = "epub"
        or else Extension = "apk"
        or else Extension = "jar"
        or else Extension = "war";
   end Is_Stored_Extension;

   function Is_Deflated_Extension (Extension : String) return Boolean is
   begin
      return Extension = "txt"
        or else Extension = "md"
        or else Extension = "json"
        or else Extension = "xml"
        or else Extension = "yaml"
        or else Extension = "yml"
        or else Extension = "toml"
        or else Extension = "ini"
        or else Extension = "csv"
        or else Extension = "adb"
        or else Extension = "ads"
        or else Extension = "c"
        or else Extension = "h"
        or else Extension = "cpp"
        or else Extension = "hpp"
        or else Extension = "rs"
        or else Extension = "py"
        or else Extension = "js"
        or else Extension = "ts"
        or else Extension = "html"
        or else Extension = "css"
        or else Extension = "svg"
        or else Extension = "log";
   end Is_Deflated_Extension;

   function Method_For_Archive_Path
     (Archive_Path : String;
      Mode         : Backup.CLI.Compression_Mode)
      return Backup.Zip.Compression_Method
   is
   begin
      pragma Assert
        (Archive_Path'Length > 0,
         "compression policy requires a non-empty archive path");

      declare
         Extension : constant String := Lowercase_Extension (Archive_Path);
      begin
         if Mode = Backup.CLI.Compression_Store then
            return Backup.Zip.Stored;
         elsif Mode = Backup.CLI.Compression_Deflate then
            return Backup.Zip.Deflated;
         elsif Mode = Backup.CLI.Compression_BZip2 then
            return Backup.Zip.BZip2;
         elsif Mode = Backup.CLI.Compression_LZMA then
            return Backup.Zip.LZMA;
         elsif Mode = Backup.CLI.Compression_Zstd then
            return Backup.Zip.Zstd;
         elsif Is_Stored_Extension (Extension) then
            return Backup.Zip.Stored;
         elsif Is_Deflated_Extension (Extension) then
            return Backup.Zip.Deflated;
         else
            return Backup.Zip.Deflated;
         end if;
      end;
   end Method_For_Archive_Path;

   function Method_For_Archive_Path
     (Archive_Path : Backup.Paths.Archive_Path;
      Mode         : Backup.CLI.Compression_Mode)
      return Backup.Zip.Compression_Method
   is
   begin
      return Method_For_Archive_Path
        (Backup.Paths.To_String (Archive_Path), Mode);
   end Method_For_Archive_Path;

   procedure Apply
     (Mode    : Backup.CLI.Compression_Mode;
      Entries : in out Backup.Scanner.Entry_Vectors.Vector)
   is
   begin
      if Entries.Is_Empty then
         return;
      end if;

      for Index in Entries.First_Index .. Entries.Last_Index loop
         declare
            Item         : Backup.Scanner.Discovered_Entry :=
              Entries.Element (Index);
         begin
            if Item.Kind = Backup.Scanner.Entry_Symlink then
               Item.Compression_Method := Backup.Zip.Stored;
            else
               Item.Compression_Method :=
                 Method_For_Archive_Path (Item.Archive_Path, Mode);
            end if;
            Entries.Replace_Element (Index, Item);
         end;
      end loop;
   end Apply;
end Backup.Compression;
