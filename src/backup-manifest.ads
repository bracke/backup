with Ada.Strings.Unbounded;

with Backup.Scanner;
with Backup.Zip;

package Backup.Manifest is
   Manifest_Path : constant String := ".backup/manifest.json";

   type Build_Result is
     (Build_Ok,
      Build_Unreadable_Source,
      Build_Size_Changed,
      Build_Size_Limit);

   function Method_Name
     (Method : Backup.Zip.Compression_Method)
      return String;

   function Build_Result_Text
     (Result : Build_Result)
      return String;

   function Build
     (Entries : Backup.Scanner.Entry_Vectors.Vector;
      Content : out Ada.Strings.Unbounded.Unbounded_String)
      return Build_Result;

   function Build
     (Entries : Backup.Scanner.Entry_Vectors.Vector)
      return Ada.Strings.Unbounded.Unbounded_String;
end Backup.Manifest;
