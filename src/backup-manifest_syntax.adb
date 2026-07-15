package body Backup.Manifest_Syntax
  with SPARK_Mode => On
is
   function Method_Name
     (Method : Backup.Zip.Compression_Method) return String
   is
   begin
      case Method is
         when Backup.Zip.Stored =>
            return "stored";
         when Backup.Zip.Deflated =>
            return "deflated";
         when Backup.Zip.BZip2 =>
            return "bzip2";
         when Backup.Zip.LZMA =>
            return "lzma";
         when Backup.Zip.Zstd =>
            return "zstd";
      end case;
   end Method_Name;

   function Build_Result_Text
     (Result : Backup.Manifest.Build_Result) return String
   is
   begin
      case Result is
         when Backup.Manifest.Build_Ok =>
            return "ok";
         when Backup.Manifest.Build_Unreadable_Source =>
            return "manifest source metadata could not be read";
         when Backup.Manifest.Build_Size_Changed =>
            return "manifest source size changed during metadata capture";
         when Backup.Manifest.Build_Size_Limit =>
            return "manifest source metadata exceeds configured size limit";
      end case;
   end Build_Result_Text;

   function Kind_Name
     (Kind : Backup.Scanner.Entry_Kind) return String
   is
   begin
      case Kind is
         when Backup.Scanner.Entry_File =>
            return "file";
         when Backup.Scanner.Entry_Symlink =>
            return "symlink";
      end case;
   end Kind_Name;
end Backup.Manifest_Syntax;
