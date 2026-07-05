package body Backup.CLI_Syntax
  with SPARK_Mode => On
is
   function Digit_Value (Ch : Character) return Interfaces.Unsigned_64 is
   begin
      case Ch is
         when '0' => return 0;
         when '1' => return 1;
         when '2' => return 2;
         when '3' => return 3;
         when '4' => return 4;
         when '5' => return 5;
         when '6' => return 6;
         when '7' => return 7;
         when '8' => return 8;
         when others => return 9;
      end case;
   end Digit_Value;

   function Can_Accumulate_Decimal
     (Current : Interfaces.Unsigned_64;
      Ch      : Character) return Boolean
   is
   begin
      return Is_Digit (Ch)
        and then Current <=
          (Interfaces.Unsigned_64'Last - Digit_Value (Ch)) / 10;
   end Can_Accumulate_Decimal;

   function Accumulate_Decimal
     (Current : Interfaces.Unsigned_64;
      Ch      : Character) return Interfaces.Unsigned_64
   is
   begin
      return Current * 10 + Digit_Value (Ch);
   end Accumulate_Decimal;


   function Flag_Count
     (First  : Boolean;
      Second : Boolean;
      Third  : Boolean;
      Fourth : Boolean;
      Fifth  : Boolean) return Natural
   is
      Result : Natural := 0;
   begin
      if First then
         Result := Result + 1;
      end if;
      if Second then
         Result := Result + 1;
      end if;
      if Third then
         Result := Result + 1;
      end if;
      if Fourth then
         Result := Result + 1;
      end if;
      if Fifth then
         Result := Result + 1;
      end if;
      return Result;
   end Flag_Count;

   function Any_Catalog_Command
     (Index_Command  : Boolean;
      Query_Command  : Boolean;
      List_Archives  : Boolean;
      List_Contents  : Boolean;
      Verify_Catalog : Boolean) return Boolean
   is
   begin
      return Index_Command
        or else Query_Command
        or else List_Archives
        or else List_Contents
        or else Verify_Catalog;
   end Any_Catalog_Command;

   function Exactly_One_Catalog_Command
     (Index_Command  : Boolean;
      Query_Command  : Boolean;
      List_Archives  : Boolean;
      List_Contents  : Boolean;
      Verify_Catalog : Boolean) return Boolean
   is
   begin
      return Flag_Count
        (Index_Command, Query_Command, List_Archives, List_Contents,
         Verify_Catalog) = 1;
   end Exactly_One_Catalog_Command;

   function Remote_Operation_Selected
     (Upload  : Boolean;
      Sync    : Boolean;
      Restore : Boolean) return Boolean
   is
   begin
      return Upload or else Sync or else Restore;
   end Remote_Operation_Selected;

   function Remote_Upload_Or_Sync
     (Upload : Boolean;
      Sync   : Boolean) return Boolean
   is
   begin
      return Upload or else Sync;
   end Remote_Upload_Or_Sync;

   function Remote_Direction_Conflict
     (Upload  : Boolean;
      Sync    : Boolean;
      Restore : Boolean) return Boolean
   is
   begin
      return Restore and then (Upload or else Sync);
   end Remote_Direction_Conflict;

   function Job_Command_Selected
     (Run_Job    : Boolean;
      Create_Job : Boolean) return Boolean
   is
   begin
      return Run_Job or else Create_Job;
   end Job_Command_Selected;

   function Job_Command_Conflict
     (Run_Job    : Boolean;
      Create_Job : Boolean) return Boolean
   is
   begin
      return Run_Job and then Create_Job;
   end Job_Command_Conflict;

   function Positional_Paths_Disallowed
     (Catalog_Command : Boolean;
      Job_Command     : Boolean;
      List_Command    : Boolean;
      Extract_Command : Boolean) return Boolean
   is
   begin
      return Catalog_Command
        or else Job_Command
        or else List_Command
        or else Extract_Command;
   end Positional_Paths_Disallowed;

   function Restore_Conflict_Can_Be_Set
     (Already_Set : Boolean) return Boolean
   is
   begin
      return not Already_Set;
   end Restore_Conflict_Can_Be_Set;
end Backup.CLI_Syntax;
