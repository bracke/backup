with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;

with I18N.Arguments;
with I18N.Result;
with I18N.Runtime;

package body Backup.Messages is
   use Ada.Strings.Unbounded;

   Runtime : I18N.Runtime.Instance;
   Locale  : Unbounded_String := To_Unbounded_String ("en");

   function Catalog_Path return String is
   begin
      if Ada.Directories.Exists ("share/backup/messages.catalog") then
         return "share/backup/messages.catalog";
      elsif Ada.Directories.Exists ("../share/backup/messages.catalog") then
         return "../share/backup/messages.catalog";
      elsif Ada.Directories.Exists ("messages.catalog") then
         return "messages.catalog";
      else
         return "share/backup/messages.catalog";
      end if;
   end Catalog_Path;

   function Normalize_Locale (Item : String) return String is
      use Ada.Characters.Handling;

      Value     : Unbounded_String;
      Result    : Unbounded_String;
      Separator : Boolean := True;
   begin
      for Ch of Item loop
         exit when Ch = '.' or else Ch = '@';

         if Ch = '_' then
            Append (Value, '-');
         elsif Ch /= ' ' and then Ch /= Character'Val (9) then
            Append (Value, Ch);
         end if;
      end loop;

      if Length (Value) = 0 then
         return "en";
      end if;

      declare
         Raw : constant String := To_String (Value);
      begin
         if Raw = "C" or else Raw = "POSIX" then
            return "en";
         end if;

         for Ch of Raw loop
            if Ch = '-' then
               Append (Result, Ch);
               Separator := True;
            elsif Separator then
               Append (Result, To_Lower (Ch));
               Separator := False;
            else
               Append (Result, To_Lower (Ch));
            end if;
         end loop;
      end;

      if Length (Result) = 0 then
         return "en";
      else
         return To_String (Result);
      end if;
   end Normalize_Locale;

   function Environment_Locale (Name : String) return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         declare
            Value : constant String := Ada.Environment_Variables.Value (Name);
         begin
            if Value /= "" then
               return Value;
            end if;
         end;
      end if;

      return "";
   end Environment_Locale;

   procedure Set_Locale (Locale_Name : String) is
   begin
      Locale := To_Unbounded_String (Normalize_Locale (Locale_Name));
   end Set_Locale;

   procedure Detect_System_Locale is
      Value : Unbounded_String;
   begin
      Value := To_Unbounded_String (Environment_Locale ("LC_ALL"));

      if Length (Value) = 0 then
         Value := To_Unbounded_String (Environment_Locale ("LC_MESSAGES"));
      end if;

      if Length (Value) = 0 then
         Value := To_Unbounded_String (Environment_Locale ("LANG"));
      end if;

      Set_Locale (To_String (Value));
   end Detect_System_Locale;

   function Current_Locale return String is
   begin
      return To_String (Locale);
   end Current_Locale;

   function Render_Once
     (Locale_Name : String;
      Key         : String;
      Args        : I18N.Arguments.Arguments;
      Text        : out Unbounded_String) return Boolean
   is
      use type I18N.Result.Render_Status;

      Result : constant I18N.Result.Render_Result :=
        I18N.Runtime.Render
          (Item      => Runtime,
           Locale    => Locale_Name,
           Key       => Key,
           Arguments => Args);
   begin
      if Result.Status = I18N.Result.Success then
         Text := To_Unbounded_String (I18N.Result.Output_Text (Result.Text));
         return True;
      else
         Text := Null_Unbounded_String;
         return False;
      end if;
   end Render_Once;

   function Parent_Locale (Locale_Name : String) return String is
   begin
      for Index_Value in reverse Locale_Name'Range loop
         if Locale_Name (Index_Value) = '-' then
            if Index_Value = Locale_Name'First then
               return "";
            else
               return Locale_Name (Locale_Name'First .. Index_Value - 1);
            end if;
         end if;
      end loop;

      return "";
   end Parent_Locale;

   function Render (Key : String; Args : I18N.Arguments.Arguments)
      return String
   is
      Locale_Name : Unbounded_String := Locale;
      Output      : Unbounded_String;
   begin
      while Length (Locale_Name) > 0 loop
         if Render_Once (To_String (Locale_Name), Key, Args, Output) then
            return To_String (Output);
         end if;

         Locale_Name :=
           To_Unbounded_String (Parent_Locale (To_String (Locale_Name)));
      end loop;

      if Render_Once ("en", Key, Args, Output) then
         return To_String (Output);
      end if;

      return Key;
   end Render;

   function Text (Key : String) return String is
      Args : I18N.Arguments.Arguments;
   begin
      return Render (Key, Args);
   end Text;

   function Text
     (Key       : String;
      Arg_Key   : String;
      Arg_Value : String) return String
   is
      Args : I18N.Arguments.Arguments;
   begin
      I18N.Arguments.Set (Args, Arg_Key, Arg_Value);
      return Render (Key, Args);
   end Text;

begin
   I18N.Runtime.Initialize (Runtime, Catalog_Path);
   Detect_System_Locale;
end Backup.Messages;
