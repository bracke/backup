with CryptoLib.Checksums;

package body Backup.Checksums is

   function CRC32
     (Data : Ada.Streams.Stream_Element_Array)
      return Interfaces.Unsigned_32
   is
      State : CryptoLib.Checksums.CRC32_State;
   begin
      CryptoLib.Checksums.CRC32_Reset (State);
      CryptoLib.Checksums.CRC32_Update (State, Data);
      return CryptoLib.Checksums.CRC32_Value (State);
   end CRC32;

   function CRC32 (Data : Zlib.Byte_Array) return Interfaces.Unsigned_32 is
      State : CryptoLib.Checksums.CRC32_State;
      Bytes : CryptoLib.Checksums.Byte_Array (Data'Range);
   begin
      for I in Data'Range loop
         Bytes (I) := CryptoLib.Checksums.Byte (Data (I));
      end loop;
      CryptoLib.Checksums.CRC32_Reset (State);
      CryptoLib.Checksums.CRC32_Update (State, Bytes);
      return CryptoLib.Checksums.CRC32_Value (State);
   end CRC32;

end Backup.Checksums;
