with Ada.Containers;
with Ada.Directories;
with Ada.Text_IO;

with Backup.Incremental_Syntax;
with Backup.Manifest;
with Backup.Metadata;
with Backup.Paths;
with Backup.Verify;
with Backup.Zip;

package body Backup.Incremental is
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Ada.Containers.Count_Type;
   use type Backup.Scanner.Entry_Kind;
   use type Backup.Scanner.Symlink_Action;
   use type Backup.Zip.Write_Result;
   use type Backup.Verify.Verify_Status;
   use type Backup.Verify.Entry_Kind;
   use type Backup.Paths.Validation_Status;
   use type Backup.Encryption.Envelope_Status;

   type Prior_Entry is record
      Archive_Path      : Unbounded_String;
      Kind              : Plan_Entry_Kind := Plan_File;
      Method            : Unsigned_16 := 0;
      Crc32             : Unsigned_32 := 0;
      Compressed_Size   : Unsigned_64 := 0;
      Uncompressed_Size : Unsigned_64 := 0;
      Link_Target       : Unbounded_String;
      Matched           : Boolean := False;
   end record;

   package Prior_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Prior_Entry);

   function Status_Text (Status : Plan_Status) return String is
   begin
      return Backup.Incremental_Syntax.Status_Text (Status);
   end Status_Text;

   function Decision_Name (Decision : Decision_Kind) return String is
   begin
      return Backup.Incremental_Syntax.Decision_Name (Decision);
   end Decision_Name;

   function Kind_Name (Kind : Plan_Entry_Kind) return String is
   begin
      return Backup.Incremental_Syntax.Kind_Name (Kind);
   end Kind_Name;

   function Method_Name (Method : Unsigned_16) return String is
   begin
      return Backup.Incremental_Syntax.Method_Name (Method);
   end Method_Name;

   function Decimal (Value : Unsigned_64) return String is
      Image : constant String := Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Decimal_32 (Value : Unsigned_32) return String is
   begin
      return Decimal (Unsigned_64 (Value));
   end Decimal_32;

   function Decimal_Natural (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal_Natural;

   function Path_At
     (Item : Backup.Scanner.Discovered_Entry)
      return String
   is
   begin
      return Backup.Paths.To_String (Item.Archive_Path);
   end Path_At;

   procedure Count_Decision
     (Result   : in out Plan;
      Decision : Decision_Kind)
   is
   begin
      case Decision is
         when Decision_Added =>
            Result.Added_Count := Result.Added_Count + 1;
         when Decision_Modified =>
            Result.Modified_Count := Result.Modified_Count + 1;
         when Decision_Removed =>
            Result.Removed_Count := Result.Removed_Count + 1;
         when Decision_Reused =>
            Result.Reused_Count := Result.Reused_Count + 1;
         when Decision_Skipped =>
            Result.Skipped_Count := Result.Skipped_Count + 1;
      end case;
   end Count_Decision;

   procedure Uncount_Decision
     (Result   : in out Plan;
      Decision : Decision_Kind)
   is
   begin
      case Decision is
         when Decision_Added =>
            pragma Assert
              (Result.Added_Count > 0,
               "incremental added count can be decremented");
            Result.Added_Count := Result.Added_Count - 1;
         when Decision_Modified =>
            pragma Assert
              (Result.Modified_Count > 0,
               "incremental modified count can be decremented");
            Result.Modified_Count := Result.Modified_Count - 1;
         when Decision_Removed =>
            pragma Assert
              (Result.Removed_Count > 0,
               "incremental removed count can be decremented");
            Result.Removed_Count := Result.Removed_Count - 1;
         when Decision_Reused =>
            pragma Assert
              (Result.Reused_Count > 0,
               "incremental reused count can be decremented");
            Result.Reused_Count := Result.Reused_Count - 1;
         when Decision_Skipped =>
            pragma Assert
              (Result.Skipped_Count > 0,
               "incremental skipped count can be decremented");
            Result.Skipped_Count := Result.Skipped_Count - 1;
      end case;
   end Uncount_Decision;

   function Prior_Metadata_Is_Consistent
     (Item       : Prior_Entry;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      Expected_Compressed_Size : Unsigned_64 := 0;
   begin
      if Item.Kind = Plan_Symlink then
         if Item.Method /= 0 then
            Diagnostic := To_Unbounded_String
              ("prior symlink entry is not stored: " &
               To_String (Item.Archive_Path));
            return False;
         end if;

         if Item.Compressed_Size /= Item.Uncompressed_Size then
            Diagnostic := To_Unbounded_String
              ("prior symlink entry has inconsistent size metadata: " &
               To_String (Item.Archive_Path));
            return False;
         end if;

         if Item.Uncompressed_Size /= Unsigned_64 (Length (Item.Link_Target))
         then
            Diagnostic := To_Unbounded_String
              ("prior symlink entry size does not match link target: " &
               To_String (Item.Archive_Path));
            return False;
         end if;

         if Item.Crc32 /= Backup.Zip.Crc32_Of_Text (Item.Link_Target) then
            Diagnostic := To_Unbounded_String
              ("prior symlink entry has inconsistent CRC metadata: " &
               To_String (Item.Archive_Path));
            return False;
         end if;

         return True;
      end if;

      if Item.Kind = Plan_Manifest then
         return True;
      end if;

      if Item.Method = 0 then
         Expected_Compressed_Size := Item.Uncompressed_Size;
      elsif Item.Method = 8 then
         Expected_Compressed_Size := Item.Compressed_Size;
         if Item.Compressed_Size = 0 and then Item.Uncompressed_Size > 0 then
            Diagnostic := To_Unbounded_String
              ("prior deflated file has empty compressed payload: " &
               To_String (Item.Archive_Path));
            return False;
         end if;
      else
         Diagnostic := To_Unbounded_String
           ("unsupported prior compression method for " &
            To_String (Item.Archive_Path));
         return False;
      end if;

      if Item.Compressed_Size /= Expected_Compressed_Size then
         Diagnostic := To_Unbounded_String
           ("prior file entry has non-deterministic compressed size " &
            "metadata: " & To_String (Item.Archive_Path));
         return False;
      end if;

      return True;
   end Prior_Metadata_Is_Consistent;

   function Current_Metadata
     (Item     : Backup.Scanner.Discovered_Entry;
      Position : Natural;
      Result   : out Plan_Item)
      return Plan_Status
   is
      Crc  : Unsigned_32 := 0;
      Size : Unsigned_64 := 0;
   begin
      Result :=
        (Archive_Path      => To_Unbounded_String (Path_At (Item)),
         Decision          => Decision_Added,
         Kind              =>
           (if Item.Kind = Backup.Scanner.Entry_Symlink then
              Plan_Symlink
            else
              Plan_File),
         Method            =>
           (if Item.Kind = Backup.Scanner.Entry_Symlink then
              0
            else
              Backup.Zip.Method_Number (Item.Compression_Method)),
         Crc32             => 0,
         Compressed_Size   => 0,
         Uncompressed_Size => Item.Byte_Size,
         Link_Target       => Item.Link_Target,
         Previous_Index    => 0,
         Current_Index     => Position);

      if Item.Kind = Backup.Scanner.Entry_Symlink then
         Result.Crc32 := Backup.Zip.Crc32_Of_Text (Item.Link_Target);
         Result.Compressed_Size := Item.Byte_Size;
         return Plan_Ok;
      end if;

      if Backup.Zip.Analyze_File (Item.Source_Path, Crc, Size)
        /= Backup.Zip.Write_Ok
      then
         return Plan_Unreadable_Source;
      end if;

      if Size /= Item.Byte_Size then
         return Plan_Conflicting_Metadata;
      end if;

      Result.Crc32 := Crc;
      if Item.Has_Prepared_Payload then
         Result.Compressed_Size := Item.Prepared_Compressed_Size;
      elsif not Backup.Metadata.Estimate_Compressed_Size_For_Direct_Metadata
        (Item.Compression_Method, Item.Source_Path, Size, Result.Compressed_Size)
      then
         return Plan_Conflicting_Metadata;
      end if;

      return Plan_Ok;
   end Current_Metadata;

   function Same_Content
     (Current : Plan_Item;
      Prior   : Prior_Entry)
      return Boolean
   is
   begin
      return Current.Kind = Prior.Kind
        and then Current.Method = Prior.Method
        and then Current.Crc32 = Prior.Crc32
        and then Current.Uncompressed_Size = Prior.Uncompressed_Size
        and then Current.Compressed_Size = Prior.Compressed_Size
        and then To_String (Current.Link_Target) =
          To_String (Prior.Link_Target);
   end Same_Content;

   function Find_Prior
     (Prior : Prior_Vectors.Vector;
      Name  : String)
      return Natural
   is
   begin
      if Prior.Is_Empty then
         return 0;
      end if;

      for Index in Prior.First_Index .. Prior.Last_Index loop
         if To_String (Prior.Element (Index).Archive_Path) = Name then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Prior;

   function Has_Duplicate
     (Prior      : Prior_Vectors.Vector;
      Candidate  : String)
      return Boolean
   is
      Count : Natural := 0;
   begin
      for Item of Prior loop
         if To_String (Item.Archive_Path) = Candidate then
            Count := Count + 1;
         end if;
      end loop;
      return Count > 1;
   end Has_Duplicate;

   function Validate_Prior
     (Prior      : Prior_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Plan_Status
   is
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      for Item of Prior loop
         Status := Backup.Paths.Make_Archive_Path
           (To_String (Item.Archive_Path), Archive);
         if Status /= Backup.Paths.Valid then
            Diagnostic := To_Unbounded_String
              ("invalid prior archive path: " & To_String (Item.Archive_Path));
            return Plan_Invalid_Archive_Path;
         end if;

         pragma Assert
           (Backup.Paths.To_String (Archive)'Length > 0,
            "validated prior archive path remains non-empty");

         if Has_Duplicate (Prior, To_String (Item.Archive_Path)) then
            Diagnostic := To_Unbounded_String
              ("duplicate prior archive path: " &
               To_String (Item.Archive_Path));
            return Plan_Duplicate_Archive_Path;
         end if;

         if Item.Method /= 0 and then Item.Method /= 8 then
            Diagnostic := To_Unbounded_String
              ("unsupported prior compression method for " &
               To_String (Item.Archive_Path));
            return Plan_Unsupported_Method;
         end if;

         if not Prior_Metadata_Is_Consistent (Item, Diagnostic) then
            return Plan_Conflicting_Metadata;
         end if;
      end loop;

      return Plan_Ok;
   end Validate_Prior;

   function Build_From_Prior
     (Prior      : in out Prior_Vectors.Vector;
      Current    : Backup.Scanner.Entry_Vectors.Vector;
      Result     : out Plan;
      Diagnostic : out Unbounded_String)
      return Plan_Status
   is
      Status : Plan_Status;
      Item   : Plan_Item;
      Pos    : Natural := 0;
      Match  : Natural;
      Prior_Item : Prior_Entry;
   begin
      Result :=
        (Strategy       => Synthetic_Full_Archive,
         Items          => Plan_Item_Vectors.Empty_Vector,
         Added_Count    => 0,
         Modified_Count => 0,
         Removed_Count  => 0,
         Reused_Count   => 0,
         Skipped_Count  => 0);
      Diagnostic := Null_Unbounded_String;

      Status := Validate_Prior (Prior, Diagnostic);
      if Status /= Plan_Ok then
         return Status;
      end if;

      for Current_Item of Current loop
         Pos := Pos + 1;
         if Result.Items.Length > 0 then
            for Existing of Result.Items loop
               if To_String (Existing.Archive_Path) = Path_At (Current_Item)
               then
                  Diagnostic := To_Unbounded_String
                    ("duplicate current archive path: " &
                     Path_At (Current_Item));
                  return Plan_Duplicate_Archive_Path;
               end if;
            end loop;
         end if;

         Status := Current_Metadata (Current_Item, Pos, Item);
         if Status /= Plan_Ok then
            Diagnostic := To_Unbounded_String
              (Status_Text (Status) & ": " & Path_At (Current_Item));
            return Status;
         end if;

         Match := Find_Prior (Prior, Path_At (Current_Item));
         if Match = 0 then
            Item.Decision := Decision_Added;
         else
            Prior_Item := Prior.Element (Match);
            Item.Previous_Index := Match;
            if Same_Content (Item, Prior_Item) then
               Item.Decision := Decision_Reused;
            else
               Item.Decision := Decision_Modified;
            end if;
            Prior_Item.Matched := True;
            Prior.Replace_Element (Match, Prior_Item);
         end if;

         Count_Decision (Result, Item.Decision);
         Result.Items.Append (Item);
      end loop;

      if not Prior.Is_Empty then
         for Index in Prior.First_Index .. Prior.Last_Index loop
            Prior_Item := Prior.Element (Index);
            if not Prior_Item.Matched then
            Item :=
              (Archive_Path      => Prior_Item.Archive_Path,
               Decision          => Decision_Removed,
               Kind              => Prior_Item.Kind,
               Method            => Prior_Item.Method,
               Crc32             => Prior_Item.Crc32,
               Compressed_Size   => Prior_Item.Compressed_Size,
               Uncompressed_Size => Prior_Item.Uncompressed_Size,
               Link_Target       => Prior_Item.Link_Target,
               Previous_Index    => Index,
               Current_Index     => 0);
               Count_Decision (Result, Decision_Removed);
               Result.Items.Append (Item);
            end if;
         end loop;
      end if;

      pragma Assert
        (Result.Added_Count + Result.Modified_Count +
         Result.Removed_Count + Result.Reused_Count +
         Result.Skipped_Count = Natural (Result.Items.Length),
         "incremental decision counts match plan item count");
      return Plan_Ok;
   end Build_From_Prior;

   function Kind_From_Verified
     (Kind : Backup.Verify.Entry_Kind)
      return Plan_Entry_Kind
   is
   begin
      case Kind is
         when Backup.Verify.Entry_File => return Plan_File;
         when Backup.Verify.Entry_Directory => return Plan_Directory;
         when Backup.Verify.Entry_Symlink => return Plan_Symlink;
         when Backup.Verify.Entry_Manifest => return Plan_Manifest;
      end case;
   end Kind_From_Verified;

   procedure Delete_If_Exists (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Delete_If_Exists;

   function Counter_Text (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Counter_Text;

   function Unique_Temp_Path
     (Base   : String;
      Suffix : String)
      return String
   is
   begin
      for Counter in Natural range 0 .. 10_000 loop
         declare
            Candidate : constant String :=
              Base & Suffix & "." & Counter_Text (Counter);
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;

      return Base & Suffix & ".overflow";
   end Unique_Temp_Path;

   function Build_From_Archive
     (Previous_Archive_Path : String;
      Current               : Backup.Scanner.Entry_Vectors.Vector;
      Result                : out Plan;
      Diagnostic            : out Unbounded_String)
      return Plan_Status
   is
      No_Password : constant Backup.Encryption.Password_Source :=
        (Kind  => Backup.Encryption.Password_None,
         Value => Null_Unbounded_String);
   begin
      return Build_From_Archive
        (Previous_Archive_Path, No_Password, Current, Result, Diagnostic);
   end Build_From_Archive;

   function Build_From_Archive
     (Previous_Archive_Path : String;
      Password              : Backup.Encryption.Password_Source;
      Current               : Backup.Scanner.Entry_Vectors.Vector;
      Result                : out Plan;
      Diagnostic            : out Unbounded_String)
      return Plan_Status
   is
      Report : Backup.Verify.Verification_Report;
      Work_Path : Unbounded_String := To_Unbounded_String (Previous_Archive_Path);
      Temporary_Work_Path : Boolean := False;
      Verify_Status : Backup.Verify.Verify_Status;
      Prior : Prior_Vectors.Vector;
   begin
      if Backup.Encryption.Is_Encrypted (Previous_Archive_Path) then
         declare
            Envelope_Status : Backup.Encryption.Envelope_Status;
         begin
            Work_Path := To_Unbounded_String
              (Unique_Temp_Path
                 (Previous_Archive_Path, ".phase19-decrypted.zip"));
            Envelope_Status := Backup.Encryption.Decrypt_File
              (Previous_Archive_Path, To_String (Work_Path),
               Password, Diagnostic);
            if Envelope_Status /= Backup.Encryption.Envelope_Ok then
               if Length (Diagnostic) = 0 then
                  Diagnostic := To_Unbounded_String
                    (Backup.Encryption.Status_Text (Envelope_Status));
               end if;
               return Plan_Previous_Verify_Failed;
            end if;
            Temporary_Work_Path := True;
         end;
      end if;

      begin
         Verify_Status := Backup.Verify.Verify_Archive
           (To_String (Work_Path), Report, Diagnostic);
      exception
         when others =>
            if Temporary_Work_Path then
               Delete_If_Exists (To_String (Work_Path));
            end if;
            Diagnostic := To_Unbounded_String
              ("previous archive verification raised an exception");
            return Plan_Previous_Verify_Failed;
      end;

      if Temporary_Work_Path then
         Delete_If_Exists (To_String (Work_Path));
      end if;

      if Verify_Status = Backup.Verify.Verify_Open_Failed then
         return Plan_Previous_Open_Failed;
      elsif Verify_Status /= Backup.Verify.Verify_Ok then
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String
              (Backup.Verify.Status_Text (Verify_Status));
         end if;
         return Plan_Previous_Verify_Failed;
      end if;

      for Item of Report.Entries loop
         if Item.Kind /= Backup.Verify.Entry_Manifest then
            Prior.Append
              (Prior_Entry'(Archive_Path      => Item.Archive_Path,
                Kind              => Kind_From_Verified (Item.Kind),
                Method            => Item.Method,
                Crc32             => Item.Crc32,
                Compressed_Size   => Item.Compressed_Size,
                Uncompressed_Size => Item.Uncompressed_Size,
                Link_Target       => Item.Link_Target,
                Matched           => False));
         end if;
      end loop;

      return Build_From_Prior (Prior, Current, Result, Diagnostic);
   end Build_From_Archive;

   function Read_Text_File
     (Path       : String;
      Text       : out Unbounded_String;
      Diagnostic : out Unbounded_String)
      return Boolean
   is
      File : Ada.Text_IO.File_Type;
   begin
      Text := Null_Unbounded_String;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Text, Ada.Text_IO.Get_Line (File));
         Append (Text, ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return True;
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("could not read previous manifest: " & Path);
         return False;
   end Read_Text_File;

   function Next_Object_End
     (Text : String;
      Pos  : Natural)
      return Natural
   is
      Depth     : Natural := 0;
      In_String : Boolean := False;
      Escaped   : Boolean := False;
      Started   : Boolean := False;
   begin
      if Pos = 0 or else Pos > Text'Last then
         return 0;
      end if;

      for Index in Pos .. Text'Last loop
         if In_String then
            if Escaped then
               Escaped := False;
            elsif Text (Index) = '\' then
               Escaped := True;
            elsif Text (Index) = '"' then
               In_String := False;
            end if;
         elsif Text (Index) = '"' then
            In_String := True;
         elsif Text (Index) = '{' then
            Depth := Depth + 1;
            Started := True;
         elsif Text (Index) = '}' then
            if not Started or else Depth = 0 then
               return 0;
            end if;
            Depth := Depth - 1;
            if Depth = 0 then
               return Index;
            end if;
         end if;
      end loop;
      return 0;
   end Next_Object_End;

   function Skip_Spaces
     (Text : String;
      Pos  : Natural)
      return Natural
   is
      Index : Natural := Pos;
   begin
      while Index <= Text'Last
        and then
          (Text (Index) = ' '
           or else Text (Index) = ASCII.HT
           or else Text (Index) = ASCII.LF
           or else Text (Index) = ASCII.CR)
      loop
         Index := Index + 1;
      end loop;
      return Index;
   end Skip_Spaces;


   function Next_Array_End
     (Text : String;
      Pos  : Natural)
      return Natural
   is
      Depth     : Natural := 0;
      In_String : Boolean := False;
      Escaped   : Boolean := False;
      Started   : Boolean := False;
   begin
      if Text'Length = 0 or else Pos < Text'First or else Pos > Text'Last
      then
         return 0;
      end if;

      for Index in Pos .. Text'Last loop
         if In_String then
            if Escaped then
               Escaped := False;
            elsif Text (Index) = '\' then
               Escaped := True;
            elsif Text (Index) = '"' then
               In_String := False;
            end if;
         elsif Text (Index) = '"' then
            In_String := True;
         elsif Text (Index) = '[' then
            Depth := Depth + 1;
            Started := True;
         elsif Text (Index) = ']' then
            if not Started or else Depth = 0 then
               return 0;
            end if;
            Depth := Depth - 1;
            if Depth = 0 then
               return Index;
            end if;
         end if;
      end loop;

      return 0;
   end Next_Array_End;


   function Find_Direct_JSON_Key
     (Text : String;
      Name : String)
      return Natural
   is
      Key          : constant String := '"' & Name & '"';
      Object_Depth : Natural := 0;
      Array_Depth  : Natural := 0;
      Index        : Natural := Text'First;
      In_String    : Boolean := False;
      Escaped      : Boolean := False;
      Start_Pos    : Natural;
      End_Pos      : Natural;
      After_Key    : Natural;
   begin
      if Text'Length = 0 or else Key'Length = 0 then
         return 0;
      end if;

      while Index <= Text'Last loop
         if In_String then
            if Escaped then
               Escaped := False;
            elsif Text (Index) = '\' then
               Escaped := True;
            elsif Text (Index) = '"' then
               In_String := False;
            end if;
         elsif Text (Index) = '"' then
            Start_Pos := Index;
            End_Pos := Start_Pos + Key'Length - 1;
            if Object_Depth = 1
              and then Array_Depth = 0
              and then End_Pos <= Text'Last
              and then Text (Start_Pos .. End_Pos) = Key
            then
               After_Key := Skip_Spaces (Text, End_Pos + 1);
               if After_Key <= Text'Last
                 and then Text (After_Key) = ':'
               then
                  return Start_Pos;
               end if;
            end if;
            In_String := True;
         elsif Text (Index) = '{' then
            Object_Depth := Object_Depth + 1;
         elsif Text (Index) = '}' then
            if Object_Depth = 0 then
               return 0;
            end if;
            Object_Depth := Object_Depth - 1;
         elsif Text (Index) = '[' then
            Array_Depth := Array_Depth + 1;
         elsif Text (Index) = ']' then
            if Array_Depth = 0 then
               return 0;
            end if;
            Array_Depth := Array_Depth - 1;
         end if;

         Index := Index + 1;
      end loop;

      return 0;
   end Find_Direct_JSON_Key;



   function Count_Direct_JSON_Key
     (Text : String;
      Name : String)
      return Natural
   is
      Key          : constant String := '"' & Name & '"';
      Object_Depth : Natural := 0;
      Array_Depth  : Natural := 0;
      Index        : Natural := Text'First;
      In_String    : Boolean := False;
      Escaped      : Boolean := False;
      Start_Pos    : Natural;
      End_Pos      : Natural;
      After_Key    : Natural;
      Count        : Natural := 0;
   begin
      if Text'Length = 0 or else Key'Length = 0 then
         return 0;
      end if;

      while Index <= Text'Last loop
         if In_String then
            if Escaped then
               Escaped := False;
            elsif Text (Index) = '\' then
               Escaped := True;
            elsif Text (Index) = '"' then
               In_String := False;
            end if;
         elsif Text (Index) = '"' then
            Start_Pos := Index;
            End_Pos := Start_Pos + Key'Length - 1;
            if Object_Depth = 1
              and then Array_Depth = 0
              and then End_Pos <= Text'Last
              and then Text (Start_Pos .. End_Pos) = Key
            then
               After_Key := Skip_Spaces (Text, End_Pos + 1);
               if After_Key <= Text'Last
                 and then Text (After_Key) = ':'
               then
                  Count := Count + 1;
               end if;
            end if;
            In_String := True;
         elsif Text (Index) = '{' then
            Object_Depth := Object_Depth + 1;
         elsif Text (Index) = '}' then
            if Object_Depth = 0 then
               return Count;
            end if;
            Object_Depth := Object_Depth - 1;
         elsif Text (Index) = '[' then
            Array_Depth := Array_Depth + 1;
         elsif Text (Index) = ']' then
            if Array_Depth = 0 then
               return Count;
            end if;
            Array_Depth := Array_Depth - 1;
         end if;

         Index := Index + 1;
      end loop;

      return Count;
   end Count_Direct_JSON_Key;

   function Has_Exactly_One_Direct_JSON_Key
     (Text : String;
      Name : String)
      return Boolean
   is
   begin
      return Count_Direct_JSON_Key (Text, Name) = 1;
   end Has_Exactly_One_Direct_JSON_Key;


   function Key_Value_Start
     (Object_Text : String;
      Name        : String)
      return Natural
   is
      Key     : constant String := '"' & Name & '"';
      Key_Pos : constant Natural := Find_Direct_JSON_Key (Object_Text, Name);
      Pos     : Natural;
   begin
      if Key_Pos = 0 then
         return 0;
      end if;

      Pos := Skip_Spaces (Object_Text, Key_Pos + Key'Length);
      pragma Assert
        (Pos <= Object_Text'Last and then Object_Text (Pos) = ':',
         "JSON key search returns a direct key immediately followed by ':'");
      return Skip_Spaces (Object_Text, Pos + 1);
   end Key_Value_Start;



   function Is_JSON_Value_Delimiter
     (Text : String;
      Pos  : Natural)
      return Boolean
   is
      Index : constant Natural := Skip_Spaces (Text, Pos);
   begin
      return Index > Text'Last
        or else Text (Index) = ','
        or else Text (Index) = '}';
   end Is_JSON_Value_Delimiter;


   function Hex_Value
     (Ch    : Character;
      Value : out Natural)
      return Boolean
   is
   begin
      if Ch in '0' .. '9' then
         Value := Character'Pos (Ch) - Character'Pos ('0');
      elsif Ch in 'a' .. 'f' then
         Value := Character'Pos (Ch) - Character'Pos ('a') + 10;
      elsif Ch in 'A' .. 'F' then
         Value := Character'Pos (Ch) - Character'Pos ('A') + 10;
      else
         return False;
      end if;
      return True;
   end Hex_Value;


   function JSON_String_End
     (Text : String;
      Pos  : Natural)
      return Natural
   is
      Index : Natural := Pos + 1;
      Digit : Natural;
   begin
      if Text'Length = 0
        or else Pos < Text'First
        or else Pos > Text'Last
        or else Text (Pos) /= '"'
      then
         return 0;
      end if;

      while Index <= Text'Last loop
         if Text (Index) = '"' then
            return Index;
         elsif Text (Index) = '\' then
            Index := Index + 1;
            if Index > Text'Last then
               return 0;
            end if;

            case Text (Index) is
               when '"' | '\' | '/' | 'b' | 't' | 'n' | 'f' | 'r' =>
                  null;
               when 'u' =>
                  if Index + 4 > Text'Last then
                     return 0;
                  end if;
                  for Offset in 1 .. 4 loop
                     if not Hex_Value (Text (Index + Offset), Digit) then
                        return 0;
                     end if;
                  end loop;
                  Index := Index + 4;
               when others =>
                  return 0;
            end case;
         elsif Character'Pos (Text (Index)) < 32 then
            return 0;
         end if;

         Index := Index + 1;
      end loop;

      return 0;
   end JSON_String_End;

   function JSON_Value_End
     (Text : String;
      Pos  : Natural)
      return Natural
   is
      Index : Natural := Pos;
   begin
      if Text'Length = 0 or else Pos < Text'First or else Pos > Text'Last then
         return 0;
      end if;

      case Text (Pos) is
         when '"' =>
            return JSON_String_End (Text, Pos);
         when '{' =>
            return Next_Object_End (Text, Pos);
         when '[' =>
            return Next_Array_End (Text, Pos);
         when '0' .. '9' =>
            while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
               Index := Index + 1;
            end loop;
            return Index - 1;
         when others =>
            return 0;
      end case;
   end JSON_Value_End;

   function Direct_Object_Syntax_Is_Valid
     (Text : String)
      return Boolean
   is
      Pos       : Natural;
      Key_End   : Natural;
      Value_End : Natural;
   begin
      if Text'Length = 0
        or else Text (Text'First) /= '{'
        or else Text (Text'Last) /= '}'
      then
         return False;
      end if;

      Pos := Skip_Spaces (Text, Text'First + 1);
      if Pos = Text'Last then
         return True;
      end if;

      loop
         if Pos > Text'Last or else Text (Pos) /= '"' then
            return False;
         end if;

         Key_End := JSON_String_End (Text, Pos);
         if Key_End = 0 then
            return False;
         end if;

         Pos := Skip_Spaces (Text, Key_End + 1);
         if Pos > Text'Last or else Text (Pos) /= ':' then
            return False;
         end if;

         Pos := Skip_Spaces (Text, Pos + 1);
         Value_End := JSON_Value_End (Text, Pos);
         if Value_End = 0 then
            return False;
         end if;

         Pos := Skip_Spaces (Text, Value_End + 1);
         if Pos > Text'Last then
            return False;
         elsif Text (Pos) = ',' then
            Pos := Skip_Spaces (Text, Pos + 1);
            if Pos > Text'Last or else Text (Pos) = '}' then
               return False;
            end if;
         elsif Text (Pos) = '}' then
            return Skip_Spaces (Text, Pos + 1) > Text'Last;
         else
            return False;
         end if;
      end loop;
   end Direct_Object_Syntax_Is_Valid;

   procedure Append_Codepoint_As_Byte
     (Value  : Natural;
      Result : in out Unbounded_String;
      Valid  : in out Boolean)
   is
   begin
      if Value > Character'Pos (Character'Last) then
         Valid := False;
      else
         Append (Result, Character'Val (Value));
      end if;
   end Append_Codepoint_As_Byte;

   function Extract_String
     (Object_Text : String;
      Name        : String;
      Value       : out Unbounded_String)
      return Boolean
   is
      Pos       : Natural := Key_Value_Start (Object_Text, Name);
      Escape    : Character;
      Code      : Natural;
      Digit     : Natural;
      Valid     : Boolean := True;
   begin
      Value := Null_Unbounded_String;
      if Pos = 0 or else Pos > Object_Text'Last
        or else Object_Text (Pos) /= '"'
      then
         return False;
      end if;

      Pos := Pos + 1;
      while Pos <= Object_Text'Last loop
         if Object_Text (Pos) = '"' then
            return Valid
              and then Is_JSON_Value_Delimiter (Object_Text, Pos + 1);
         elsif Object_Text (Pos) = '\' then
            Pos := Pos + 1;
            if Pos > Object_Text'Last then
               return False;
            end if;

            Escape := Object_Text (Pos);
            case Escape is
               when '"' | '\' | '/' =>
                  Append (Value, Escape);
               when 'b' =>
                  Append (Value, ASCII.BS);
               when 't' =>
                  Append (Value, ASCII.HT);
               when 'n' =>
                  Append (Value, ASCII.LF);
               when 'f' =>
                  Append (Value, ASCII.FF);
               when 'r' =>
                  Append (Value, ASCII.CR);
               when 'u' =>
                  if Pos + 4 > Object_Text'Last then
                     return False;
                  end if;
                  Code := 0;
                  for Offset in 1 .. 4 loop
                     if not Hex_Value (Object_Text (Pos + Offset), Digit) then
                        return False;
                     end if;
                     Code := Code * 16 + Digit;
                  end loop;
                  Append_Codepoint_As_Byte (Code, Value, Valid);
                  Pos := Pos + 4;
               when others =>
                  return False;
            end case;
         else
            if Character'Pos (Object_Text (Pos)) < 32 then
               return False;
            end if;
            Append (Value, Object_Text (Pos));
         end if;
         Pos := Pos + 1;
      end loop;

      return False;
   end Extract_String;

   function Extract_Number
     (Object_Text : String;
      Name        : String;
      Value       : out Unsigned_64)
      return Boolean
   is
      Pos          : Natural := Key_Value_Start (Object_Text, Name);
      Start_Pos    : Natural;
      Accum        : Unsigned_64 := 0;
      Digit        : Unsigned_64;
      Leading_Zero : Boolean := False;
   begin
      Value := 0;
      if Pos = 0 or else Pos > Object_Text'Last
        or else Object_Text (Pos) not in '0' .. '9'
      then
         return False;
      end if;

      Start_Pos := Pos;
      Leading_Zero := Object_Text (Pos) = '0';
      while Pos <= Object_Text'Last
        and then Object_Text (Pos) in '0' .. '9'
      loop
         if Leading_Zero and then Pos > Start_Pos then
            return False;
         end if;
         Digit := Unsigned_64
           (Character'Pos (Object_Text (Pos)) - Character'Pos ('0'));
         if Accum > (Unsigned_64'Last - Digit) / 10 then
            return False;
         end if;
         Accum := Accum * 10 + Digit;
         Pos := Pos + 1;
      end loop;
      if not Is_JSON_Value_Delimiter (Object_Text, Pos) then
         return False;
      end if;

      Value := Accum;
      return True;
   end Extract_Number;

   function Parse_Manifest_Prior
     (Text       : String;
      Prior      : out Prior_Vectors.Vector;
      Diagnostic : out Unbounded_String)
      return Plan_Status
   is
      Pos        : Natural := Text'First;
      Start_Pos  : Natural;
      End_Pos    : Natural;
      Name       : Unbounded_String;
      Kind_Text  : Unbounded_String;
      Method_Text : Unbounded_String;
      Link_Target : Unbounded_String;
      Crc_Value   : Unsigned_64;
      Comp_Size   : Unsigned_64;
      Uncomp_Size : Unsigned_64;
      Kind        : Plan_Entry_Kind;
      Method      : Unsigned_16;
      Archive     : Backup.Paths.Archive_Path;
      Path_Status : Backup.Paths.Validation_Status;
      Format_Text : Unbounded_String;
      Entries_Key_Count : Natural;
      Entries_Start     : Natural;
      Entries_End       : Natural;
      Root_Start        : Natural;
      Root_End          : Natural;
      After_Root        : Natural;
   begin
      Prior.Clear;
      if Text'Length = 0 then
         Diagnostic := To_Unbounded_String
           ("previous manifest is empty");
         return Plan_Invalid_Manifest;
      end if;

      Root_Start := Skip_Spaces (Text, Text'First);
      if Root_Start > Text'Last or else Text (Root_Start) /= '{' then
         Diagnostic := To_Unbounded_String
           ("previous manifest root is not an object");
         return Plan_Invalid_Manifest;
      end if;

      Root_End := Next_Object_End (Text, Root_Start);
      if Root_End = 0 then
         Diagnostic := To_Unbounded_String
           ("previous manifest root object is malformed");
         return Plan_Invalid_Manifest;
      end if;

      After_Root := Skip_Spaces (Text, Root_End + 1);
      if After_Root <= Text'Last then
         Diagnostic := To_Unbounded_String
           ("previous manifest has trailing content after root object");
         return Plan_Invalid_Manifest;
      end if;

      if not Direct_Object_Syntax_Is_Valid (Text (Root_Start .. Root_End)) then
         Diagnostic := To_Unbounded_String
           ("previous manifest root object has invalid field separators");
         return Plan_Invalid_Manifest;
      end if;

      if not Has_Exactly_One_Direct_JSON_Key (Text, "format") then
         Diagnostic := To_Unbounded_String
           ("previous manifest must contain exactly one top-level format " &
            "field");
         return Plan_Invalid_Manifest;
      end if;

      if not Extract_String (Text, "format", Format_Text)
        or else To_String (Format_Text) /= "backup-manifest-v1"
      then
         Diagnostic := To_Unbounded_String
           ("previous manifest format is not backup-manifest-v1");
         return Plan_Invalid_Manifest;
      end if;

      Entries_Key_Count := Count_Direct_JSON_Key (Text, "entries");
      if Entries_Key_Count /= 1 then
         Diagnostic := To_Unbounded_String
           ("previous manifest must contain exactly one top-level entries " &
            "array");
         return Plan_Invalid_Manifest;
      end if;

      Entries_Start := Key_Value_Start (Text, "entries");
      if Entries_Start = 0
        or else Entries_Start > Text'Last
        or else Text (Entries_Start) /= '['
      then
         Diagnostic := To_Unbounded_String
           ("previous manifest entries field is not an array");
         return Plan_Invalid_Manifest;
      end if;

      Entries_End := Next_Array_End (Text, Entries_Start);
      if Entries_End = 0 then
         Diagnostic := To_Unbounded_String
           ("previous manifest entries array is malformed");
         return Plan_Invalid_Manifest;
      end if;

      Pos := Skip_Spaces (Text, Entries_Start + 1);
      if Pos > Entries_End then
         Diagnostic := To_Unbounded_String
           ("previous manifest entries array is malformed");
         return Plan_Invalid_Manifest;
      end if;

      if Text (Pos) /= ']' then
         loop
            Start_Pos := Pos;
            if Text (Start_Pos) /= '{' then
               Diagnostic := To_Unbounded_String
                 ("previous manifest entries array contains a " &
                  "non-object value");
               return Plan_Invalid_Manifest;
            end if;

            End_Pos := Next_Object_End (Text, Start_Pos);
            if End_Pos = 0
              or else Start_Pos > End_Pos
              or else End_Pos > Entries_End
            then
               Diagnostic := To_Unbounded_String
                 ("previous manifest entry object is malformed");
               return Plan_Invalid_Manifest;
            end if;

            declare
               Object_Text : constant String := Text (Start_Pos .. End_Pos);
            begin
               if not Direct_Object_Syntax_Is_Valid (Object_Text) then
                  Diagnostic := To_Unbounded_String
                    ("previous manifest entry object has invalid field " &
                     "separators");
                  return Plan_Invalid_Manifest;
               end if;

               if not Has_Exactly_One_Direct_JSON_Key
                 (Object_Text, "archive_path")
               then
                  Diagnostic := To_Unbounded_String
                    ("previous manifest entry must contain exactly one " &
                     "archive_path field");
                  return Plan_Invalid_Manifest;
               end if;

               if not Has_Exactly_One_Direct_JSON_Key (Object_Text, "kind")
                 or else not Has_Exactly_One_Direct_JSON_Key
                   (Object_Text, "compression_method")
                 or else not Has_Exactly_One_Direct_JSON_Key
                   (Object_Text, "crc32")
                 or else not Has_Exactly_One_Direct_JSON_Key
                   (Object_Text, "compressed_size")
                 or else not Has_Exactly_One_Direct_JSON_Key
                   (Object_Text, "uncompressed_size")
               then
                  Diagnostic := To_Unbounded_String
                    ("previous manifest entry has missing or duplicate " &
                     "required metadata");
                  return Plan_Invalid_Manifest;
               end if;

               if not Extract_String (Object_Text, "archive_path", Name)
                 or else not Extract_String (Object_Text, "kind", Kind_Text)
                 or else not Extract_String
                   (Object_Text, "compression_method", Method_Text)
                 or else not Extract_Number (Object_Text, "crc32", Crc_Value)
                 or else not Extract_Number
                   (Object_Text, "compressed_size", Comp_Size)
                 or else not Extract_Number
                   (Object_Text, "uncompressed_size", Uncomp_Size)
               then
                  Diagnostic := To_Unbounded_String
                    ("previous manifest entry is missing required metadata");
                  return Plan_Invalid_Manifest;
               end if;

               if To_String (Name) = Backup.Manifest.Manifest_Path then
                  null;
               else
                  Path_Status := Backup.Paths.Make_Archive_Path
                    (To_String (Name), Archive);
                  if Path_Status /= Backup.Paths.Valid then
                     Diagnostic := To_Unbounded_String
                       ("invalid prior manifest archive path: " &
                        To_String (Name));
                     return Plan_Invalid_Archive_Path;
                  end if;

                  pragma Assert
                    (Backup.Paths.To_String (Archive)'Length > 0,
                     "validated manifest archive path remains non-empty");

                  if To_String (Kind_Text) = "file" then
                     Kind := Plan_File;
                     Link_Target := Null_Unbounded_String;
                     if Count_Direct_JSON_Key (Object_Text, "link_target") /= 0
                     then
                        Diagnostic := To_Unbounded_String
                          ("previous manifest file entry must not contain " &
                           "link_target");
                        return Plan_Invalid_Manifest;
                     end if;
                  elsif To_String (Kind_Text) = "symlink" then
                     Kind := Plan_Symlink;
                     if not Has_Exactly_One_Direct_JSON_Key
                       (Object_Text, "link_target")
                       or else not Extract_String
                         (Object_Text, "link_target", Link_Target)
                     then
                        Diagnostic := To_Unbounded_String
                          ("previous manifest symlink entry lacks exactly " &
                           "one valid link_target");
                        return Plan_Invalid_Manifest;
                     end if;
                  else
                     Diagnostic := To_Unbounded_String
                       ("previous manifest entry has unsupported kind: " &
                        To_String (Kind_Text));
                     return Plan_Invalid_Manifest;
                  end if;

                  if To_String (Method_Text) = "stored" then
                     Method := 0;
                  elsif To_String (Method_Text) = "deflated" then
                     Method := 8;
                  else
                     Diagnostic := To_Unbounded_String
                       ("previous manifest entry has unsupported method: " &
                        To_String (Method_Text));
                     return Plan_Unsupported_Method;
                  end if;

                  if Crc_Value > Unsigned_64 (Unsigned_32'Last) then
                     Diagnostic := To_Unbounded_String
                       ("previous manifest crc32 value is out of range: " &
                        To_String (Name));
                     return Plan_Invalid_Manifest;
                  end if;

                  Prior.Append
                    (Prior_Entry'(Archive_Path      => Name,
                      Kind              => Kind,
                      Method            => Method,
                      Crc32             => Unsigned_32 (Crc_Value),
                      Compressed_Size   => Comp_Size,
                      Uncompressed_Size => Uncomp_Size,
                      Link_Target       => Link_Target,
                      Matched           => False));
               end if;
            end;

            Pos := Skip_Spaces (Text, End_Pos + 1);
            if Pos > Entries_End then
               Diagnostic := To_Unbounded_String
                 ("previous manifest entries array is malformed");
               return Plan_Invalid_Manifest;
            elsif Text (Pos) = ']' then
               exit;
            elsif Text (Pos) = ',' then
               Pos := Skip_Spaces (Text, Pos + 1);
               if Pos > Entries_End or else Text (Pos) = ']' then
                  Diagnostic := To_Unbounded_String
                    ("previous manifest entries array has a trailing comma");
                  return Plan_Invalid_Manifest;
               end if;
            else
               Diagnostic := To_Unbounded_String
                 ("previous manifest entries array has an invalid separator");
               return Plan_Invalid_Manifest;
            end if;
         end loop;
      end if;

      return Plan_Ok;
   end Parse_Manifest_Prior;

   function Build_From_Manifest
     (Previous_Manifest_Path : String;
      Current                : Backup.Scanner.Entry_Vectors.Vector;
      Result                 : out Plan;
      Diagnostic             : out Unbounded_String)
      return Plan_Status
   is
      Text   : Unbounded_String;
      Prior  : Prior_Vectors.Vector;
      Status : Plan_Status;
   begin
      if not Read_Text_File (Previous_Manifest_Path, Text, Diagnostic) then
         return Plan_Previous_Open_Failed;
      end if;

      Status := Parse_Manifest_Prior (To_String (Text), Prior, Diagnostic);
      if Status /= Plan_Ok then
         return Status;
      end if;

      return Build_From_Prior (Prior, Current, Result, Diagnostic);
   end Build_From_Manifest;


   function Ignored_To_Plan_Kind
     (Kind : Backup.Scanner.Ignored_Kind)
      return Plan_Entry_Kind
   is
   begin
      case Kind is
         when Backup.Scanner.Ignored_File =>
            return Plan_File;
         when Backup.Scanner.Ignored_Directory =>
            return Plan_Directory;
         when Backup.Scanner.Ignored_Symlink =>
            return Plan_Symlink;
      end case;
   end Ignored_To_Plan_Kind;

   function Find_Plan_Item
     (Result : Plan;
      Name   : String)
      return Natural
   is
   begin
      if Result.Items.Is_Empty then
         return 0;
      end if;

      for Index in Result.Items.First_Index .. Result.Items.Last_Index loop
         if To_String (Result.Items.Element (Index).Archive_Path) = Name then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Plan_Item;

   procedure Append_Skipped_Item
     (Result       : in out Plan;
      Archive_Path : Unbounded_String;
      Kind         : Plan_Entry_Kind;
      Link_Target  : Unbounded_String := Null_Unbounded_String)
   is
      Existing_Index : constant Natural :=
        Find_Plan_Item (Result, To_String (Archive_Path));
      Existing       : Plan_Item;
   begin
      if Existing_Index /= 0 then
         Existing := Result.Items.Element (Existing_Index);
         if Existing.Decision = Decision_Removed then
            --  Current filesystem policy is more specific than historical
            --  absence: if a prior path is now ignored or skipped as a
            --  symlink, expose it as skipped instead of only removed.
            Uncount_Decision (Result, Existing.Decision);
            Existing.Decision := Decision_Skipped;
            Existing.Kind := Kind;
            Existing.Method := 0;
            Existing.Crc32 := 0;
            Existing.Compressed_Size := 0;
            Existing.Uncompressed_Size := 0;
            Existing.Link_Target := Link_Target;
            Existing.Current_Index := 0;
            Result.Items.Replace_Element (Existing_Index, Existing);
            Count_Decision (Result, Decision_Skipped);
         end if;
         return;
      end if;

      Result.Items.Append
        (Plan_Item'(Archive_Path      => Archive_Path,
          Decision          => Decision_Skipped,
          Kind              => Kind,
          Method            => 0,
          Crc32             => 0,
          Compressed_Size   => 0,
          Uncompressed_Size => 0,
          Link_Target       => Link_Target,
          Previous_Index    => 0,
          Current_Index     => 0));
      Count_Decision (Result, Decision_Skipped);
   end Append_Skipped_Item;

   procedure Append_Skipped_From_Report
     (Result : in out Plan;
      Report : Backup.Scanner.Scan_Report)
   is
   begin
      for Ignored of Report.Ignored_Diagnostics loop
         Append_Skipped_Item
           (Result,
            Ignored.Archive_Path,
            Ignored_To_Plan_Kind (Ignored.Kind));
      end loop;

      for Link of Report.Symlink_Diagnostics loop
         if Link.Action = Backup.Scanner.Symlink_Skipped
           or else Link.Action = Backup.Scanner.Symlink_Broken
           or else Link.Action = Backup.Scanner.Symlink_Cycle
           or else Link.Action = Backup.Scanner.Symlink_Outside_Input
         then
            Append_Skipped_Item
              (Result,
               Link.Archive_Path,
               Plan_Symlink,
               Link.Target_Text);
         end if;
      end loop;

      pragma Assert
        (Result.Added_Count + Result.Modified_Count +
         Result.Removed_Count + Result.Reused_Count +
         Result.Skipped_Count = Natural (Result.Items.Length),
         "incremental decision counts match plan item count after " &
         "skipped diagnostics");
   end Append_Skipped_From_Report;

   procedure Append_Escape
     (Result : in out Unbounded_String;
      Code   : Character)
   is
   begin
      Append (Result, '\');
      Append (Result, Code);
   end Append_Escape;

   function Json_Escape (Text : String) return String is
      Result : Unbounded_String;
      Hex    : constant array (Natural range 0 .. 15) of Character :=
        "0123456789abcdef";
      Code   : Natural;
   begin
      for Ch of Text loop
         case Ch is
            when '"' => Append_Escape (Result, '"');
            when '\' => Append_Escape (Result, '\');
            when ASCII.BS => Append_Escape (Result, 'b');
            when ASCII.HT => Append_Escape (Result, 't');
            when ASCII.LF => Append_Escape (Result, 'n');
            when ASCII.FF => Append_Escape (Result, 'f');
            when ASCII.CR => Append_Escape (Result, 'r');
            when others =>
               Code := Character'Pos (Ch);
               if Code < 32 then
                  Append (Result, "\u00");
                  Append (Result, Hex (Code / 16));
                  Append (Result, Hex (Code mod 16));
               else
                  Append (Result, Ch);
               end if;
         end case;
      end loop;
      return To_String (Result);
   end Json_Escape;

   function Q (Text : String) return String is
   begin
      return '"' & Json_Escape (Text) & '"';
   end Q;

   procedure Build_Dry_Run_Report
     (Result : Plan;
      Text   : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String
        ("incremental plan" & ASCII.LF &
         "strategy: synthetic-full-archive" & ASCII.LF &
         "payload-reuse: semantic-plan" & ASCII.LF &
         "trust-model: prior metadata is trusted only after archive " &
         "verification or manifest validation" & ASCII.LF &
         "decisions:" & ASCII.LF);
      for Item of Result.Items loop
         Append (Text, "  ");
         Append (Text, Decision_Name (Item.Decision));
         Append (Text, " ");
         Append (Text, To_String (Item.Archive_Path));
         Append (Text, " kind=");
         Append (Text, Kind_Name (Item.Kind));
         Append (Text, " method=");
         Append (Text, Method_Name (Item.Method));
         Append (Text, " crc32=");
         Append (Text, Decimal_32 (Item.Crc32));
         Append (Text, " size=");
         Append (Text, Decimal (Item.Uncompressed_Size));
         if Item.Kind = Plan_Symlink then
            Append (Text, " link-target=");
            Append (Text, To_String (Item.Link_Target));
         end if;
         Append (Text, ASCII.LF);
      end loop;
      Append (Text, "summary: added=");
      Append (Text, Decimal_Natural (Result.Added_Count));
      Append (Text, " modified=");
      Append (Text, Decimal_Natural (Result.Modified_Count));
      Append (Text, " removed=");
      Append (Text, Decimal_Natural (Result.Removed_Count));
      Append (Text, " reused=");
      Append (Text, Decimal_Natural (Result.Reused_Count));
      Append (Text, " skipped=");
      Append (Text, Decimal_Natural (Result.Skipped_Count));
      Append (Text, ASCII.LF);
   end Build_Dry_Run_Report;

   procedure Build_JSON_Report
     (Result : Plan;
      Text   : out Unbounded_String)
   is
      First : Boolean := True;
   begin
      Text := To_Unbounded_String ("{" & ASCII.LF);
      Append (Text, "  " & Q ("format") & ": " &
        Q ("backup-incremental-plan-v1") & "," & ASCII.LF);
      Append (Text, "  " & Q ("strategy") & ": " &
        Q ("synthetic-full-archive") & "," & ASCII.LF);
      Append (Text, "  " & Q ("payload_reuse") & ": " &
        Q ("semantic-plan") & "," & ASCII.LF);
      Append (Text, "  " & Q ("trust_model") & ": " &
        Q ("prior metadata is trusted only after archive verification " &
           "or manifest validation") & "," & ASCII.LF);
      Append (Text, "  " & Q ("summary") & ": {");
      Append (Text, Q ("added") & ": " & Decimal_Natural (Result.Added_Count));
      Append (Text, ", " & Q ("modified") & ": " &
        Decimal_Natural (Result.Modified_Count));
      Append (Text, ", " & Q ("removed") & ": " &
        Decimal_Natural (Result.Removed_Count));
      Append (Text, ", " & Q ("reused") & ": " &
        Decimal_Natural (Result.Reused_Count));
      Append (Text, ", " & Q ("skipped") & ": " &
        Decimal_Natural (Result.Skipped_Count));
      Append (Text, "}," & ASCII.LF);
      Append (Text, "  " & Q ("entries") & ": [" & ASCII.LF);

      for Item of Result.Items loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_path") & ": " &
           Q (To_String (Item.Archive_Path)));
         Append (Text, ", " & Q ("decision") & ": " &
           Q (Decision_Name (Item.Decision)));
         Append (Text, ", " & Q ("kind") & ": " &
           Q (Kind_Name (Item.Kind)));
         Append (Text, ", " & Q ("compression_method") & ": " &
           Q (Method_Name (Item.Method)));
         Append (Text, ", " & Q ("crc32") & ": " &
           Decimal_32 (Item.Crc32));
         Append (Text, ", " & Q ("uncompressed_size") & ": " &
           Decimal (Item.Uncompressed_Size));
         Append (Text, ", " & Q ("compressed_size") & ": " &
           Decimal (Item.Compressed_Size));
         if Item.Kind = Plan_Symlink then
            Append (Text, ", " & Q ("link_target") & ": " &
              Q (To_String (Item.Link_Target)));
         end if;
         Append (Text, "}");
      end loop;

      Append (Text, ASCII.LF & "  ]" & ASCII.LF & "}" & ASCII.LF);
   end Build_JSON_Report;
end Backup.Incremental;
