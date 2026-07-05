with Interfaces;

package Backup.Zip_Syntax
  with SPARK_Mode => On
is
   use type Interfaces.Unsigned_16;

   Deflate_Method : constant Interfaces.Unsigned_16 := 8;

   function Is_Supported_Zip_Version
     (Version : Interfaces.Unsigned_16) return Boolean
     with Post => Is_Supported_Zip_Version'Result = (Version <= 63);

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
