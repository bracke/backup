with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Backup.Paths;
with Backup.Remote;
with Backup.Catalog_Syntax;
with Backup.Verify;
with Backup.Zip;

package body Backup.Catalog is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Backup.Verify.Verify_Status;
   use type Backup.Encryption.Envelope_Status;
   use type Backup.Encryption.Password_Source_Kind;

   Magic : constant String := "backup-catalog-v1";

   function Decimal (Value : Interfaces.Unsigned_64) return String is
      Image : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Decimal_32 (Value : Interfaces.Unsigned_32) return String is
   begin
      return Decimal (Interfaces.Unsigned_64 (Value));
   end Decimal_32;

   function Decimal_16 (Value : Interfaces.Unsigned_16) return String is
   begin
      return Decimal (Interfaces.Unsigned_64 (Value));
   end Decimal_16;

   function Boolean_Text (Value : Boolean) return String is
   begin
      return Backup.Catalog_Syntax.Boolean_Text (Value);
   end Boolean_Text;

   function Parse_Boolean (Text : String; Value : out Boolean) return Boolean is
   begin
      if Text = "true" then
         Value := True;
         return True;
      elsif Text = "false" then
         Value := False;
         return True;
      else
         Value := False;
         return False;
      end if;
   end Parse_Boolean;

   function Parse_U64 (Text : String; Value : out Interfaces.Unsigned_64)
      return Boolean
   is
      Parsed : constant Backup.Catalog_Syntax.U64_Parse :=
        Backup.Catalog_Syntax.Parse_U64_Text (Text);
   begin
      Value := Parsed.Value;
      return Parsed.Valid;
   end Parse_U64;

   function Parse_U32 (Text : String; Value : out Interfaces.Unsigned_32)
      return Boolean
   is
      Parsed : constant Backup.Catalog_Syntax.U32_Parse :=
        Backup.Catalog_Syntax.Parse_U32_Text (Text);
   begin
      Value := Parsed.Value;
      return Parsed.Valid;
   end Parse_U32;

   function Parse_U16 (Text : String; Value : out Interfaces.Unsigned_16)
      return Boolean
   is
      Parsed : constant Backup.Catalog_Syntax.U16_Parse :=
        Backup.Catalog_Syntax.Parse_U16_Text (Text);
   begin
      Value := Parsed.Value;
      return Parsed.Valid;
   end Parse_U16;

   function Percent_Hex (Value : Natural) return Character is
      Hex : constant array (Natural range 0 .. 15) of Character :=
        "0123456789ABCDEF";
   begin
      return Hex (Value);
   end Percent_Hex;

   function Escape (Text : String) return String is
      Result : Unbounded_String;
      Code   : Natural;
   begin
      for Ch of Text loop
         Code := Character'Pos (Ch);
         if Ch = '%' or else Ch = '|' or else Code < 32 then
            Append (Result, '%');
            Append (Result, Percent_Hex (Code / 16));
            Append (Result, Percent_Hex (Code mod 16));
         else
            Append (Result, Ch);
         end if;
      end loop;
      return To_String (Result);
   end Escape;

   function Hex_Value (Ch : Character; Value : out Natural) return Boolean is
   begin
      if Ch in '0' .. '9' then
         Value := Character'Pos (Ch) - Character'Pos ('0');
      elsif Ch in 'A' .. 'F' then
         Value := 10 + Character'Pos (Ch) - Character'Pos ('A');
      elsif Ch in 'a' .. 'f' then
         Value := 10 + Character'Pos (Ch) - Character'Pos ('a');
      else
         Value := 0;
         return False;
      end if;
      return True;
   end Hex_Value;

   function Unescape (Text : String; Value : out Unbounded_String)
      return Boolean
   is
      Index : Integer := Text'First;
      Hi    : Natural;
      Lo    : Natural;
   begin
      Value := Null_Unbounded_String;
      while Index <= Text'Last loop
         if Text (Index) = '%' then
            if Index + 2 > Text'Last
              or else not Hex_Value (Text (Index + 1), Hi)
              or else not Hex_Value (Text (Index + 2), Lo)
            then
               Value := Null_Unbounded_String;
               return False;
            end if;
            Append (Value, Character'Val (Hi * 16 + Lo));
            Index := Index + 3;
         else
            Append (Value, Text (Index));
            Index := Index + 1;
         end if;
      end loop;
      return True;
   end Unescape;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   function Split (Line : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      Start  : Integer := Line'First;
   begin
      for Index in Line'Range loop
         if Line (Index) = '|' then
            Result.Append (Line (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      Result.Append (Line (Start .. Line'Last));
      return Result;
   end Split;

   function Verification_Name (State : Verification_State) return String is
   begin
      return Backup.Catalog_Syntax.Verification_Name (State);
   end Verification_Name;

   function Parse_Verification (Text : String; State : out Verification_State)
      return Boolean
   is
      Parsed : constant Backup.Catalog_Syntax.Verification_Parse :=
        Backup.Catalog_Syntax.Parse_Verification (Text);
   begin
      State := Parsed.State;
      return Parsed.Valid;
   end Parse_Verification;

   function Encryption_Name (State : Encryption_State) return String is
   begin
      return Backup.Catalog_Syntax.Encryption_Name (State);
   end Encryption_Name;

   function Parse_Encryption (Text : String; State : out Encryption_State)
      return Boolean
   is
      Parsed : constant Backup.Catalog_Syntax.Encryption_Parse :=
        Backup.Catalog_Syntax.Parse_Encryption (Text);
   begin
      State := Parsed.State;
      return Parsed.Valid;
   end Parse_Encryption;

   function Kind_Name (Kind : Entry_Kind) return String is
   begin
      return Backup.Catalog_Syntax.Kind_Name (Kind);
   end Kind_Name;

   function Parse_Kind (Text : String; Kind : out Entry_Kind) return Boolean is
      Parsed : constant Backup.Catalog_Syntax.Kind_Parse :=
        Backup.Catalog_Syntax.Parse_Kind (Text);
   begin
      Kind := Parsed.Kind;
      return Parsed.Valid;
   end Parse_Kind;

   function Now_Text return String is
   begin
      return Ada.Calendar.Formatting.Image
        (Ada.Calendar.Clock, Include_Time_Fraction => False);
   end Now_Text;

   function File_Size (Path : String) return Interfaces.Unsigned_64 is
   begin
      return Interfaces.Unsigned_64 (Ada.Directories.Size (Path));
   exception
      when others =>
         return 0;
   end File_Size;

   function File_Modification_Text (Path : String) return String is
   begin
      return Ada.Calendar.Formatting.Image
        (Ada.Directories.Modification_Time (Path),
         Include_Time_Fraction => False);
   exception
      when others =>
         return "";
   end File_Modification_Text;

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

   procedure Delete_If_Exists (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Delete_If_Exists;

   function Archive_Id (Path : String) return String is
   begin
      return Backup.Remote.Archive_Id_For_Path (Path);
   end Archive_Id;

   function Status_Text (Status : Catalog_Status) return String is
   begin
      return Backup.Catalog_Syntax.Status_Text (Status);
   end Status_Text;

   function Contains_Case_Sensitive (Text : String; Pattern : String)
      return Boolean
   is
   begin
      if Pattern'Length = 0 then
         return True;
      end if;
      if Text'Length < Pattern'Length then
         return False;
      end if;
      for Index in Text'First .. Text'Last - Pattern'Length + 1 loop
         if Text (Index .. Index + Pattern'Length - 1) = Pattern then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Case_Sensitive;

   function Parse_Query
     (Text       : String;
      Parsed     : out Query;
      Diagnostic : out Unbounded_String)
      return Catalog_Status
   is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Text, ":");
      Key   : Unbounded_String;
      Value : Unbounded_String;
   begin
      Diagnostic := Null_Unbounded_String;
      Parsed := (Mode => Query_All, Text => Null_Unbounded_String);

      if Text'Length = 0 or else Text = "all" then
         return Catalog_Ok;
      end if;

      if Colon = 0 then
         Parsed := (Mode => Query_Contents, Text => To_Unbounded_String (Text));
         return Catalog_Ok;
      end if;

      Key := To_Unbounded_String (Text (Text'First .. Colon - 1));
      Value := To_Unbounded_String (Text (Colon + 1 .. Text'Last));
      if To_String (Key) = "archive" then
         Parsed.Mode := Query_Archive_Name;
      elsif To_String (Key) = "date" then
         Parsed.Mode := Query_Archive_Date;
      elsif To_String (Key) = "content" then
         Parsed.Mode := Query_Contents;
      elsif To_String (Key) = "source" then
         Parsed.Mode := Query_Source_Path;
      elsif To_String (Key) = "lineage" then
         Parsed.Mode := Query_Incremental_Lineage;
      elsif To_String (Key) = "remote" then
         Parsed.Mode := Query_Remote_Location;
      elsif To_String (Key) = "remote-verified" then
         Parsed.Mode := Query_Remote_Verified;
      elsif To_String (Key) = "verification" then
         Parsed.Mode := Query_Verification_State;
      elsif To_String (Key) = "manifest" then
         Parsed.Mode := Query_Manifest_State;
      elsif To_String (Key) = "encrypted" then
         Parsed.Mode := Query_Encryption_State;
      elsif To_String (Key) = "size" then
         Parsed.Mode := Query_Metadata_Size;
      elsif To_String (Key) = "crc32" then
         Parsed.Mode := Query_Metadata_Crc32;
      elsif To_String (Key) = "method" then
         Parsed.Mode := Query_Compression_Method;
      elsif To_String (Key) = "kind" then
         Parsed.Mode := Query_Entry_Kind;
      elsif To_String (Key) = "retention" then
         Parsed.Mode := Query_Retention_Group;
      else
         Diagnostic := To_Unbounded_String
           ("unsupported catalog query field: " & To_String (Key));
         return Catalog_Unsupported_Query;
      end if;

      Parsed.Text := Value;

      if Parsed.Mode = Query_Remote_Verified then
         declare
            Raw : constant String := To_String (Value);
         begin
            if not Backup.Catalog_Syntax.Is_Flexible_Boolean_Text (Raw) then
               Diagnostic := To_Unbounded_String
                 ("remote-verified query expects true, false, yes, no, 1, or 0");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Verification_State then
         declare
            Parsed_State : Verification_State;
         begin
            if not Parse_Verification (To_String (Value), Parsed_State) then
               Diagnostic := To_Unbounded_String
                 ("verification query expects unknown, trusted, failed, or stale");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Manifest_State then
         declare
            Raw : constant String := To_String (Value);
         begin
            if not Backup.Catalog_Syntax.Is_Manifest_Query_Text (Raw) then
               Diagnostic := To_Unbounded_String
                 ("manifest query expects present, trusted, untrusted, true, or false");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Encryption_State then
         declare
            Raw : constant String := To_String (Value);
         begin
            if not Backup.Catalog_Syntax.Is_Encryption_Query_Text (Raw) then
               Diagnostic := To_Unbounded_String
                 ("encrypted query expects true, false, yes, no, 1, 0, envelope, or none");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Metadata_Size then
         declare
            Raw : constant String := To_String (Value);
            Parsed_Size : Interfaces.Unsigned_64;
         begin
            if not Parse_U64 (Raw, Parsed_Size) then
               Diagnostic := To_Unbounded_String
                 ("size query expects an unsigned byte count");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Metadata_Crc32 then
         declare
            Raw : constant String := To_String (Value);
            Parsed_Crc32 : Interfaces.Unsigned_32;
         begin
            if not Parse_U32 (Raw, Parsed_Crc32) then
               Diagnostic := To_Unbounded_String
                 ("crc32 query expects an unsigned CRC32 value");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Entry_Kind then
         declare
            Parsed_Kind : Entry_Kind;
         begin
            if not Parse_Kind (To_String (Value), Parsed_Kind) then
               Diagnostic := To_Unbounded_String
                 ("kind query expects file, directory, symlink, or manifest");
               return Catalog_Unsupported_Query;
            end if;
         end;
      elsif Parsed.Mode = Query_Compression_Method then
         declare
            Raw : constant String := To_String (Value);
         begin
            if not Backup.Catalog_Syntax.Is_Method_Query_Text (Raw) then
               Diagnostic := To_Unbounded_String
                 ("method query expects store, deflate, bzip2, lzma, zstd, ppmd, or a ZIP method number");
               return Catalog_Unsupported_Query;
            end if;
         end;
      end if;

      return Catalog_Ok;
   end Parse_Query;

   function Archive_Less (Left : Archive_Record; Right : Archive_Record)
      return Boolean
   is
   begin
      return To_String (Left.Archive_Id) < To_String (Right.Archive_Id);
   end Archive_Less;

   package Archive_Sorting is new Archive_Vectors.Generic_Sorting
     ("<" => Archive_Less);

   function Entry_Less (Left : Entry_Record; Right : Entry_Record)
      return Boolean
   is
   begin
      if To_String (Left.Archive_Id) = To_String (Right.Archive_Id) then
         return To_String (Left.Archive_Path) < To_String (Right.Archive_Path);
      else
         return To_String (Left.Archive_Id) < To_String (Right.Archive_Id);
      end if;
   end Entry_Less;

   package Entry_Sorting is new Entry_Vectors.Generic_Sorting
     ("<" => Entry_Less);

   function Has_Archive (Catalog : Catalog_Data; Id : String) return Boolean is
   begin
      for Item of Catalog.Archives loop
         if To_String (Item.Archive_Id) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Has_Archive;

   function Has_Entry
     (Catalog      : Catalog_Data;
      Archive_Id   : String;
      Archive_Path : String)
      return Boolean
   is
   begin
      for Item of Catalog.Entries loop
         if To_String (Item.Archive_Id) = Archive_Id
           and then To_String (Item.Archive_Path) = Archive_Path
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Entry;

   procedure Remove_Archive (Catalog : in out Catalog_Data; Id : String) is
   begin
      if not Catalog.Archives.Is_Empty then
         declare
            Archive_Index : Positive := Catalog.Archives.First_Index;
         begin
            while Archive_Index <= Catalog.Archives.Last_Index loop
               if To_String
                 (Catalog.Archives.Element (Archive_Index).Archive_Id) = Id
               then
                  Catalog.Archives.Delete (Archive_Index);
               else
                  Archive_Index := Archive_Index + 1;
               end if;
               exit when Catalog.Archives.Is_Empty;
            end loop;
         end;
      end if;

      if not Catalog.Entries.Is_Empty then
         declare
            Entry_Index : Positive := Catalog.Entries.First_Index;
         begin
            while Entry_Index <= Catalog.Entries.Last_Index loop
               if To_String
                 (Catalog.Entries.Element (Entry_Index).Archive_Id) = Id
               then
                  Catalog.Entries.Delete (Entry_Index);
               else
                  Entry_Index := Entry_Index + 1;
               end if;
               exit when Catalog.Entries.Is_Empty;
            end loop;
         end;
      end if;
   end Remove_Archive;

   function Parse_Archive_Line
     (Fields     : String_Vectors.Vector;
      Item       : out Archive_Record;
      Diagnostic : out Unbounded_String)
      return Catalog_Status
   is
      Bool_Value : Boolean;
      U64        : Interfaces.Unsigned_64;
      U32        : Interfaces.Unsigned_32;
   begin
      if Fields.Length /= 14 and then Fields.Length /= 15 then
         Diagnostic := To_Unbounded_String ("malformed archive catalog record");
         return Catalog_Malformed;
      end if;

      if not Unescape (Fields.Element (2), Item.Archive_Id)
        or else not Unescape (Fields.Element (3), Item.Archive_Path)
        or else not Parse_U64 (Fields.Element (4), U64)
        or else not Parse_U32 (Fields.Element (5), U32)
        or else not Unescape (Fields.Element (6), Item.Indexed_Timestamp)
        or else not Parse_Encryption (Fields.Element (7), Item.Encryption)
        or else not Parse_Verification (Fields.Element (8), Item.Verification)
        or else not Parse_Boolean (Fields.Element (9), Bool_Value)
      then
         Diagnostic := To_Unbounded_String ("malformed archive catalog fields");
         return Catalog_Malformed;
      end if;
      Item.Archive_Size := U64;
      Item.Archive_Crc32 := U32;
      Item.Has_Manifest := Bool_Value;

      if not Parse_Boolean (Fields.Element (10), Bool_Value)
        or else not Unescape (Fields.Element (11), Item.Parent_Archive_Id)
        or else not Unescape (Fields.Element (12), Item.Retention_Group)
        or else not Unescape (Fields.Element (13), Item.Remote_URL)
        or else not Parse_Boolean (Fields.Element (14), Item.Remote_Verified)
      then
         Diagnostic := To_Unbounded_String ("malformed archive catalog fields");
         return Catalog_Malformed;
      end if;
      Item.Manifest_Trusted := Bool_Value;

      if Fields.Length = 15 then
         if not Unescape (Fields.Element (15), Item.Archive_Modification_Time) then
            Diagnostic := To_Unbounded_String ("malformed archive catalog fields");
            return Catalog_Malformed;
         end if;
      else
         Item.Archive_Modification_Time := Null_Unbounded_String;
      end if;
      return Catalog_Ok;
   end Parse_Archive_Line;

   function Parse_Entry_Line
     (Fields     : String_Vectors.Vector;
      Item       : out Entry_Record;
      Diagnostic : out Unbounded_String)
      return Catalog_Status
   is
      U64 : Interfaces.Unsigned_64;
      U32 : Interfaces.Unsigned_32;
      U16 : Interfaces.Unsigned_16;
   begin
      if Fields.Length /= 10
        and then Fields.Length /= 11
        and then Fields.Length /= 12
      then
         Diagnostic := To_Unbounded_String ("malformed entry catalog record");
         return Catalog_Malformed;
      end if;

      if not Unescape (Fields.Element (2), Item.Archive_Id)
        or else not Unescape (Fields.Element (3), Item.Archive_Path)
        or else not Unescape (Fields.Element (4), Item.Source_Path)
        or else not Parse_Kind (Fields.Element (5), Item.Kind)
        or else not Parse_U16 (Fields.Element (6), U16)
        or else not Parse_U32 (Fields.Element (7), U32)
        or else not Parse_U64 (Fields.Element (8), U64)
      then
         Diagnostic := To_Unbounded_String ("malformed entry catalog fields");
         return Catalog_Malformed;
      end if;
      Item.Method := U16;
      Item.Crc32 := U32;
      Item.Compressed_Size := U64;

      if not Parse_U64 (Fields.Element (9), U64) then
         Diagnostic := To_Unbounded_String ("malformed entry catalog fields");
         return Catalog_Malformed;
      end if;
      Item.Uncompressed_Size := U64;

      if not Parse_U64 (Fields.Element (10), U64) then
         Diagnostic := To_Unbounded_String ("malformed entry catalog fields");
         return Catalog_Malformed;
      end if;
      Item.Local_Offset := U64;

      if Fields.Length >= 11 then
         if not Unescape (Fields.Element (11), Item.Modification_Time) then
            Diagnostic := To_Unbounded_String ("malformed entry catalog fields");
            return Catalog_Malformed;
         end if;
      else
         Item.Modification_Time := Null_Unbounded_String;
      end if;

      if Fields.Length = 12 then
         if not Parse_Verification (Fields.Element (12), Item.Verification) then
            Diagnostic := To_Unbounded_String ("malformed entry catalog fields");
            return Catalog_Malformed;
         end if;
      else
         Item.Verification := Verification_Unknown;
      end if;
      return Catalog_Ok;
   end Parse_Entry_Line;

   function Load
     (Catalog_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      File   : Ada.Text_IO.File_Type;
      Buffer : String (1 .. 16384);
      Last   : Natural;
      Line_No : Natural := 0;
      Status : Catalog_Status;
   begin
      Catalog.Archives.Clear;
      Catalog.Entries.Clear;
      Diagnostic := Null_Unbounded_String;

      if not Ada.Directories.Exists (Catalog_Path) then
         if Ada.Directories.Exists (Catalog_Path & ".tmp") then
            Diagnostic := To_Unbounded_String
              ("interrupted catalog update found without final catalog; " &
               "recovery: inspect or remove temporary file: " &
               Catalog_Path & ".tmp");
            return Catalog_Malformed;
         end if;
         return Catalog_Ok;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Catalog_Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Buffer, Last);
         Line_No := Line_No + 1;
         declare
            Line : constant String := Buffer (Buffer'First .. Last);
            Fields : constant String_Vectors.Vector := Split (Line);
            Archive_Item : Archive_Record;
            Entry_Item   : Entry_Record;
         begin
            if Line_No = 1 then
               if Line /= Magic then
                  Ada.Text_IO.Close (File);
                  Diagnostic := To_Unbounded_String
                    ("catalog has invalid header: " & Catalog_Path);
                  return Catalog_Malformed;
               end if;
            elsif Line'Length = 0 then
               null;
            elsif Fields.Is_Empty then
               null;
            elsif Fields.First_Element = "A" then
               Status := Parse_Archive_Line (Fields, Archive_Item, Diagnostic);
               if Status /= Catalog_Ok then
                  Ada.Text_IO.Close (File);
                  return Status;
               end if;
               if Has_Archive (Catalog, To_String (Archive_Item.Archive_Id)) then
                  Ada.Text_IO.Close (File);
                  Diagnostic := To_Unbounded_String
                    ("duplicate archive id in catalog: " &
                     To_String (Archive_Item.Archive_Id));
                  return Catalog_Duplicate_Archive;
               end if;
               Catalog.Archives.Append (Archive_Item);
            elsif Fields.First_Element = "E" then
               Status := Parse_Entry_Line (Fields, Entry_Item, Diagnostic);
               if Status /= Catalog_Ok then
                  Ada.Text_IO.Close (File);
                  return Status;
               end if;
               if Has_Entry
                 (Catalog,
                  To_String (Entry_Item.Archive_Id),
                  To_String (Entry_Item.Archive_Path))
               then
                  Ada.Text_IO.Close (File);
                  Diagnostic := To_Unbounded_String
                    ("duplicate entry in catalog: " &
                     To_String (Entry_Item.Archive_Id) & ":" &
                     To_String (Entry_Item.Archive_Path));
                  return Catalog_Duplicate_Entry;
               end if;
               Catalog.Entries.Append (Entry_Item);
            else
               Ada.Text_IO.Close (File);
               Diagnostic := To_Unbounded_String
                 ("catalog line" & Natural'Image (Line_No) &
                  ": unknown record type");
               return Catalog_Malformed;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      if Line_No = 0 then
         Diagnostic := To_Unbounded_String
           ("catalog is empty and missing header: " & Catalog_Path);
         return Catalog_Malformed;
      end if;
      Archive_Sorting.Sort (Catalog.Archives);
      Entry_Sorting.Sort (Catalog.Entries);
      return Catalog_Ok;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Diagnostic := To_Unbounded_String
           ("could not read catalog file: " & Catalog_Path);
         return Catalog_Open_Failed;
   end Load;

   procedure Put_Archive_Line
     (File : Ada.Text_IO.File_Type;
      Item : Archive_Record)
   is
   begin
      Ada.Text_IO.Put_Line
        (File,
         "A|" & Escape (To_String (Item.Archive_Id)) &
         "|" & Escape (To_String (Item.Archive_Path)) &
         "|" & Decimal (Item.Archive_Size) &
         "|" & Decimal_32 (Item.Archive_Crc32) &
         "|" & Escape (To_String (Item.Indexed_Timestamp)) &
         "|" & Encryption_Name (Item.Encryption) &
         "|" & Verification_Name (Item.Verification) &
         "|" & Boolean_Text (Item.Has_Manifest) &
         "|" & Boolean_Text (Item.Manifest_Trusted) &
         "|" & Escape (To_String (Item.Parent_Archive_Id)) &
         "|" & Escape (To_String (Item.Retention_Group)) &
         "|" & Escape (To_String (Item.Remote_URL)) &
         "|" & Boolean_Text (Item.Remote_Verified) &
         "|" & Escape (To_String (Item.Archive_Modification_Time)));
   end Put_Archive_Line;

   procedure Put_Entry_Line
     (File : Ada.Text_IO.File_Type;
      Item : Entry_Record)
   is
   begin
      Ada.Text_IO.Put_Line
        (File,
         "E|" & Escape (To_String (Item.Archive_Id)) &
         "|" & Escape (To_String (Item.Archive_Path)) &
         "|" & Escape (To_String (Item.Source_Path)) &
         "|" & Kind_Name (Item.Kind) &
         "|" & Decimal_16 (Item.Method) &
         "|" & Decimal_32 (Item.Crc32) &
         "|" & Decimal (Item.Compressed_Size) &
         "|" & Decimal (Item.Uncompressed_Size) &
         "|" & Decimal (Item.Local_Offset) &
         "|" & Escape (To_String (Item.Modification_Time)) &
         "|" & Verification_Name (Item.Verification));
   end Put_Entry_Line;

   function Save
     (Catalog_Path : String;
      Catalog      : Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      File : Ada.Text_IO.File_Type;
      Temp_Path : constant String := Catalog_Path & ".tmp";
      Backup_Path : constant String := Catalog_Path & ".bak";
      Copy : Catalog_Data := Catalog;
   begin
      Diagnostic := Null_Unbounded_String;
      Archive_Sorting.Sort (Copy.Archives);
      Entry_Sorting.Sort (Copy.Entries);

      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Temp_Path);
      Ada.Text_IO.Put_Line (File, Magic);
      for Item of Copy.Archives loop
         Put_Archive_Line (File, Item);
      end loop;
      for Item of Copy.Entries loop
         Put_Entry_Line (File, Item);
      end loop;
      Ada.Text_IO.Close (File);

      if Ada.Directories.Exists (Backup_Path) then
         Ada.Directories.Delete_File (Backup_Path);
      end if;
      if Ada.Directories.Exists (Catalog_Path) then
         Ada.Directories.Rename (Catalog_Path, Backup_Path);
      end if;

      begin
         Ada.Directories.Rename (Temp_Path, Catalog_Path);
      exception
         when others =>
            if Ada.Directories.Exists (Backup_Path)
              and then not Ada.Directories.Exists (Catalog_Path)
            then
               Ada.Directories.Rename (Backup_Path, Catalog_Path);
            end if;
            raise;
      end;

      if Ada.Directories.Exists (Backup_Path) then
         Ada.Directories.Delete_File (Backup_Path);
      end if;
      return Catalog_Ok;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         begin
            if Ada.Directories.Exists (Temp_Path) then
               Ada.Directories.Delete_File (Temp_Path);
            end if;
            if Ada.Directories.Exists (Backup_Path)
              and then not Ada.Directories.Exists (Catalog_Path)
            then
               Ada.Directories.Rename (Backup_Path, Catalog_Path);
            end if;
         exception
            when others =>
               null;
         end;
         Diagnostic := To_Unbounded_String
           ("could not write catalog file: " & Catalog_Path);
         return Catalog_Write_Failed;
   end Save;

   function To_Catalog_Kind (Kind : Backup.Verify.Entry_Kind) return Entry_Kind is
   begin
      case Kind is
         when Backup.Verify.Entry_File =>
            return Entry_File;
         when Backup.Verify.Entry_Directory =>
            return Entry_Directory;
         when Backup.Verify.Entry_Symlink =>
            return Entry_Symlink;
         when Backup.Verify.Entry_Manifest =>
            return Entry_Manifest;
      end case;
   end To_Catalog_Kind;

   procedure Preserve_Run_Metadata
     (Catalog : Catalog_Data;
      Id      : String;
      Item    : in out Archive_Record)
   is
   begin
      for Existing of Catalog.Archives loop
         if To_String (Existing.Archive_Id) = Id then
            Item.Parent_Archive_Id := Existing.Parent_Archive_Id;
            Item.Retention_Group := Existing.Retention_Group;
            Item.Remote_URL := Existing.Remote_URL;
            Item.Remote_Verified := Existing.Remote_Verified;
            exit;
         end if;
      end loop;
   end Preserve_Run_Metadata;

   function Index_Verified_Archive
     (Catalog_Path      : String;
      Archive_Path      : String;
      Verification_Path : String;
      Encrypted         : Boolean;
      Catalog           : out Catalog_Data;
      Diagnostic        : out Unbounded_String)
      return Catalog_Status
   is
      Status : Catalog_Status;
      Verify_Report : Backup.Verify.Verification_Report;
      Verify_Status : Backup.Verify.Verify_Status;
      Id : constant String := Archive_Id (Archive_Path);
      Archive_Item : Archive_Record;
   begin
      Status := Load (Catalog_Path, Catalog, Diagnostic);
      if Status /= Catalog_Ok then
         return Status;
      end if;

      if not Ada.Directories.Exists (Archive_Path) then
         Diagnostic := To_Unbounded_String
           ("archive does not exist for catalog indexing: " & Archive_Path);
         return Catalog_Archive_Not_Found;
      elsif not Ada.Directories.Exists (Verification_Path) then
         Diagnostic := To_Unbounded_String
           ("decrypted archive does not exist for catalog indexing: " &
            Verification_Path);
         return Catalog_Archive_Not_Found;
      end if;

      Archive_Item.Archive_Id := To_Unbounded_String (Id);
      Archive_Item.Archive_Path := To_Unbounded_String (Archive_Path);
      Archive_Item.Archive_Size := File_Size (Archive_Path);
      Archive_Item.Archive_Crc32 := Backup.Zip.Crc32_Of_File
        (Backup.Paths.Normalize_File_System_Path (Archive_Path));
      Archive_Item.Indexed_Timestamp := To_Unbounded_String (Now_Text);
      Archive_Item.Archive_Modification_Time := To_Unbounded_String
        (File_Modification_Text (Archive_Path));
      if Encrypted then
         Archive_Item.Encryption := Encryption_Envelope_Present;
      else
         Archive_Item.Encryption := Encryption_Not_Encrypted;
      end if;
      Preserve_Run_Metadata (Catalog, Id, Archive_Item);
      Remove_Archive (Catalog, Id);

      Verify_Status := Backup.Verify.Verify_Archive
        (Verification_Path, Verify_Report, Diagnostic);
      if Verify_Status = Backup.Verify.Verify_Ok then
         Archive_Item.Verification := Verification_Trusted;
      else
         Archive_Item.Verification := Verification_Failed;
         Catalog.Archives.Append (Archive_Item);
         Status := Save (Catalog_Path, Catalog, Diagnostic);
         if Status = Catalog_Ok then
            return Catalog_Verification_Failed;
         else
            return Status;
         end if;
      end if;

      Archive_Item.Has_Manifest := Verify_Report.Has_Manifest;
      Archive_Item.Manifest_Trusted := Verify_Report.Manifest_OK;
      Catalog.Archives.Append (Archive_Item);

      for Verified of Verify_Report.Entries loop
         Catalog.Entries.Append
           (Entry_Record'(Archive_Id        => To_Unbounded_String (Id),
             Archive_Path      => Verified.Archive_Path,
             Source_Path       => Null_Unbounded_String,
             Kind              => To_Catalog_Kind (Verified.Kind),
             Method            => Verified.Method,
             Crc32             => Verified.Crc32,
             Compressed_Size   => Verified.Compressed_Size,
             Uncompressed_Size => Verified.Uncompressed_Size,
             Local_Offset      => Verified.Local_Offset,
             Modification_Time => Null_Unbounded_String,
             Verification      => Verification_Trusted));
      end loop;

      pragma Assert (Has_Archive (Catalog, Id),
                     "indexed catalog contains archive");
      return Save (Catalog_Path, Catalog, Diagnostic);
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("catalog indexing failed for archive: " & Archive_Path);
         return Catalog_Open_Failed;
   end Index_Verified_Archive;

   function Index_Archive
     (Catalog_Path : String;
      Archive_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      Status : Catalog_Status;
      Id : constant String := Archive_Id (Archive_Path);
      Archive_Item : Archive_Record;
   begin
      if not Backup.Encryption.Is_Encrypted (Archive_Path) then
         return Index_Verified_Archive
           (Catalog_Path      => Catalog_Path,
            Archive_Path      => Archive_Path,
            Verification_Path => Archive_Path,
            Encrypted         => False,
            Catalog           => Catalog,
            Diagnostic        => Diagnostic);
      end if;

      Status := Load (Catalog_Path, Catalog, Diagnostic);
      if Status /= Catalog_Ok then
         return Status;
      end if;

      if not Ada.Directories.Exists (Archive_Path) then
         Diagnostic := To_Unbounded_String
           ("archive does not exist for catalog indexing: " & Archive_Path);
         return Catalog_Archive_Not_Found;
      end if;

      Archive_Item.Archive_Id := To_Unbounded_String (Id);
      Archive_Item.Archive_Path := To_Unbounded_String (Archive_Path);
      Archive_Item.Archive_Size := File_Size (Archive_Path);
      Archive_Item.Archive_Crc32 := Backup.Zip.Crc32_Of_File
        (Backup.Paths.Normalize_File_System_Path (Archive_Path));
      Archive_Item.Indexed_Timestamp := To_Unbounded_String (Now_Text);
      Archive_Item.Archive_Modification_Time := To_Unbounded_String
        (File_Modification_Text (Archive_Path));
      Archive_Item.Encryption := Encryption_Envelope_Present;
      Archive_Item.Verification := Verification_Unknown;
      Preserve_Run_Metadata (Catalog, Id, Archive_Item);
      Remove_Archive (Catalog, Id);
      Catalog.Archives.Append (Archive_Item);
      pragma Assert
        (Catalog.Entries.Is_Empty
           or else Catalog.Entries.Last_Element.Archive_Id /= Archive_Item.Archive_Id,
         "encrypted catalog indexing without a password keeps entry metadata hidden");
      return Save (Catalog_Path, Catalog, Diagnostic);
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("catalog indexing failed for archive: " & Archive_Path);
         return Catalog_Open_Failed;
   end Index_Archive;

   function Index_Archive
     (Catalog_Path : String;
      Archive_Path : String;
      Password     : Backup.Encryption.Password_Source;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      Work_Path : Unbounded_String;
      Envelope_Status : Backup.Encryption.Envelope_Status;
      Status : Catalog_Status;
   begin
      if not Backup.Encryption.Is_Encrypted (Archive_Path)
        or else Password.Kind = Backup.Encryption.Password_None
      then
         return Index_Archive
           (Catalog_Path, Archive_Path, Catalog, Diagnostic);
      end if;

      Work_Path := To_Unbounded_String
        (Unique_Temp_Path (Archive_Path, ".catalog-decrypted.zip"));
      Envelope_Status := Backup.Encryption.Decrypt_File
        (Archive_Path, To_String (Work_Path), Password, Diagnostic);
      if Envelope_Status /= Backup.Encryption.Envelope_Ok then
         Delete_If_Exists (To_String (Work_Path));
         if Length (Diagnostic) = 0 then
            Diagnostic := To_Unbounded_String
              (Backup.Encryption.Status_Text (Envelope_Status));
         end if;
         case Envelope_Status is
            when Backup.Encryption.Envelope_Open_Failed
               | Backup.Encryption.Envelope_Read_Failed =>
               return Catalog_Open_Failed;
            when Backup.Encryption.Envelope_Write_Failed =>
               return Catalog_Write_Failed;
            when others =>
               return Catalog_Verification_Failed;
         end case;
      end if;

      begin
         Status := Index_Verified_Archive
           (Catalog_Path      => Catalog_Path,
            Archive_Path      => Archive_Path,
            Verification_Path => To_String (Work_Path),
            Encrypted         => True,
            Catalog           => Catalog,
            Diagnostic        => Diagnostic);
      exception
         when others =>
            Delete_If_Exists (To_String (Work_Path));
            raise;
      end;
      Delete_If_Exists (To_String (Work_Path));
      return Status;
   end Index_Archive;

   function Archive_Matches (Item : Archive_Record; Filter : Query) return Boolean is
      Value : constant String := To_String (Filter.Text);
   begin
      case Filter.Mode is
         when Query_All | Query_Archives_Only =>
            return True;
         when Query_Archive_Name =>
            return Contains_Case_Sensitive (To_String (Item.Archive_Id), Value)
              or else Contains_Case_Sensitive (To_String (Item.Archive_Path), Value);
         when Query_Archive_Date =>
            return Contains_Case_Sensitive
              (To_String (Item.Indexed_Timestamp), Value)
              or else Contains_Case_Sensitive
                (To_String (Item.Archive_Modification_Time), Value);
         when Query_Incremental_Lineage =>
            return Contains_Case_Sensitive
              (To_String (Item.Parent_Archive_Id), Value)
              or else Contains_Case_Sensitive (To_String (Item.Archive_Id), Value);
         when Query_Remote_Location =>
            return Contains_Case_Sensitive (To_String (Item.Remote_URL), Value);
         when Query_Remote_Verified =>
            return Boolean_Text (Item.Remote_Verified) = Value
              or else (Item.Remote_Verified and then (Value = "yes" or else Value = "1"))
              or else ((not Item.Remote_Verified) and then (Value = "no" or else Value = "0"));
         when Query_Verification_State =>
            return Verification_Name (Item.Verification) = Value;
         when Query_Manifest_State =>
            return (Value = "present" and then Item.Has_Manifest)
              or else (Value = "trusted" and then Item.Manifest_Trusted)
              or else (Value = "untrusted"
                       and then Item.Has_Manifest
                       and then not Item.Manifest_Trusted)
              or else (Value = "true" and then Item.Has_Manifest)
              or else (Value = "false" and then not Item.Has_Manifest);
         when Query_Encryption_State =>
            return (Item.Encryption = Encryption_Envelope_Present
                    and then (Value = "true" or else Value = "yes"
                              or else Value = "1" or else Value = "envelope"))
              or else (Item.Encryption = Encryption_Not_Encrypted
                       and then (Value = "false" or else Value = "no"
                                 or else Value = "0" or else Value = "none"));
         when Query_Metadata_Size =>
            return Decimal (Item.Archive_Size) = Value;
         when Query_Metadata_Crc32 =>
            return Decimal_32 (Item.Archive_Crc32) = Value;
         when Query_Retention_Group =>
            return Contains_Case_Sensitive
              (To_String (Item.Retention_Group), Value);
         when Query_Contents | Query_Source_Path
            | Query_Compression_Method | Query_Entry_Kind =>
            return False;
      end case;
   end Archive_Matches;

   function Entry_Matches
     (Item   : Entry_Record;
      Filter : Query)
      return Boolean
   is
      Value : constant String := To_String (Filter.Text);
      Method_Text : constant String :=
        (if Item.Method = 0 then
            "store"
         elsif Item.Method = 8 then
            "deflate"
         elsif Item.Method = 12 then
            "bzip2"
         elsif Item.Method = 14 then
            "lzma"
         elsif Item.Method = 20 or else Item.Method = 93 then
            "zstd"
         elsif Item.Method = 98 then
            "ppmd"
         else Decimal_16 (Item.Method));
   begin
      case Filter.Mode is
         when Query_All =>
            return True;
         when Query_Archives_Only =>
            return False;
         when Query_Contents =>
            return Contains_Case_Sensitive (To_String (Item.Archive_Path), Value);
         when Query_Source_Path =>
            return Contains_Case_Sensitive (To_String (Item.Source_Path), Value);
         when Query_Verification_State =>
            return Verification_Name (Item.Verification) = Value;
         when Query_Metadata_Size =>
            return Decimal (Item.Uncompressed_Size) = Value
              or else Decimal (Item.Compressed_Size) = Value;
         when Query_Metadata_Crc32 =>
            return Decimal_32 (Item.Crc32) = Value;
         when Query_Compression_Method =>
            return Method_Text = Value
              or else (Item.Method = 0 and then Value = "stored")
              or else (Item.Method = 8 and then Value = "deflated")
              or else Decimal_16 (Item.Method) = Value;
         when Query_Entry_Kind =>
            return Kind_Name (Item.Kind) = Value;
         when others =>
            return False;
      end case;
   end Entry_Matches;

   function Query_Catalog
     (Catalog    : Catalog_Data;
      Filter     : Query;
      Result     : out Query_Result;
      Diagnostic : out Unbounded_String)
      return Catalog_Status
   is
   begin
      Result.Archives.Clear;
      Result.Entries.Clear;
      Diagnostic := Null_Unbounded_String;

      for Archive_Item of Catalog.Archives loop
         if Archive_Matches (Archive_Item, Filter) then
            Result.Archives.Append (Archive_Item);
         end if;
      end loop;

      for Entry_Item of Catalog.Entries loop
         if Entry_Matches (Entry_Item, Filter) then
            Result.Entries.Append (Entry_Item);
         end if;
      end loop;

      Archive_Sorting.Sort (Result.Archives);
      Entry_Sorting.Sort (Result.Entries);
      return Catalog_Ok;
   end Query_Catalog;



   function Remove_Indexed_Archive
     (Catalog_Path : String;
      Archive_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      Status : Catalog_Status;
      Id     : Unbounded_String := To_Unbounded_String (Archive_Id (Archive_Path));
   begin
      Status := Load (Catalog_Path, Catalog, Diagnostic);
      if Status /= Catalog_Ok then
         return Status;
      end if;

      if not Has_Archive (Catalog, To_String (Id))
        and then Has_Archive (Catalog, Archive_Path)
      then
         Id := To_Unbounded_String (Archive_Path);
      end if;

      if not Has_Archive (Catalog, To_String (Id)) then
         Diagnostic := To_Unbounded_String
           ("archive is not indexed in catalog: " & Archive_Path);
         return Catalog_Archive_Not_Found;
      end if;

      Remove_Archive (Catalog, To_String (Id));
      pragma Assert (not Has_Archive (Catalog, To_String (Id)),
                     "removed archive id is absent from catalog");
      return Save (Catalog_Path, Catalog, Diagnostic);
   end Remove_Indexed_Archive;

   function Attach_Run_Metadata
     (Catalog_Path      : String;
      Archive_Path      : String;
      Scanned_Entries   : Backup.Scanner.Entry_Vectors.Vector;
      Parent_Archive_Id : String;
      Retention_Group   : String;
      Remote_URL        : String;
      Remote_Verified   : Boolean;
      Catalog           : out Catalog_Data;
      Diagnostic        : out Unbounded_String)
      return Catalog_Status
   is
      Status : Catalog_Status;
      Id     : constant String := Archive_Id (Archive_Path);
      Found  : Boolean := False;
   begin
      Status := Load (Catalog_Path, Catalog, Diagnostic);
      if Status /= Catalog_Ok then
         return Status;
      end if;

      if not Catalog.Archives.Is_Empty then
         for Archive_Index in Catalog.Archives.First_Index
           .. Catalog.Archives.Last_Index
         loop
            declare
               Item : Archive_Record := Catalog.Archives.Element (Archive_Index);
            begin
               if To_String (Item.Archive_Id) = Id then
                  Item.Parent_Archive_Id := To_Unbounded_String (Parent_Archive_Id);
                  Item.Retention_Group := To_Unbounded_String (Retention_Group);
                  Item.Remote_URL := To_Unbounded_String (Remote_URL);
                  Item.Remote_Verified := Remote_Verified;
                  Catalog.Archives.Replace_Element (Archive_Index, Item);
                  Found := True;
               end if;
            end;
         end loop;
      end if;

      if not Found then
         Diagnostic := To_Unbounded_String
           ("cannot attach run metadata; archive is not indexed: " &
            Archive_Path);
         return Catalog_Archive_Not_Found;
      end if;

      if not Scanned_Entries.Is_Empty and then not Catalog.Entries.Is_Empty then
         for Entry_Index in Catalog.Entries.First_Index
           .. Catalog.Entries.Last_Index
         loop
            declare
               Catalog_Entry : Entry_Record :=
                 Catalog.Entries.Element (Entry_Index);
            begin
               if To_String (Catalog_Entry.Archive_Id) = Id then
                  for Scanned of Scanned_Entries loop
                     if To_String (Catalog_Entry.Archive_Path) =
                       Backup.Paths.To_String (Scanned.Archive_Path)
                     then
                        Catalog_Entry.Source_Path := To_Unbounded_String
                          (Backup.Paths.To_String (Scanned.Source_Path));
                        if Scanned.Has_Modification_Time then
                           Catalog_Entry.Modification_Time := To_Unbounded_String
                             (Ada.Calendar.Formatting.Image
                                (Scanned.Modification_Time,
                                 Include_Time_Fraction => False));
                        else
                           Catalog_Entry.Modification_Time := Null_Unbounded_String;
                        end if;
                        if Catalog_Entry.Verification = Verification_Unknown then
                           Catalog_Entry.Verification := Verification_Trusted;
                        end if;
                        Catalog.Entries.Replace_Element
                          (Entry_Index, Catalog_Entry);
                        exit;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end if;

      pragma Assert (Has_Archive (Catalog, Id),
                     "catalog run metadata keeps archive record");
      return Save (Catalog_Path, Catalog, Diagnostic);
   exception
      when Constraint_Error =>
         Diagnostic := To_Unbounded_String
           ("cannot attach run metadata to an empty catalog: " & Archive_Path);
         return Catalog_Archive_Not_Found;
      when others =>
         Diagnostic := To_Unbounded_String
           ("failed to attach run metadata for catalog archive: " &
            Archive_Path);
         return Catalog_Write_Failed;
   end Attach_Run_Metadata;


   function Record_Verification_Result
     (Catalog_Path : String;
      Archive_Path : String;
      Trusted      : Boolean;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      Status : Catalog_Status;
      Id     : constant String := Archive_Id (Archive_Path);
      Found  : Boolean := False;
   begin
      Status := Load (Catalog_Path, Catalog, Diagnostic);
      if Status /= Catalog_Ok then
         return Status;
      end if;

      if not Ada.Directories.Exists (Archive_Path) then
         Diagnostic := To_Unbounded_String
           ("archive does not exist for catalog verification update: " &
            Archive_Path);
         return Catalog_Archive_Not_Found;
      end if;

      if not Catalog.Archives.Is_Empty then
         for Archive_Index in Catalog.Archives.First_Index
           .. Catalog.Archives.Last_Index
         loop
            declare
               Item : Archive_Record := Catalog.Archives.Element (Archive_Index);
            begin
               if To_String (Item.Archive_Id) = Id then
                  Item.Archive_Path := To_Unbounded_String (Archive_Path);
                  Item.Archive_Size := File_Size (Archive_Path);
                  Item.Archive_Crc32 := Backup.Zip.Crc32_Of_File
                    (Backup.Paths.Normalize_File_System_Path (Archive_Path));
                  Item.Archive_Modification_Time := To_Unbounded_String
                    (File_Modification_Text (Archive_Path));
                  Item.Indexed_Timestamp := To_Unbounded_String (Now_Text);
                  if Backup.Encryption.Is_Encrypted (Archive_Path) then
                     Item.Encryption := Encryption_Envelope_Present;
                  end if;
                  if Trusted then
                     Item.Verification := Verification_Trusted;
                  else
                     Item.Verification := Verification_Failed;
                  end if;
                  Catalog.Archives.Replace_Element (Archive_Index, Item);
                  Found := True;
               end if;
            end;
         end loop;
      end if;

      if not Found then
         Catalog.Archives.Append
           (Archive_Record'(Archive_Id                 => To_Unbounded_String (Id),
             Archive_Path               => To_Unbounded_String (Archive_Path),
             Archive_Size               => File_Size (Archive_Path),
             Archive_Crc32              => Backup.Zip.Crc32_Of_File
               (Backup.Paths.Normalize_File_System_Path (Archive_Path)),
             Indexed_Timestamp          => To_Unbounded_String (Now_Text),
             Archive_Modification_Time  => To_Unbounded_String
               (File_Modification_Text (Archive_Path)),
             Encryption                 =>
               (if Backup.Encryption.Is_Encrypted (Archive_Path) then
                   Encryption_Envelope_Present
                else
                   Encryption_Not_Encrypted),
             Verification               =>
               (if Trusted then
                   Verification_Trusted
                else
                   Verification_Failed),
             Has_Manifest               => False,
             Manifest_Trusted           => False,
             Parent_Archive_Id          => Null_Unbounded_String,
             Retention_Group            => Null_Unbounded_String,
             Remote_URL                 => Null_Unbounded_String,
             Remote_Verified            => False));
      end if;

      pragma Assert (Has_Archive (Catalog, Id),
                     "verification update records archive");
      return Save (Catalog_Path, Catalog, Diagnostic);
   exception
      when others =>
         Diagnostic := To_Unbounded_String
           ("failed to update catalog verification state for archive: " &
            Archive_Path);
         return Catalog_Write_Failed;
   end Record_Verification_Result;

   function Verify_Catalog
     (Catalog_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Unbounded_String)
      return Catalog_Status
   is
      Status : Catalog_Status;
   begin
      if not Ada.Directories.Exists (Catalog_Path) then
         if Ada.Directories.Exists (Catalog_Path & ".tmp") then
            Status := Load (Catalog_Path, Catalog, Diagnostic);
            return Status;
         end if;

         Catalog.Archives.Clear;
         Catalog.Entries.Clear;
         Diagnostic := To_Unbounded_String
           ("catalog file does not exist: " & Catalog_Path);
         return Catalog_Open_Failed;
      end if;

      Status := Load (Catalog_Path, Catalog, Diagnostic);
      if Status /= Catalog_Ok then
         return Status;
      end if;

      if not Catalog.Archives.Is_Empty then
         for Left_Index in Catalog.Archives.First_Index
           .. Catalog.Archives.Last_Index
         loop
            declare
               Left : constant Archive_Record :=
                 Catalog.Archives.Element (Left_Index);
            begin
               if not Ada.Directories.Exists (To_String (Left.Archive_Path)) then
                  Diagnostic := To_Unbounded_String
                    ("catalog archive is missing: " &
                     To_String (Left.Archive_Path));
                  return Catalog_Archive_Not_Found;
               end if;

               if File_Size (To_String (Left.Archive_Path)) /= Left.Archive_Size
                 or else Backup.Zip.Crc32_Of_File
                   (Backup.Paths.Normalize_File_System_Path
                      (To_String (Left.Archive_Path))) /= Left.Archive_Crc32
               then
                  Diagnostic := To_Unbounded_String
                    ("catalog metadata is stale for archive: " &
                     To_String (Left.Archive_Path));
                  return Catalog_Stale_Metadata;
               end if;

               if Length (Left.Parent_Archive_Id) > 0
                 and then To_String (Left.Parent_Archive_Id) =
                   To_String (Left.Archive_Id)
               then
                  Diagnostic := To_Unbounded_String
                    ("incremental archive cannot name itself as parent: " &
                     To_String (Left.Archive_Id));
                  return Catalog_Malformed;
               end if;

               if Length (Left.Parent_Archive_Id) > 0
                 and then not Has_Archive
                   (Catalog, To_String (Left.Parent_Archive_Id))
               then
                  Diagnostic := To_Unbounded_String
                    ("incremental parent archive is missing from catalog: " &
                     To_String (Left.Parent_Archive_Id));
                  return Catalog_Malformed;
               end if;

               if Left_Index < Catalog.Archives.Last_Index then
                  for Right_Index in Positive'Succ (Left_Index)
                    .. Catalog.Archives.Last_Index
                  loop
                     if To_String (Left.Archive_Id) =
                       To_String
                         (Catalog.Archives.Element (Right_Index).Archive_Id)
                     then
                        Diagnostic := To_Unbounded_String
                          ("duplicate archive id in catalog: " &
                           To_String (Left.Archive_Id));
                        return Catalog_Duplicate_Archive;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end if;

      if not Catalog.Entries.Is_Empty then
         for Left_Index in Catalog.Entries.First_Index
           .. Catalog.Entries.Last_Index
         loop
            declare
               Left : constant Entry_Record := Catalog.Entries.Element (Left_Index);
            begin
               if not Has_Archive (Catalog, To_String (Left.Archive_Id)) then
                  Diagnostic := To_Unbounded_String
                    ("entry references missing archive id: " &
                     To_String (Left.Archive_Id));
                  return Catalog_Malformed;
               end if;

               for Archive_Item of Catalog.Archives loop
                  if To_String (Archive_Item.Archive_Id) =
                    To_String (Left.Archive_Id)
                    and then Archive_Item.Verification = Verification_Trusted
                    and then Left.Verification /= Verification_Trusted
                  then
                     Diagnostic := To_Unbounded_String
                       ("trusted archive has untrusted entry metadata: " &
                        To_String (Left.Archive_Id) & ":" &
                        To_String (Left.Archive_Path));
                     return Catalog_Stale_Metadata;
                  end if;
               end loop;

               if Left_Index < Catalog.Entries.Last_Index then
                  for Right_Index in Positive'Succ (Left_Index)
                    .. Catalog.Entries.Last_Index
                  loop
                     declare
                        Right : constant Entry_Record :=
                          Catalog.Entries.Element (Right_Index);
                     begin
                        if To_String (Left.Archive_Id) =
                            To_String (Right.Archive_Id)
                          and then To_String (Left.Archive_Path) =
                            To_String (Right.Archive_Path)
                        then
                           Diagnostic := To_Unbounded_String
                             ("duplicate entry in catalog: " &
                              To_String (Left.Archive_Id) & ":" &
                              To_String (Left.Archive_Path));
                           return Catalog_Duplicate_Entry;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end if;

      Diagnostic := To_Unbounded_String
        ("catalog ok: archives=" &
         Ada.Containers.Count_Type'Image (Catalog.Archives.Length) &
         " entries=" &
         Ada.Containers.Count_Type'Image (Catalog.Entries.Length));
      if Ada.Directories.Exists (Catalog_Path & ".tmp") then
         Append (Diagnostic,
                 "; ignored interrupted update temp file; recovery: remove " &
                 Catalog_Path & ".tmp after confirming the final catalog");
      end if;
      if Ada.Directories.Exists (Catalog_Path & ".bak") then
         Append (Diagnostic,
                 "; ignored prior catalog backup file; recovery: remove " &
                 Catalog_Path & ".bak after confirming the final catalog");
      end if;
      Append (Diagnostic, ASCII.LF);
      return Catalog_Ok;
   end Verify_Catalog;

   procedure Append_Escape_JSON
     (Result : in out Unbounded_String;
      Code   : Character)
   is
   begin
      Append (Result, '\');
      Append (Result, Code);
   end Append_Escape_JSON;

   function Json_Escape (Text : String) return String is
      Result : Unbounded_String;
      Hex    : constant array (Natural range 0 .. 15) of Character :=
        "0123456789abcdef";
      Code   : Natural;
   begin
      for Ch of Text loop
         case Ch is
            when '"' =>
               Append_Escape_JSON (Result, '"');
            when '\' =>
               Append_Escape_JSON (Result, '\');
            when ASCII.BS =>
               Append_Escape_JSON (Result, 'b');
            when ASCII.HT =>
               Append_Escape_JSON (Result, 't');
            when ASCII.LF =>
               Append_Escape_JSON (Result, 'n');
            when ASCII.FF =>
               Append_Escape_JSON (Result, 'f');
            when ASCII.CR =>
               Append_Escape_JSON (Result, 'r');
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

   procedure Build_JSON_Report
     (Result : Query_Result;
      Text   : out Unbounded_String)
   is
      First : Boolean := True;
   begin
      Text := To_Unbounded_String ("{" & ASCII.LF);
      Append (Text, "  " & Q ("format") & ": " &
        Q ("backup-catalog-query-v1") & "," & ASCII.LF);
      Append (Text, "  " & Q ("archives") & ": [" & ASCII.LF);
      for Item of Result.Archives loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_id") & ": " &
           Q (To_String (Item.Archive_Id)));
         Append (Text, ", " & Q ("archive_path") & ": " &
           Q (To_String (Item.Archive_Path)));
         Append (Text, ", " & Q ("size") & ": " &
           Decimal (Item.Archive_Size));
         Append (Text, ", " & Q ("crc32") & ": " &
           Decimal_32 (Item.Archive_Crc32));
         Append (Text, ", " & Q ("encrypted") & ": ");
         Append (Text, Boolean_Text (Item.Encryption = Encryption_Envelope_Present));
         Append (Text, ", " & Q ("verification") & ": " &
           Q (Verification_Name (Item.Verification)));
         Append (Text, ", " & Q ("has_manifest") & ": " &
           Boolean_Text (Item.Has_Manifest));
         Append (Text, ", " & Q ("indexed_timestamp") & ": " &
           Q (To_String (Item.Indexed_Timestamp)));
         Append (Text, ", " & Q ("archive_modification_time") & ": " &
           Q (To_String (Item.Archive_Modification_Time)));
         Append (Text, ", " & Q ("manifest_trusted") & ": " &
           Boolean_Text (Item.Manifest_Trusted));
         Append (Text, ", " & Q ("parent_archive_id") & ": " &
           Q (To_String (Item.Parent_Archive_Id)));
         Append (Text, ", " & Q ("remote_url") & ": " &
           Q (To_String (Item.Remote_URL)));
         Append (Text, ", " & Q ("remote_verified") & ": " &
           Boolean_Text (Item.Remote_Verified));
         Append (Text, ", " & Q ("retention_group") & ": " &
           Q (To_String (Item.Retention_Group)) & "}");
      end loop;
      Append (Text, ASCII.LF & "  ]," & ASCII.LF);
      Append (Text, "  " & Q ("entries") & ": [" & ASCII.LF);
      First := True;
      for Item of Result.Entries loop
         if First then
            First := False;
         else
            Append (Text, "," & ASCII.LF);
         end if;
         Append (Text, "    {" & Q ("archive_id") & ": " &
           Q (To_String (Item.Archive_Id)));
         Append (Text, ", " & Q ("archive_path") & ": " &
           Q (To_String (Item.Archive_Path)));
         Append (Text, ", " & Q ("source_path") & ": " &
           Q (To_String (Item.Source_Path)));
         Append (Text, ", " & Q ("kind") & ": " & Q (Kind_Name (Item.Kind)));
         Append (Text, ", " & Q ("method") & ": " & Decimal_16 (Item.Method));
         Append (Text, ", " & Q ("crc32") & ": " & Decimal_32 (Item.Crc32));
         Append (Text, ", " & Q ("compressed_size") & ": " &
           Decimal (Item.Compressed_Size));
         Append (Text, ", " & Q ("uncompressed_size") & ": " &
           Decimal (Item.Uncompressed_Size));
         Append (Text, ", " & Q ("local_offset") & ": " &
           Decimal (Item.Local_Offset));
         Append (Text, ", " & Q ("modification_time") & ": " &
           Q (To_String (Item.Modification_Time)));
         Append (Text, ", " & Q ("verification") & ": " &
           Q (Verification_Name (Item.Verification)) & "}");
      end loop;
      Append (Text, ASCII.LF & "  ]" & ASCII.LF & "}" & ASCII.LF);
   end Build_JSON_Report;

   procedure Build_Human_Report
     (Result : Query_Result;
      Text   : out Unbounded_String)
   is
   begin
      Text := To_Unbounded_String ("catalog query" & ASCII.LF);
      Append (Text, "archives:" & ASCII.LF);
      for Item of Result.Archives loop
         Append (Text, "  archive ");
         Append (Text, To_String (Item.Archive_Id));
         Append (Text, " path=");
         Append (Text, To_String (Item.Archive_Path));
         Append (Text, " verification=");
         Append (Text, Verification_Name (Item.Verification));
         if Length (Item.Archive_Modification_Time) > 0 then
            Append (Text, " archive-modified=");
            Append (Text, To_String (Item.Archive_Modification_Time));
         end if;
         if Item.Encryption = Encryption_Envelope_Present then
            Append (Text, " encrypted=yes");
         end if;
         if Length (Item.Remote_URL) > 0 then
            Append (Text, " remote=");
            Append (Text, To_String (Item.Remote_URL));
         end if;
         Append (Text, ASCII.LF);
      end loop;
      Append (Text, "entries:" & ASCII.LF);
      for Item of Result.Entries loop
         Append (Text, "  entry ");
         Append (Text, To_String (Item.Archive_Id));
         Append (Text, ":");
         Append (Text, To_String (Item.Archive_Path));
         Append (Text, " kind=");
         Append (Text, Kind_Name (Item.Kind));
         Append (Text, " method=");
         Append (Text, Decimal_16 (Item.Method));
         Append (Text, " size=");
         Append (Text, Decimal (Item.Uncompressed_Size));
         if Length (Item.Modification_Time) > 0 then
            Append (Text, " modified=");
            Append (Text, To_String (Item.Modification_Time));
         end if;
         Append (Text, " verification=");
         Append (Text, Verification_Name (Item.Verification));
         Append (Text, ASCII.LF);
      end loop;
   end Build_Human_Report;
end Backup.Catalog;
