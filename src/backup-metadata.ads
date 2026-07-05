with Interfaces;

with Backup.Paths;
with Backup.Zip;

package Backup.Metadata is
   function Estimate_Compressed_Size_For_Direct_Metadata
     (Method            : Backup.Zip.Compression_Method;
      Path              : Backup.Paths.File_System_Path;
      Uncompressed_Size : Interfaces.Unsigned_64;
      Compressed_Size   : out Interfaces.Unsigned_64)
      return Boolean;
end Backup.Metadata;
