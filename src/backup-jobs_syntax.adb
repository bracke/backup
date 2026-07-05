package body Backup.Jobs_Syntax
  with SPARK_Mode => On
is
   function Starts_With
     (Value  : String;
      Prefix : String) return Boolean
   is
   begin
      if Prefix'Length = 0 then
         return True;
      elsif Value'Length < Prefix'Length then
         return False;
      end if;

      declare
         End_Index : constant Integer :=
           Value'Last - (Value'Length - Prefix'Length);
      begin
         return Value (Value'First .. End_Index) = Prefix;
      end;
   end Starts_With;

   function Repeated_Key_Allowed (Key : String) return Boolean is
   begin
      return Key = "source"
        or else Key = "input"
        or else Key = "ignore";
   end Repeated_Key_Allowed;

   function Status_Text (Status : Backup.Jobs.Job_Status) return String is
   begin
      case Status is
         when Backup.Jobs.Job_Ok =>
            return "job completed";
         when Backup.Jobs.Job_Open_Failed =>
            return "could not open job configuration";
         when Backup.Jobs.Job_Read_Failed =>
            return "could not read job configuration";
         when Backup.Jobs.Job_Write_Failed =>
            return "could not write job configuration";
         when Backup.Jobs.Job_Malformed =>
            return "malformed job configuration";
         when Backup.Jobs.Job_Unsupported_Value =>
            return "unsupported job configuration value";
         when Backup.Jobs.Job_Missing_Required_Field =>
            return "job configuration is missing a required field";
         when Backup.Jobs.Job_Backup_Failed =>
            return "scheduled backup failed";
         when Backup.Jobs.Job_Verification_Failed =>
            return "scheduled post-backup verification failed";
         when Backup.Jobs.Job_Retention_Failed =>
            return "scheduled retention cleanup failed";
         when Backup.Jobs.Job_Interrupted =>
            return "scheduled job was interrupted";
      end case;
   end Status_Text;

   function Is_Boolean_Text (Value : String) return Boolean is
   begin
      return Value = "true" or else Value = "false";
   end Is_Boolean_Text;

   function Parse_Natural_Text (Value : String) return Natural_Parse
   is
      Accumulated : Natural := 0;
      Digit       : Natural;
   begin
      if Value'Length = 0 then
         return (Valid => False, Value => 0);
      end if;

      for Ch of Value loop
         if Ch not in '0' .. '9' then
            return (Valid => False, Value => 0);
         end if;

         Digit := Character'Pos (Ch) - Character'Pos ('0');
         if Accumulated > (Natural'Last - Digit) / 10 then
            return (Valid => False, Value => 0);
         end if;

         Accumulated := Accumulated * 10 + Digit;
      end loop;

      return (Valid => True, Value => Accumulated);
   end Parse_Natural_Text;

   function First_Colon (Value : String) return Natural is
   begin
      for Index in Value'Range loop
         if Value (Index) = ':' then
            return Index;
         end if;
      end loop;

      return 0;
   end First_Colon;

   function Valid_Schedule_Metadata (Value : String) return Boolean is
      Hour   : Natural_Parse;
      Minute : Natural_Parse;
      Sep    : Natural;
      Interval_Prefix : constant String := "interval-hours:";
      Daily_Prefix    : constant String := "daily-at:";
   begin
      if Value'Length = 0
        or else Value = "external"
        or else Value = "manual"
        or else Value = "disabled"
      then
         return True;
      end if;

      if Starts_With (Value, Interval_Prefix) then
         if Value'Length <= Interval_Prefix'Length then
            return False;
         end if;

         declare
            Hour_First : constant Integer :=
              Value'Last - (Value'Length - Interval_Prefix'Length) + 1;
         begin
            Hour := Parse_Natural_Text
              (Value (Hour_First .. Value'Last));
            return Hour.Valid and then Hour.Value > 0;
         end;
      elsif Starts_With (Value, Daily_Prefix) then
         if Value'Length <= Daily_Prefix'Length then
            return False;
         end if;

         declare
            Time_First : constant Positive := Value'First + Daily_Prefix'Length;
         begin
            Sep := First_Colon (Value (Time_First .. Value'Last));
            if Sep = 0 or else Sep = Time_First or else Sep = Value'Last then
               return False;
            end if;

            Hour := Parse_Natural_Text (Value (Time_First .. Sep - 1));
            Minute := Parse_Natural_Text (Value (Sep + 1 .. Value'Last));
            return Hour.Valid
              and then Minute.Valid
              and then Hour.Value <= 23
              and then Minute.Value <= 59;
         end;
      end if;

      return False;
   end Valid_Schedule_Metadata;
end Backup.Jobs_Syntax;
