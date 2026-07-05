package body Backup.Path_Syntax
  with SPARK_Mode => On
is
   function Is_Slash (Ch : Character) return Boolean is
   begin
      return Ch = '/' or else Ch = '\';
   end Is_Slash;

   function Is_Control (Ch : Character) return Boolean is
   begin
      return Character'Pos (Ch) < 32 or else Character'Pos (Ch) = 127;
   end Is_Control;

   function Clean_Separator (Ch : Character) return Character is
   begin
      if Ch = '\' then
         return '/';
      end if;
      return Ch;
   end Clean_Separator;

   function Is_Windows_Absolute (Path : String) return Boolean is
   begin
      if Path'Length < 3 then
         return False;
      end if;

      return Path (Path'First) in 'A' .. 'Z' | 'a' .. 'z'
        and then Path (Path'First + 1) = ':'
        and then Is_Slash (Path (Path'First + 2));
   end Is_Windows_Absolute;

   function Is_Absolute (Path : String) return Boolean is
   begin
      if Path'Length = 0 then
         return False;
      end if;

      return Is_Slash (Path (Path'First)) or else Is_Windows_Absolute (Path);
   end Is_Absolute;

   function Has_Path_Separator (Text : String) return Boolean is
   begin
      for Ch of Text loop
         if Is_Slash (Ch) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Path_Separator;

   function Has_Control_Character (Text : String) return Boolean is
   begin
      for Ch of Text loop
         if Is_Control (Ch) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Control_Character;

   function Is_Dot_Or_Dot_Dot (Text : String) return Boolean is
   begin
      return Text = "." or else Text = "..";
   end Is_Dot_Or_Dot_Dot;

   function Ends_With
     (Value  : String;
      Suffix : String) return Boolean
   is
   begin
      if Suffix'Length = 0 then
         return True;
      elsif Suffix'Length > Value'Length then
         return False;
      end if;

      return Value (Value'Last - Suffix'Length + 1 .. Value'Last) = Suffix;
   end Ends_With;

   function Safe_Object_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0 then
         return False;
      end if;

      if Is_Dot_Or_Dot_Dot (Name) then
         return False;
      end if;

      for Ch of Name loop
         if Is_Slash (Ch) or else Is_Control (Ch) then
            return False;
         end if;
      end loop;

      return True;
   end Safe_Object_Name;

   function Looks_Like_Object (Name : String) return Boolean is
   begin
      return Ends_With (Name, ".zip")
        or else Ends_With (Name, ".backupenc")
        or else Ends_With (Name, ".enc")
        or else Ends_With (Name, ".zip.enc");
   end Looks_Like_Object;

   function Looks_Like_Managed_Object (Name : String) return Boolean is
      Partial_Suffix : constant String := ".partial";
   begin
      if Looks_Like_Object (Name) then
         return True;
      end if;

      if Name'Length > Partial_Suffix'Length
        and then Ends_With (Name, Partial_Suffix)
      then
         declare
            Base_Name : constant String :=
              Name (Name'First .. Name'Last - Partial_Suffix'Length);
         begin
            return Looks_Like_Object (Base_Name);
         end;
      end if;

      return False;
   end Looks_Like_Managed_Object;
end Backup.Path_Syntax;
