with Ada.Calendar;
with Ada.Command_Line;
with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Project_Tools.Files;

with Backup.Catalog;
with Backup.Catalog_Syntax;
with Backup.CLI;
with Backup.Encryption;
with Backup.Paths;
with Backup.Remote;
with Backup.Scanner;
with Backup.Zip;

procedure Backup_Catalog_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Backup.Catalog.Catalog_Status;
   use type Backup.Catalog.Encryption_State;
   use type Backup.Catalog.Entry_Kind;
   use type Backup.Catalog.Verification_State;
   use type Backup.Encryption.Envelope_Status;
   use type Backup.Paths.Validation_Status;
   use type Backup.Zip.Write_Result;

   Root       : constant String := "tmp_backup_catalog_tests";
   Src_Dir    : constant String := Root & "/src";
   Catalog_Path : constant String := Root & "/catalog.db";
   Archive_Path : constant String := Root & "/archive.zip";
   Encrypted_Path : constant String := Root & "/encrypted.backup";
   Password_Path  : constant String := Root & "/password.txt";
   Temp_Only_Catalog : constant String := Root & "/interrupted.catalog";
   Broken_Trust_Catalog : constant String := Root & "/broken-trust.catalog";
   Duplicate_Entry_Catalog : constant String := Root & "/duplicate-entry.catalog";
   Missing_Parent_Catalog : constant String := Root & "/missing-parent.catalog";
   Missing_Catalog : constant String := Root & "/missing.catalog";
   Failures   : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Name);
      end if;
   end Check;

   procedure Ensure_Directory (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Path (Path);
      end if;
   end Ensure_Directory;

   procedure Write_File (Path : String; Text : String) is
   begin
      Project_Tools.Files.Write_Text_File (Path, Text);
   end Write_File;

   procedure Append_File (Path : String; Text : String) is
   begin
      Project_Tools.Files.Append_Text_File (Path, Text);
   end Append_File;

   function Contains (Text : String; Pattern : String) return Boolean is
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
   end Contains;

   function Make_Archive return Boolean is
      Entries : Backup.Zip.Source_Entry_Vectors.Vector;
      Source  : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (Src_Dir & "/alpha.txt");
      Archive : Backup.Paths.Archive_Path;
      Status  : Backup.Paths.Validation_Status;
   begin
      Status := Backup.Paths.Make_Archive_Path ("alpha.txt", Archive);
      if Status /= Backup.Paths.Valid then
         return False;
      end if;

      Entries.Append
        (Backup.Zip.Source_Entry'(Source_Path  => Source,
          Archive_Path => Archive,
          Byte_Size    => 6,
          Method       => Backup.Zip.Stored,
          Kind         => Backup.Zip.Source_File,
          Generated    => False,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Content      => Null_Unbounded_String));
      return Backup.Zip.Create_Archive (Archive_Path, Entries) =
        Backup.Zip.Write_Ok;
   end Make_Archive;

   function Args
     (A01 : String := "";
      A02 : String := "";
      A03 : String := "";
      A04 : String := "";
      A05 : String := "";
      A06 : String := "")
      return Backup.CLI.String_Vectors.Vector
   is
      Result : Backup.CLI.String_Vectors.Vector;
   begin
      if A01 /= "" then
         Result.Append (A01);
      end if;
      if A02 /= "" then
         Result.Append (A02);
      end if;
      if A03 /= "" then
         Result.Append (A03);
      end if;
      if A04 /= "" then
         Result.Append (A04);
      end if;
      if A05 /= "" then
         Result.Append (A05);
      end if;
      if A06 /= "" then
         Result.Append (A06);
      end if;
      return Result;
   end Args;

   Diagnostic : Unbounded_String;
   Catalog    : Backup.Catalog.Catalog_Data;
   Result     : Backup.Catalog.Query_Result;
   Query      : Backup.Catalog.Query;
   Status     : Backup.Catalog.Catalog_Status;
   Json       : Unbounded_String;
   Config     : Backup.CLI.Configuration;
   Scanned    : Backup.Scanner.Entry_Vectors.Vector;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;
   Ensure_Directory (Src_Dir);
   Write_File (Src_Dir & "/alpha.txt", "alpha" & ASCII.LF);
   Write_File (Password_Path, "correct horse battery staple" & ASCII.LF);
   Check (Make_Archive, "test archive creation for catalog indexing");

   Status := Backup.Catalog.Index_Archive
     (Catalog_Path, Archive_Path, Catalog, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog indexes verified archive: " & To_String (Diagnostic));
   Check (Catalog.Archives.Length = 1,
          "catalog contains one archive after indexing");
   Check (Catalog.Entries.Length = 1,
          "catalog contains one entry after indexing");
   Check (Catalog.Archives.First_Element.Verification =
          Backup.Catalog.Verification_Trusted,
          "catalog marks verified archive metadata trusted");

   Status := Backup.Catalog.Parse_Query ("manifest:false", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses manifest metadata query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok
          and then Result.Archives.Length = 1,
          "catalog queries manifest metadata state");

   Status := Backup.Catalog.Parse_Query ("content:alpha", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses content query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog executes content query");
   Check (Result.Entries.Length = 1,
          "catalog content query finds archive entry");

   Backup.Catalog.Build_JSON_Report (Result, Json);
   Check (Contains (To_String (Json), "backup-catalog-query-v1"),
          "catalog query JSON reports deterministic format id");
   Check (Contains (To_String (Json), "alpha.txt"),
          "catalog query JSON includes indexed entry path");
   Check (Contains (To_String (Json), "verification"),
          "catalog query JSON includes entry trust state");

   Status := Backup.Catalog.Verify_Catalog
     (Catalog_Path, Catalog, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog verifies fresh metadata: " & To_String (Diagnostic));

   declare
      Broken : Backup.Catalog.Catalog_Data := Catalog;
      Item   : Backup.Catalog.Entry_Record := Broken.Entries.First_Element;
   begin
      Item.Verification := Backup.Catalog.Verification_Unknown;
      Broken.Entries.Replace_Element (Broken.Entries.First_Index, Item);
      Status := Backup.Catalog.Save
        (Broken_Trust_Catalog, Broken, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Ok,
             "catalog writes broken trust fixture");
      Status := Backup.Catalog.Verify_Catalog
        (Broken_Trust_Catalog, Broken, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Stale_Metadata,
             "catalog rejects untrusted entry metadata under trusted archive");
   end;

   declare
      Broken : Backup.Catalog.Catalog_Data := Catalog;
   begin
      Broken.Entries.Append (Broken.Entries.First_Element);
      Status := Backup.Catalog.Save
        (Duplicate_Entry_Catalog, Broken, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Ok,
             "catalog writes duplicate entry fixture");
      Status := Backup.Catalog.Load
        (Duplicate_Entry_Catalog, Broken, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Duplicate_Entry,
             "catalog load rejects duplicate entry rows precisely");
   end;

   Status := Backup.Catalog.Verify_Catalog
     (Missing_Catalog, Catalog, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Open_Failed
          and then Contains (To_String (Diagnostic), "does not exist"),
          "catalog verification rejects missing catalog precisely");

   Append_File (Archive_Path, "stale");
   Status := Backup.Catalog.Verify_Catalog
     (Catalog_Path, Catalog, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Stale_Metadata,
          "catalog detects stale archive metadata");

   Check (Make_Archive, "recreate archive after stale metadata test");
   declare
      Envelope_Status : constant Backup.Encryption.Envelope_Status :=
        Backup.Encryption.Encrypt_File
          (Archive_Path,
           Encrypted_Path,
           (Kind  => Backup.Encryption.Password_File,
            Value => To_Unbounded_String (Password_Path)),
           Backup.Encryption.Cipher_AES256_GCM,
           Diagnostic);
   begin
      Check (Envelope_Status = Backup.Encryption.Envelope_Ok,
             "test encrypted archive envelope creation: " &
             To_String (Diagnostic));
   end;

   Status := Backup.Catalog.Index_Archive
     (Catalog_Path, Encrypted_Path, Catalog, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog indexes encrypted envelope metadata");
   declare
      Saw_Encrypted : Boolean := False;
      Saw_Encrypted_Entry : Boolean := False;
   begin
      for Archive_Item of Catalog.Archives loop
         if To_String (Archive_Item.Archive_Path) = Encrypted_Path then
            Saw_Encrypted :=
              Archive_Item.Encryption = Backup.Catalog.Encryption_Envelope_Present
              and then Archive_Item.Verification =
                Backup.Catalog.Verification_Unknown;
         end if;
      end loop;
      for Entry_Item of Catalog.Entries loop
         if To_String (Entry_Item.Archive_Id) =
           Backup.Remote.Archive_Id_For_Path (Encrypted_Path)
         then
            Saw_Encrypted_Entry := True;
         end if;
      end loop;
      Check (Saw_Encrypted,
             "encrypted catalog record exposes only envelope metadata");
      Check (not Saw_Encrypted_Entry,
             "encrypted catalog record does not expose entry metadata");
   end;

   Status := Backup.Catalog.Record_Verification_Result
     (Catalog_Path => Catalog_Path,
      Archive_Path => Encrypted_Path,
      Trusted      => True,
      Catalog      => Catalog,
      Diagnostic   => Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog records successful verification for encrypted envelope: " &
          To_String (Diagnostic));
   Check
     (Catalog.Archives.Last_Element.Verification =
        Backup.Catalog.Verification_Trusted,
      "catalog verification update marks encrypted envelope trusted");

   Status := Backup.Catalog.Index_Archive
     (Catalog_Path,
      Encrypted_Path,
      (Kind  => Backup.Encryption.Password_File,
       Value => To_Unbounded_String (Password_Path)),
      Catalog,
      Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "password-aware encrypted catalog indexing succeeds: " &
          To_String (Diagnostic));
   declare
      Encrypted_Id : constant String :=
        Backup.Remote.Archive_Id_For_Path (Encrypted_Path);
      Saw_Encrypted_Archive : Boolean := False;
      Saw_Encrypted_Content : Boolean := False;
   begin
      for Archive_Item of Catalog.Archives loop
         if To_String (Archive_Item.Archive_Id) = Encrypted_Id then
            Saw_Encrypted_Archive :=
              Archive_Item.Encryption = Backup.Catalog.Encryption_Envelope_Present
              and then Archive_Item.Verification =
                Backup.Catalog.Verification_Trusted;
         end if;
      end loop;
      for Entry_Item of Catalog.Entries loop
         if To_String (Entry_Item.Archive_Id) = Encrypted_Id
           and then To_String (Entry_Item.Archive_Path) = "alpha.txt"
         then
            Saw_Encrypted_Content := True;
         end if;
      end loop;
      Check (Saw_Encrypted_Archive,
             "password-aware encrypted catalog keeps encrypted archive state");
      Check (Saw_Encrypted_Content,
             "password-aware encrypted catalog exposes searchable entry metadata");
   end;

   Status := Backup.Catalog.Parse_Query ("content:alpha", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses encrypted content query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Entries.Length >= 2,
      "catalog content query finds plaintext and encrypted archive entries");

   declare
      Source_Path : constant Backup.Paths.File_System_Path :=
        Backup.Paths.Normalize_File_System_Path (Src_Dir & "/alpha.txt");
      Archive : Backup.Paths.Archive_Path;
      Path_Status : constant Backup.Paths.Validation_Status :=
        Backup.Paths.Make_Archive_Path ("alpha.txt", Archive);
   begin
      Check (Path_Status = Backup.Paths.Valid,
             "test archive path for scanned catalog source metadata");
      Scanned.Append
        (Backup.Scanner.Discovered_Entry'(Source_Path           => Source_Path,
          Archive_Path          => Archive,
          Kind                  => Backup.Scanner.Entry_File,
          Byte_Size             => 6,
          Has_Modification_Time => True,
          Modification_Time     => Ada.Calendar.Time_Of (2026, 5, 12),
          Compression_Method    => Backup.Zip.Stored,
          Has_Prepared_Payload  => False,
          Prepared_Payload_Path => Ada.Strings.Unbounded.Null_Unbounded_String,
          Prepared_Compressed_Size => 0,
          Link_Target           => Null_Unbounded_String));
   end;

   Status := Backup.Catalog.Attach_Run_Metadata
     (Catalog_Path      => Catalog_Path,
      Archive_Path      => Archive_Path,
      Scanned_Entries   => Scanned,
      Parent_Archive_Id => Backup.Remote.Archive_Id_For_Path (Encrypted_Path),
      Retention_Group   => "daily",
      Remote_URL        => "file://backup",
      Remote_Verified   => True,
      Catalog           => Catalog,
      Diagnostic        => Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog attaches run metadata after indexing: " &
          To_String (Diagnostic));

   Status := Backup.Catalog.Parse_Query
     ("remote:file://backup", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses remote-location query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length = 1,
          "catalog queries remote-location metadata");


   Status := Backup.Catalog.Parse_Query ("remote-verified:true",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses remote verification query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length = 1,
          "catalog queries remote verification state");

   Status := Backup.Catalog.Parse_Query ("remote-verified:yes",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses flexible remote verification query");

   Query := (Mode => Backup.Catalog.Query_Archives_Only,
             Text => Null_Unbounded_String);
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length = 2
        and then Result.Entries.Length = 0,
      "catalog archive-only listing excludes entry rows");

   Status := Backup.Catalog.Parse_Query
     ("lineage:" & Backup.Remote.Archive_Id_For_Path (Encrypted_Path),
      Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses incremental-lineage query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length = 2,
          "catalog queries incremental-lineage metadata");

   declare
      Broken : Backup.Catalog.Catalog_Data := Catalog;
      Item   : Backup.Catalog.Archive_Record := Broken.Archives.First_Element;
   begin
      Item.Parent_Archive_Id := To_Unbounded_String ("missing-parent-id");
      Broken.Archives.Replace_Element (Broken.Archives.First_Index, Item);
      Status := Backup.Catalog.Save
        (Missing_Parent_Catalog, Broken, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Ok,
             "catalog writes missing parent fixture");
      Status := Backup.Catalog.Verify_Catalog
        (Missing_Parent_Catalog, Broken, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Malformed
             and then Contains (To_String (Diagnostic), "parent"),
             "catalog verification rejects missing incremental parent");
   end;

   Status := Backup.Catalog.Parse_Query ("retention:daily", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses retention query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length = 1,
          "catalog queries retention metadata");

   Status := Backup.Catalog.Parse_Query ("source:alpha.txt", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses source-path query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Entries.Length = 1
        and then Length (Result.Entries.First_Element.Modification_Time) > 0,
          "catalog queries source-path metadata and keeps modification time");

   declare
      Indexed_Text : constant String :=
        To_String (Catalog.Archives.First_Element.Indexed_Timestamp);
      Date_Fragment : constant String :=
        Indexed_Text (Indexed_Text'First .. Indexed_Text'First + 3);
   begin
      Status := Backup.Catalog.Parse_Query
        ("date:" & Date_Fragment, Query, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Ok,
             "catalog parses archive-date query");
      Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result,
                                              Diagnostic);
      Check
        (Status = Backup.Catalog.Catalog_Ok
           and then Result.Archives.Length >= 1,
         "catalog archive-date query matches indexed or modification timestamps");
   end;

   Check (Backup.Catalog_Syntax.Parse_U64_Text ("18446744073709551615").Valid,
          "SPARK catalog parses maximum unsigned 64-bit value");
   Check (not Backup.Catalog_Syntax.Parse_U64_Text ("18446744073709551616").Valid,
          "SPARK catalog rejects overflowing unsigned 64-bit value");
   Check (Backup.Catalog_Syntax.Parse_U32_Text ("4294967295").Valid,
          "SPARK catalog parses maximum unsigned 32-bit value");
   Check (not Backup.Catalog_Syntax.Parse_U32_Text ("4294967296").Valid,
          "SPARK catalog rejects overflowing unsigned 32-bit value");
   Check (Backup.Catalog_Syntax.Parse_U16_Text ("65535").Valid,
          "SPARK catalog parses maximum unsigned 16-bit value");
   Check (not Backup.Catalog_Syntax.Parse_U16_Text ("65536").Valid,
          "SPARK catalog rejects overflowing unsigned 16-bit value");
   Check (Backup.Catalog_Syntax.Is_Flexible_Boolean_Text ("yes"),
          "SPARK catalog accepts flexible boolean query text");
   Check (not Backup.Catalog_Syntax.Is_Flexible_Boolean_Text ("maybe"),
          "SPARK catalog rejects invalid flexible boolean query text");
   Check (Backup.Catalog_Syntax.Is_Manifest_Query_Text ("untrusted"),
          "SPARK catalog accepts manifest query text");
   Check (Backup.Catalog_Syntax.Is_Encryption_Query_Text ("envelope"),
          "SPARK catalog accepts encryption query text");
   Check
     (Backup.Catalog_Syntax.Parse_Kind ("directory").Valid
        and then Backup.Catalog_Syntax.Parse_Kind ("directory").Kind =
          Backup.Catalog.Entry_Directory,
      "SPARK catalog accepts directory entry-kind query text");
   Check (Backup.Catalog_Syntax.Is_Method_Query_Text ("deflate"),
          "SPARK catalog accepts method query name");
   Check (Backup.Catalog_Syntax.Is_Method_Query_Text ("65535"),
          "SPARK catalog accepts numeric method query text");
   Check
     (Backup.Catalog_Syntax.Is_Method_Query_Text ("0")
      and then Backup.Catalog_Syntax.Is_Method_Query_Text ("8")
      and then Backup.Catalog_Syntax.Is_Method_Query_Text ("12")
      and then Backup.Catalog_Syntax.Is_Method_Query_Text ("14")
      and then Backup.Catalog_Syntax.Is_Method_Query_Text ("20")
      and then Backup.Catalog_Syntax.Is_Method_Query_Text ("93")
      and then Backup.Catalog_Syntax.Is_Method_Query_Text ("98"),
      "SPARK catalog accepts documented numeric method ids");
   Check (not Backup.Catalog_Syntax.Is_Method_Query_Text ("65536"),
          "SPARK catalog rejects overflowing method query text");

   Status := Backup.Catalog.Parse_Query ("verification:trusted",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses verification-state query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length >= 1
        and then Result.Entries.Length >= 1,
      "catalog verification query includes trusted archives and entries");

   Status := Backup.Catalog.Parse_Query ("method:store", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses compression method query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Entries.Length >= 1,
      "catalog queries entries by compression method");

   Status := Backup.Catalog.Parse_Query ("kind:file", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses entry-kind query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Entries.Length >= 1,
      "catalog queries entries by entry kind");

   Catalog.Entries.Append
     (Backup.Catalog.Entry_Record'
        (Archive_Id        => Catalog.Archives.First_Element.Archive_Id,
         Archive_Path      => To_Unbounded_String ("directory-entry/"),
         Source_Path       => To_Unbounded_String (Src_Dir),
         Kind              => Backup.Catalog.Entry_Directory,
         Method            => 0,
         Crc32             => 0,
         Compressed_Size   => 0,
         Uncompressed_Size => 0,
         Local_Offset      => 0,
         Modification_Time => Null_Unbounded_String,
         Verification      => Backup.Catalog.Verification_Trusted));
   Status := Backup.Catalog.Parse_Query ("kind:directory", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses directory entry-kind query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Entries.Length = 1
        and then Result.Entries.First_Element.Kind =
          Backup.Catalog.Entry_Directory,
      "catalog queries directory entries by entry kind");

   Status := Backup.Catalog.Parse_Query ("encrypted:true", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses encryption metadata query");
   Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Result.Archives.Length = 1
        and then Result.Entries.Length = 0,
      "catalog queries encrypted envelope metadata without entries");

   Status := Backup.Catalog.Parse_Query ("encrypted:0", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog parses flexible encryption metadata query");

   declare
      Size_Text : constant String :=
        Interfaces.Unsigned_64'Image (Catalog.Archives.First_Element.Archive_Size);
      Clean_Size_Text : constant String :=
        Size_Text (Size_Text'First + 1 .. Size_Text'Last);
   begin
      Status := Backup.Catalog.Parse_Query
        ("size:" & Clean_Size_Text, Query, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Ok,
             "catalog parses size metadata query");
      Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result,
                                              Diagnostic);
      Check
        (Status = Backup.Catalog.Catalog_Ok
           and then Result.Archives.Length >= 1,
         "catalog queries archive or entry size metadata");
   end;

   declare
      Crc_Text : constant String :=
        Interfaces.Unsigned_32'Image (Catalog.Archives.First_Element.Archive_Crc32);
      Clean_Crc_Text : constant String :=
        Crc_Text (Crc_Text'First + 1 .. Crc_Text'Last);
   begin
      Status := Backup.Catalog.Parse_Query
        ("crc32:" & Clean_Crc_Text, Query, Diagnostic);
      Check (Status = Backup.Catalog.Catalog_Ok,
             "catalog parses CRC32 metadata query");
      Status := Backup.Catalog.Query_Catalog (Catalog, Query, Result,
                                              Diagnostic);
      Check
        (Status = Backup.Catalog.Catalog_Ok
           and then Result.Archives.Length >= 1,
         "catalog queries archive or entry CRC32 metadata");
   end;

   Status := Backup.Catalog.Parse_Query ("verification:bogus",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Unsupported_Query,
          "catalog rejects invalid verification-state query value");

   Status := Backup.Catalog.Parse_Query ("remote-verified:maybe",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Unsupported_Query,
          "catalog rejects invalid remote verification query value");
   Check (Contains (To_String (Diagnostic), "yes, no, 1, or 0"),
          "catalog remote verification diagnostic names flexible booleans");

   Status := Backup.Catalog.Parse_Query ("encrypted:maybe",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Unsupported_Query,
          "catalog rejects invalid encryption query value");
   Check (Contains (To_String (Diagnostic), "yes, no, 1, 0"),
          "catalog encryption diagnostic names flexible booleans");

   Status := Backup.Catalog.Parse_Query ("size:not-a-number",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Unsupported_Query,
          "catalog rejects invalid size query value");

   Status := Backup.Catalog.Parse_Query ("crc32:not-a-number",
                                         Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Unsupported_Query,
          "catalog rejects invalid CRC32 query value");

   Write_File (Catalog_Path & ".tmp", "backup-catalog-v1" & ASCII.LF);
   Status := Backup.Catalog.Verify_Catalog
     (Catalog_Path, Catalog, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Contains (To_String (Diagnostic), "interrupted update"),
      "catalog verification reports interrupted-update recovery guidance");
   if Ada.Directories.Exists (Catalog_Path & ".tmp") then
      Ada.Directories.Delete_File (Catalog_Path & ".tmp");
   end if;

   Write_File (Catalog_Path & ".bak", "backup-catalog-v1" & ASCII.LF);
   Status := Backup.Catalog.Verify_Catalog
     (Catalog_Path, Catalog, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Ok
        and then Contains (To_String (Diagnostic), "prior catalog backup"),
      "catalog verification reports leftover backup-file recovery guidance");
   if Ada.Directories.Exists (Catalog_Path & ".bak") then
      Ada.Directories.Delete_File (Catalog_Path & ".bak");
   end if;

   Write_File (Temp_Only_Catalog & ".tmp", "backup-catalog-v1" & ASCII.LF);
   Status := Backup.Catalog.Load (Temp_Only_Catalog, Catalog, Diagnostic);
   Check
     (Status = Backup.Catalog.Catalog_Malformed
        and then Contains (To_String (Diagnostic), "recovery"),
      "catalog load reports recovery guidance for temp-only interrupted update");

   Status := Backup.Catalog.Remove_Indexed_Archive
     (Catalog_Path, Encrypted_Path, Catalog, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Ok,
          "catalog removes indexed archive during retention cleanup");

   Status := Backup.Catalog.Parse_Query ("badfield:value", Query, Diagnostic);
   Check (Status = Backup.Catalog.Catalog_Unsupported_Query,
          "catalog rejects unsupported query fields precisely");

   Check
     (Backup.CLI.Parse
        (Args ("--catalog", Catalog_Path, "--list-archives"),
         Config,
         Diagnostic),
      "CLI accepts explicit catalog list command: " & To_String (Diagnostic));

   Check
     (not Backup.CLI.Parse
        (Args ("--catalog", Missing_Catalog, "--list-archives"),
         Config,
         Diagnostic)
        and then Contains (To_String (Diagnostic), "does not exist"),
      "CLI rejects catalog list command against a missing catalog");

   Check
     (not Backup.CLI.Parse
        (Args ("--catalog", Catalog_Path, "--list-archives",
               "--list-contents"),
         Config,
         Diagnostic),
      "CLI rejects multiple simultaneous catalog commands");

   Check
     (Backup.CLI.Parse
        (Args ("--catalog", Catalog_Path, "--verify", Archive_Path),
         Config,
         Diagnostic),
      "CLI accepts --catalog with archive verification: " &
      To_String (Diagnostic));

   Check
     (Backup.CLI.Parse
        (Args ("--catalog", Catalog_Path, "--index", Encrypted_Path,
               "--password-file", Password_Path),
         Config,
         Diagnostic),
      "CLI accepts password source for encrypted catalog indexing: " &
      To_String (Diagnostic));

   Check
     (Backup.CLI.Parse
        (Args ("--catalog", Catalog_Path, Root & "/created.zip", Src_Dir),
         Config,
         Diagnostic),
      "CLI accepts --catalog for backup creation auto-indexing: " &
      To_String (Diagnostic));
   Check
     (not Backup.CLI.Parse
        (Args ("--catalog", Catalog_Path, "--dry-run", Root & "/created.zip"),
         Config,
         Diagnostic),
      "CLI rejects --catalog with dry-run backup creation");

   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("backup catalog tests passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Natural'Image (Failures) & " backup catalog test failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
end Backup_Catalog_Tests;
