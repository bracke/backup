with Interfaces;

package Backup.Zip_Syntax
  with SPARK_Mode => On
is
   use type Interfaces.Unsigned_16;

   Deflate_Method : constant Interfaces.Unsigned_16 := 8;

   --  Only the low byte carries the version number (spec x 10); the high byte is a
   --  host/attribute field some writers -- 7-Zip on macOS among them -- fill in. Judge
   --  by the low byte, as standard readers do, so a set high byte does not reject a
   --  readable archive. The body and this contract must agree, or the postcondition
   --  fires on exactly those archives (an assertion seen on macOS but not Linux).
   function Is_Supported_Zip_Version
     (Version : Interfaces.Unsigned_16) return Boolean
     with Post =>
       Is_Supported_Zip_Version'Result = ((Version and 16#00FF#) <= 63);

   function Is_Supported_General_Flags
     (Flags  : Interfaces.Unsigned_16;
      Method : Interfaces.Unsigned_16) return Boolean
     with Post =>
       Is_Supported_General_Flags'Result =
         (((Flags and not Interfaces.Unsigned_16'(16#080F#)) = 0)
          and then
            (((Flags and Interfaces.Unsigned_16'(16#0004#)) = 0)
             or else Method = Deflate_Method));

   function Has_Deflate_Option_Flag
     (Flags : Interfaces.Unsigned_16) return Boolean
     with Post =>
       Has_Deflate_Option_Flag'Result =
         ((Flags and Interfaces.Unsigned_16'(16#0004#)) /= 0);
end Backup.Zip_Syntax;
