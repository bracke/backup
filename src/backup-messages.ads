package Backup.Messages is
   procedure Set_Locale (Locale_Name : String);
   procedure Detect_System_Locale;
   function Current_Locale return String;
   function Text (Key : String) return String;
   function Text
     (Key       : String;
      Arg_Key   : String;
      Arg_Value : String) return String;
end Backup.Messages;
