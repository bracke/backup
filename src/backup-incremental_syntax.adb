package body Backup.Incremental_Syntax
  with SPARK_Mode => On
is
   use type Interfaces.Unsigned_16;
   function Status_Text
     (Status : Backup.Incremental.Plan_Status) return String
   is
   begin
      case Status is
         when Backup.Incremental.Plan_Ok =>
            return "ok";
         when Backup.Incremental.Plan_Previous_Open_Failed =>
            return "previous incremental source could not be opened";
         when Backup.Incremental.Plan_Previous_Verify_Failed =>
            return "previous archive verification failed";
         when Backup.Incremental.Plan_Invalid_Manifest =>
            return "previous manifest is invalid or unsupported";
         when Backup.Incremental.Plan_Invalid_Archive_Path =>
            return "previous manifest contains an invalid archive path";
         when Backup.Incremental.Plan_Duplicate_Archive_Path =>
            return "incremental metadata contains a duplicate archive path";
         when Backup.Incremental.Plan_Unreadable_Source =>
            return "current source metadata could not be read";
         when Backup.Incremental.Plan_Unsupported_Method =>
            return "previous incremental source uses an unsupported method";
         when Backup.Incremental.Plan_Conflicting_Metadata =>
            return "previous incremental metadata is internally inconsistent";
      end case;
   end Status_Text;

   function Decision_Name
     (Decision : Backup.Incremental.Decision_Kind) return String
   is
   begin
      case Decision is
         when Backup.Incremental.Decision_Added =>
            return "added";
         when Backup.Incremental.Decision_Modified =>
            return "modified";
         when Backup.Incremental.Decision_Removed =>
            return "removed";
         when Backup.Incremental.Decision_Reused =>
            return "reused";
         when Backup.Incremental.Decision_Skipped =>
            return "skipped";
      end case;
   end Decision_Name;

   function Kind_Name
     (Kind : Backup.Incremental.Plan_Entry_Kind) return String
   is
   begin
      case Kind is
         when Backup.Incremental.Plan_File =>
            return "file";
         when Backup.Incremental.Plan_Directory =>
            return "directory";
         when Backup.Incremental.Plan_Symlink =>
            return "symlink";
         when Backup.Incremental.Plan_Manifest =>
            return "manifest";
      end case;
   end Kind_Name;

   function Method_Name (Method : Interfaces.Unsigned_16) return String is
   begin
      if Method = 0 then
         return "stored";
      elsif Method = 8 then
         return "deflated";
      elsif Method = 12 then
         return "bzip2";
      elsif Method = 14 then
         return "lzma";
      elsif Method = 20 or else Method = 93 then
         return "zstd";
      elsif Method = 98 then
         return "ppmd";
      else
         declare
            Image : constant String := Interfaces.Unsigned_16'Image (Method);
         begin
            return "method-" & Image (Image'First + 1 .. Image'Last);
         end;
      end if;
   end Method_Name;
end Backup.Incremental_Syntax;
