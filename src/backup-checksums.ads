with Ada.Streams;
with Interfaces;
with Zlib;

--  CRC-32 helpers over the byte representations backup passes around.
--
--  The CRC-32 implementation lives in CryptoLib.Checksums; zlib itself uses it
--  rather than exposing its own. These overloads keep the conversion between
--  Zlib.Byte_Array and CryptoLib's byte array in one place.
package Backup.Checksums is

   --  Compute the standard ZIP/gzip CRC-32 of Data.
   --  @param Data bytes to checksum
   --  @return finalized CRC-32 value
   function CRC32
     (Data : Ada.Streams.Stream_Element_Array)
      return Interfaces.Unsigned_32;

   --  Compute the standard ZIP/gzip CRC-32 of Data.
   --  @param Data bytes to checksum
   --  @return finalized CRC-32 value
   function CRC32 (Data : Zlib.Byte_Array) return Interfaces.Unsigned_32;

end Backup.Checksums;
