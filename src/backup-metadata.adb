with Zlib;

package body Backup.Metadata is
   use Interfaces;
   use type Backup.Zip.Compression_Method;
   use type Zlib.Status_Code;

   function Estimate_Compressed_Size_For_Direct_Metadata
     (Method            : Backup.Zip.Compression_Method;
      Path              : Backup.Paths.File_System_Path;
      Uncompressed_Size : Unsigned_64;
      Compressed_Size   : out Unsigned_64)
      return Boolean
   is
      Status : Zlib.Status_Code := Zlib.Ok;
   begin
      if Method = Backup.Zip.Stored then
         Compressed_Size := Uncompressed_Size;
         return True;
      end if;

      Zlib.Deflate_Raw_File_Size
        (Input_Path      => Backup.Paths.To_String (Path),
         Mode            => Zlib.Auto,
         Compressed_Size => Compressed_Size,
         Status          => Status);
      return Status = Zlib.Ok;
   end Estimate_Compressed_Size_For_Direct_Metadata;
end Backup.Metadata;
