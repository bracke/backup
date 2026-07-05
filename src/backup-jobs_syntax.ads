with Backup.Jobs;

package Backup.Jobs_Syntax
  with SPARK_Mode => On
is
   function Starts_With
     (Value  : String;
      Prefix : String) return Boolean;

   function Repeated_Key_Allowed (Key : String) return Boolean;

   function Status_Text (Status : Backup.Jobs.Job_Status) return String;

   function Is_Boolean_Text (Value : String) return Boolean;

   type Natural_Parse is record
      Valid : Boolean := False;
      Value : Natural := 0;
   end record;

   function Parse_Natural_Text (Value : String) return Natural_Parse;

   function Valid_Schedule_Metadata (Value : String) return Boolean;
end Backup.Jobs_Syntax;
