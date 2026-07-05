with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

with Backup.Paths;

package Backup.Zip is
   type Compression_Method is
     (Stored,
      Deflated,
      BZip2,
      LZMA,
      PPMd,
      Zstd);

   type Write_Result is
     (Write_Ok,
      Write_Unsupported_Entry,
      Write_Unreadable_Source,
      Write_Invalid_Archive_Path,
      Write_Duplicate_Archive_Path,
      Write_Output_Error,
      Write_Compression_Failed,
      Write_Size_Overflow,
      Write_Archive_Name_Too_Long);

   type Source_Kind is
     (Source_File,
      Source_Symlink,
      Source_Generated);

   type Source_Entry is record
      Source_Path  : Backup.Paths.File_System_Path;
      Archive_Path : Backup.Paths.Archive_Path;
      Byte_Size    : Interfaces.Unsigned_64 := 0;
      Method       : Compression_Method := Stored;
      Kind         : Source_Kind := Source_File;
      Generated    : Boolean := False;
      Has_Prepared_Payload  : Boolean := False;
      Prepared_Payload_Path : Ada.Strings.Unbounded.Unbounded_String;
      Prepared_Compressed_Size : Interfaces.Unsigned_64 := 0;
      Content      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Method_Number
     (Method : Compression_Method) return Interfaces.Unsigned_16;
   --  Return the ZIP compression method id for a backup compression method.

   package Source_Entry_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Source_Entry);

   function Analyze_File
     (Path : Backup.Paths.File_System_Path;
      Crc  : out Interfaces.Unsigned_32;
      Size : out Interfaces.Unsigned_64)
      return Write_Result;

   function Crc32_Of_File
     (Path : Backup.Paths.File_System_Path)
      return Interfaces.Unsigned_32;

   function Crc32_Of_Text
     (Text : Ada.Strings.Unbounded.Unbounded_String)
      return Interfaces.Unsigned_32;

   function Create_Archive
     (Output_Path : String;
      Entries     : Source_Entry_Vectors.Vector)
      return Write_Result;

   function Create_Archive
     (Output_Path : String)
      return Write_Result;
end Backup.Zip;
