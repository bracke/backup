with Backup.Catalog;
with Interfaces;

package Backup.Catalog_Syntax
  with SPARK_Mode => On
is
   function Verification_Name
     (State : Backup.Catalog.Verification_State) return String;

   function Encryption_Name
     (State : Backup.Catalog.Encryption_State) return String;

   function Kind_Name (Kind : Backup.Catalog.Entry_Kind) return String;

   function Status_Text (Status : Backup.Catalog.Catalog_Status) return String;

   type Verification_Parse is record
      Valid : Boolean := False;
      State : Backup.Catalog.Verification_State := Backup.Catalog.Verification_Unknown;
   end record;

   type Encryption_Parse is record
      Valid : Boolean := False;
      State : Backup.Catalog.Encryption_State := Backup.Catalog.Encryption_Not_Encrypted;
   end record;

   type Kind_Parse is record
      Valid : Boolean := False;
      Kind  : Backup.Catalog.Entry_Kind := Backup.Catalog.Entry_File;
   end record;

   type U64_Parse is record
      Valid : Boolean := False;
      Value : Interfaces.Unsigned_64 := 0;
   end record;

   type U32_Parse is record
      Valid : Boolean := False;
      Value : Interfaces.Unsigned_32 := 0;
   end record;

   type U16_Parse is record
      Valid : Boolean := False;
      Value : Interfaces.Unsigned_16 := 0;
   end record;

   function Parse_Verification (Text : String) return Verification_Parse;

   function Parse_Encryption (Text : String) return Encryption_Parse;

   function Parse_Kind (Text : String) return Kind_Parse;

   function Boolean_Text (Value : Boolean) return String;

   function Is_Boolean_Text (Text : String) return Boolean;

   function Is_Flexible_Boolean_Text (Text : String) return Boolean;

   function Is_Manifest_Query_Text (Text : String) return Boolean;

   function Is_Encryption_Query_Text (Text : String) return Boolean;

   function Is_Method_Query_Text (Text : String) return Boolean;

   function Parse_U64_Text (Text : String) return U64_Parse;

   function Parse_U32_Text (Text : String) return U32_Parse;

   function Parse_U16_Text (Text : String) return U16_Parse;
end Backup.Catalog_Syntax;
