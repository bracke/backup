package body Backup.Zip_Syntax
  with SPARK_Mode => On
is
   Base_Allowed : constant Interfaces.Unsigned_16 := 16#080B#;
   Deflate_Only : constant Interfaces.Unsigned_16 := 16#0004#;

   function Is_Supported_Zip_Version
     (Version : Interfaces.Unsigned_16) return Boolean
   is
   begin
      --  Only the low byte is the version number (spec x 10 -- 20 for deflate, 45 for ZIP64,
      --  46 for bzip2). The high byte is a host/attribute field that some writers leave zero
      --  and others -- 7-Zip on macOS among them -- fill in, which pushed the whole 16-bit
      --  value past 63 and made a perfectly readable archive look like an unsupported one.
      --  Standard readers judge the version by its low byte; so does this now.
      return (Version and 16#00FF#) <= 63;
   end Is_Supported_Zip_Version;

   function Is_Supported_General_Flags
     (Flags  : Interfaces.Unsigned_16;
      Method : Interfaces.Unsigned_16) return Boolean
   is
   begin
      return (Flags and not (Base_Allowed or Deflate_Only)) = 0
        and then ((Flags and Deflate_Only) = 0
                  or else Method = Deflate_Method);
   end Is_Supported_General_Flags;

   function Has_Deflate_Option_Flag
     (Flags : Interfaces.Unsigned_16) return Boolean
   is
   begin
      return (Flags and Deflate_Only) /= 0;
   end Has_Deflate_Option_Flag;
end Backup.Zip_Syntax;
