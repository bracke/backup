with Backup.CLI;
with Backup.Paths;
with Backup.Scanner;
with Backup.Zip;

package Backup.Compression is
   --  ZIP compression methods selected by policy use the ZIP standard
   --  method numbers represented in Backup.Zip: Stored = method 0,
   --  Deflated = method 8, BZip2 = method 12, LZMA = method 14,
   --  and Zstd = method 93. ZIP PPMd (method 98) is not supported: it is PPMd
   --  var.I, which zlib does not implement (its PPMd is var.H, for 7z
   --  containers). Unknown extensions intentionally default to Deflated in auto
   --  mode until a later sampling phase proves otherwise.

   function Method_For_Archive_Path
     (Archive_Path : String;
      Mode         : Backup.CLI.Compression_Mode)
      return Backup.Zip.Compression_Method;

   function Method_For_Archive_Path
     (Archive_Path : Backup.Paths.Archive_Path;
      Mode         : Backup.CLI.Compression_Mode)
      return Backup.Zip.Compression_Method;

   procedure Apply
     (Mode    : Backup.CLI.Compression_Mode;
      Entries : in out Backup.Scanner.Entry_Vectors.Vector);
end Backup.Compression;
