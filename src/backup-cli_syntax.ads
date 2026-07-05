with Interfaces;

package Backup.CLI_Syntax
  with SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   function Is_Digit (Ch : Character) return Boolean is (Ch in '0' .. '9');

   function Digit_Value (Ch : Character) return Interfaces.Unsigned_64
     with Pre => Is_Digit (Ch),
          Post => Digit_Value'Result <= 9;

   function Can_Accumulate_Decimal
     (Current : Interfaces.Unsigned_64;
      Ch      : Character) return Boolean;

   function Accumulate_Decimal
     (Current : Interfaces.Unsigned_64;
      Ch      : Character) return Interfaces.Unsigned_64
     with Pre => Is_Digit (Ch)
       and then Current <=
         (Interfaces.Unsigned_64'Last - Digit_Value (Ch)) / 10;

   function Flag_Count
     (First  : Boolean;
      Second : Boolean;
      Third  : Boolean;
      Fourth : Boolean;
      Fifth  : Boolean) return Natural
     with Post => Flag_Count'Result <= 5;

   function Any_Catalog_Command
     (Index_Command  : Boolean;
      Query_Command  : Boolean;
      List_Archives  : Boolean;
      List_Contents  : Boolean;
      Verify_Catalog : Boolean) return Boolean;

   function Exactly_One_Catalog_Command
     (Index_Command  : Boolean;
      Query_Command  : Boolean;
      List_Archives  : Boolean;
      List_Contents  : Boolean;
      Verify_Catalog : Boolean) return Boolean;

   function Remote_Operation_Selected
     (Upload  : Boolean;
      Sync    : Boolean;
      Restore : Boolean) return Boolean;

   function Remote_Upload_Or_Sync
     (Upload : Boolean;
      Sync   : Boolean) return Boolean;

   function Remote_Direction_Conflict
     (Upload  : Boolean;
      Sync    : Boolean;
      Restore : Boolean) return Boolean;

   function Job_Command_Selected
     (Run_Job    : Boolean;
      Create_Job : Boolean) return Boolean;

   function Job_Command_Conflict
     (Run_Job    : Boolean;
      Create_Job : Boolean) return Boolean;

   function Positional_Paths_Disallowed
     (Catalog_Command : Boolean;
      Job_Command     : Boolean;
      List_Command    : Boolean;
      Extract_Command : Boolean) return Boolean;

   function Restore_Conflict_Can_Be_Set
     (Already_Set : Boolean) return Boolean;
end Backup.CLI_Syntax;
