package body Backup.Restore_Syntax
  with SPARK_Mode => On
is
   function Status_Text (Status : Backup.Restore.Restore_Status) return String is
   begin
      case Status is
         when Backup.Restore.Restore_Ok =>
            return "ok";
         when Backup.Restore.Restore_Verify_Failed =>
            return "archive verification failed";
         when Backup.Restore.Restore_Target_Error =>
            return "target directory error";
         when Backup.Restore.Restore_Existing_Path =>
            return "destination path already exists";
         when Backup.Restore.Restore_Unsafe_Symlink =>
            return "unsafe symlink target";
         when Backup.Restore.Restore_Unsupported_Symlink =>
            return "symlink restoration is unsupported";
         when Backup.Restore.Restore_Read_Error =>
            return "archive read error";
         when Backup.Restore.Restore_Write_Error =>
            return "destination write error";
         when Backup.Restore.Restore_Deflate_Invalid =>
            return "deflate payload extraction failed";
         when Backup.Restore.Restore_Crc_Mismatch =>
            return "restored payload CRC32 mismatch";
         when Backup.Restore.Restore_Internal_Error =>
            return "internal restore error";
      end case;
   end Status_Text;

   function Action_Name (Action : Backup.Restore.Restore_Action) return String is
   begin
      case Action is
         when Backup.Restore.Action_Restore =>
            return "restored";
         when Backup.Restore.Action_Skip =>
            return "skipped";
         when Backup.Restore.Action_Reject =>
            return "rejected";
         when Backup.Restore.Action_Would_Restore =>
            return "would-restore";
         when Backup.Restore.Action_Would_Skip =>
            return "would-skip";
         when Backup.Restore.Action_Would_Reject =>
            return "would-reject";
      end case;
   end Action_Name;

   function Report_Action
     (Action  : Backup.Restore.Restore_Action;
      Dry_Run : Boolean) return Backup.Restore.Restore_Action
   is
   begin
      if not Dry_Run then
         return Action;
      end if;

      case Action is
         when Backup.Restore.Action_Restore | Backup.Restore.Action_Would_Restore =>
            return Backup.Restore.Action_Would_Restore;
         when Backup.Restore.Action_Skip | Backup.Restore.Action_Would_Skip =>
            return Backup.Restore.Action_Would_Skip;
         when Backup.Restore.Action_Reject | Backup.Restore.Action_Would_Reject =>
            return Backup.Restore.Action_Would_Reject;
      end case;
   end Report_Action;

   function Prefix_Matches
     (Text   : String;
      Prefix : String) return Boolean
   is
   begin
      if Prefix'Length > Text'Length then
         return False;
      end if;

      for Offset in 0 .. Prefix'Length - 1 loop
         if Text (Text'First + Offset) /= Prefix (Prefix'First + Offset) then
            return False;
         end if;
      end loop;

      return True;
   end Prefix_Matches;

   function Path_Matches_Filter
     (Filter       : String;
      Archive_Path : String) return Boolean
   is
   begin
      if Filter'Length = 0 then
         return False;
      end if;

      if Archive_Path = Filter then
         return True;
      end if;

      if Filter (Filter'Last) = '/' then
         return Archive_Path'Length > Filter'Length
           and then Prefix_Matches (Archive_Path, Filter);
      end if;

      return Archive_Path'Length > Filter'Length
        and then Prefix_Matches (Archive_Path, Filter)
        and then Archive_Path (Archive_Path'First + Filter'Length) = '/';
   end Path_Matches_Filter;

   type Segment_State is
     (Segment_Empty,
      Segment_One_Dot,
      Segment_Two_Dots,
      Segment_Other);

   function Next_Segment_State
     (State : Segment_State;
      Ch    : Character) return Segment_State
   is
   begin
      case State is
         when Segment_Empty =>
            if Ch = '.' then
               return Segment_One_Dot;
            else
               return Segment_Other;
            end if;
         when Segment_One_Dot =>
            if Ch = '.' then
               return Segment_Two_Dots;
            else
               return Segment_Other;
            end if;
         when Segment_Two_Dots | Segment_Other =>
            return Segment_Other;
      end case;
   end Next_Segment_State;

   function Symlink_Target_Is_Safe (Target : String) return Boolean is
      Segment : Segment_State := Segment_Empty;
   begin
      if Target'Length = 0 then
         return False;
      end if;

      if Target (Target'First) = '/'
        or else Target (Target'First) = '\'
      then
         return False;
      end if;

      for Ch of Target loop
         if Ch = '\' then
            return False;
         elsif Ch = '/' then
            if Segment = Segment_Empty or else Segment = Segment_Two_Dots then
               return False;
            end if;
            Segment := Segment_Empty;
         else
            Segment := Next_Segment_State (Segment, Ch);
         end if;
      end loop;

      return Segment /= Segment_Empty and then Segment /= Segment_Two_Dots;
   end Symlink_Target_Is_Safe;

end Backup.Restore_Syntax;
