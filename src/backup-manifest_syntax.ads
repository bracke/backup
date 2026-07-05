with Backup.Manifest;
with Backup.Scanner;
with Backup.Zip;

package Backup.Manifest_Syntax
  with SPARK_Mode => On
is
   function Method_Name
     (Method : Backup.Zip.Compression_Method) return String;

   function Build_Result_Text
     (Result : Backup.Manifest.Build_Result) return String;

   function Kind_Name
     (Kind : Backup.Scanner.Entry_Kind) return String;
end Backup.Manifest_Syntax;
