package body Backup.Zip_Syntax
  with SPARK_Mode => On
is
   Base_Allowed : constant Interfaces.Unsigned_16 := 16#080B#;
   Deflate_Only : constant Interfaces.Unsigned_16 := 16#0004#;

   function Is_Supported_Zip_Version
     (Version : Interfaces.Unsigned_16) return Boolean
   is
   begin
      return Version <= 63;
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
