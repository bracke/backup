with Ada.Calendar;
with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Backup.CLI;
with Backup.Compression;
with Backup.Paths;
with Backup.Scanner;
with Backup.Zip;

procedure Backup_Compression_Tests is
   use type Backup.Paths.Validation_Status;
   use type Backup.Zip.Compression_Method;

   Failures : Natural := 0;

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

   function Method
     (Archive_Path : String;
      Mode         : Backup.CLI.Compression_Mode)
      return Backup.Zip.Compression_Method
   is
   begin
      return Backup.Compression.Method_For_Archive_Path
        (Archive_Path, Mode);
   end Method;

   procedure Append_Entry
     (Entries      : in out Backup.Scanner.Entry_Vectors.Vector;
      Archive_Text : String)
   is
      Source  : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (Archive_Text);
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      Status := Backup.Paths.Make_Archive_Path (Archive_Text, Archive);
      pragma Assert
        (Status = Backup.Paths.Valid,
         "test archive path must be valid");

      Entries.Append
        (Backup.Scanner.Discovered_Entry'(Source_Path           => Source,
          Archive_Path          => Archive,
          Kind                  => Backup.Scanner.Entry_File,
          Byte_Size             => 0,
          Has_Modification_Time => False,
          Modification_Time     => Ada.Calendar.Time_Of (1901, 1, 1),
          Compression_Method    => Backup.Zip.Stored,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Link_Target           => Ada.Strings.Unbounded.Null_Unbounded_String));
   end Append_Entry;

   Entries : Backup.Scanner.Entry_Vectors.Vector;
begin
   Check
     (Method ("image.jpg", Backup.CLI.Compression_Store)
      = Backup.Zip.Stored,
      "forced store stores jpg");
   Check
     (Method ("README.md", Backup.CLI.Compression_Store)
      = Backup.Zip.Stored,
      "forced store stores text");
   Check
     (Method ("image.jpg", Backup.CLI.Compression_Deflate)
      = Backup.Zip.Deflated,
      "forced deflate deflates jpg");
   Check
     (Method ("README.md", Backup.CLI.Compression_BZip2)
      = Backup.Zip.BZip2,
      "forced bzip2 uses ZIP method 12 for text");
   Check
     (Method ("image.jpg", Backup.CLI.Compression_BZip2)
      = Backup.Zip.BZip2,
      "forced bzip2 overrides stored extension policy");
   Check
     (Method ("README.md", Backup.CLI.Compression_LZMA)
      = Backup.Zip.LZMA,
      "forced lzma uses ZIP method 14 for text");
   Check
     (Method ("README.md", Backup.CLI.Compression_Zstd)
      = Backup.Zip.Zstd,
      "forced zstd uses ZIP method 93 for text");
   Check
     (Method ("README.md", Backup.CLI.Compression_Deflate)
      = Backup.Zip.Deflated,
      "forced deflate deflates text");

   Check
     (Method ("photo.JPG", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores compressed extension case-insensitively");
   Check
     (Method ("movie.MP4", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores video extension case-insensitively");
   Check
     (Method ("doc.pdf", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores document container extension");
   Check
     (Method ("src/main.adb", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates Ada body");
   Check
     (Method ("config.JSON", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates text extension case-insensitively");

   --  Completeness coverage for the documented extension tables.
   Check
     (Method ("sample.jpg", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .jpg");
   Check
     (Method ("sample.jpeg", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .jpeg");
   Check
     (Method ("sample.png", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .png");
   Check
     (Method ("sample.gif", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .gif");
   Check
     (Method ("sample.webp", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .webp");
   Check
     (Method ("sample.mp3", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .mp3");
   Check
     (Method ("sample.mp4", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .mp4");
   Check
     (Method ("sample.mov", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .mov");
   Check
     (Method ("sample.mkv", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .mkv");
   Check
     (Method ("sample.avi", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .avi");
   Check
     (Method ("sample.zip", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .zip");
   Check
     (Method ("sample.gz", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .gz");
   Check
     (Method ("sample.xz", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .xz");
   Check
     (Method ("sample.bz2", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .bz2");
   Check
     (Method ("sample.7z", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .7z");
   Check
     (Method ("sample.rar", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .rar");
   Check
     (Method ("sample.pdf", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .pdf");
   Check
     (Method ("sample.docx", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .docx");
   Check
     (Method ("sample.xlsx", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .xlsx");
   Check
     (Method ("sample.pptx", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .pptx");
   Check
     (Method ("sample.odt", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .odt");
   Check
     (Method ("sample.ods", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .ods");
   Check
     (Method ("sample.odp", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .odp");
   Check
     (Method ("sample.epub", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .epub");
   Check
     (Method ("sample.apk", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .apk");
   Check
     (Method ("sample.jar", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .jar");
   Check
     (Method ("sample.war", Backup.CLI.Compression_Auto)
      = Backup.Zip.Stored,
      "auto stores .war");
   Check
     (Method ("sample.txt", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .txt");
   Check
     (Method ("sample.md", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .md");
   Check
     (Method ("sample.json", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .json");
   Check
     (Method ("sample.xml", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .xml");
   Check
     (Method ("sample.yaml", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .yaml");
   Check
     (Method ("sample.yml", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .yml");
   Check
     (Method ("sample.toml", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .toml");
   Check
     (Method ("sample.ini", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .ini");
   Check
     (Method ("sample.csv", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .csv");
   Check
     (Method ("sample.adb", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .adb");
   Check
     (Method ("sample.ads", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .ads");
   Check
     (Method ("sample.c", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .c");
   Check
     (Method ("sample.h", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .h");
   Check
     (Method ("sample.cpp", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .cpp");
   Check
     (Method ("sample.hpp", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .hpp");
   Check
     (Method ("sample.rs", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .rs");
   Check
     (Method ("sample.py", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .py");
   Check
     (Method ("sample.js", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .js");
   Check
     (Method ("sample.ts", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .ts");
   Check
     (Method ("sample.html", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .html");
   Check
     (Method ("sample.css", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .css");
   Check
     (Method ("sample.svg", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .svg");
   Check
     (Method ("sample.log", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates .log");

   Check
     (Method ("Makefile", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates files without extension by documented default");
   Check
     (Method ("data.unknown", Backup.CLI.Compression_Auto)
      = Backup.Zip.Deflated,
      "auto deflates unknown extension by documented default");

   Append_Entry (Entries, "a.txt");
   Append_Entry (Entries, "b.png");
   Backup.Compression.Apply (Backup.CLI.Compression_Auto, Entries);
   Check
     (Entries.Element (1).Compression_Method = Backup.Zip.Deflated,
      "apply preserves deflated method in entry metadata");
   Check
     (Entries.Element (2).Compression_Method = Backup.Zip.Stored,
      "apply preserves stored method in entry metadata");

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup compression tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup compression test(s) failed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Compression_Tests;
