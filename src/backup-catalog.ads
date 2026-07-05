with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

with Backup.Encryption;
with Backup.Scanner;

package Backup.Catalog is
   --  Persistent searchable backup catalog support.
   --
   --  The on-disk format is a deterministic Ada-native line format with the
   --  magic header "backup-catalog-v1". Fields are pipe-separated and percent
   --  escaped. Updates are written to a temporary file and then atomically
   --  renamed into place where the host filesystem supports rename semantics.
   --
   --  Trust model: entry metadata imported from an archive is marked trusted
   --  only when Phase 16 verification succeeds. Encrypted archives indexed
   --  without a password expose only the archive-level metadata that the Phase
   --  19 envelope leaves visible: archive path, archive id, envelope size,
   --  envelope CRC32, and encryption-presence metadata. Password-aware
   --  indexing decrypts to a temporary work archive, verifies that plaintext
   --  ZIP, and stores searchable entry metadata under the encrypted archive id.

   type Catalog_Status is
     (Catalog_Ok,
      Catalog_Open_Failed,
      Catalog_Write_Failed,
      Catalog_Malformed,
      Catalog_Duplicate_Archive,
      Catalog_Duplicate_Entry,
      Catalog_Verification_Failed,
      Catalog_Archive_Not_Found,
      Catalog_Stale_Metadata,
      Catalog_Unsupported_Query);

   type Verification_State is
     (Verification_Unknown,
      Verification_Trusted,
      Verification_Failed,
      Verification_Stale);

   type Encryption_State is
     (Encryption_Not_Encrypted,
      Encryption_Envelope_Present);

   type Entry_Kind is
     (Entry_File,
      Entry_Directory,
      Entry_Symlink,
      Entry_Manifest);

   type Archive_Record is record
      Archive_Id        : Ada.Strings.Unbounded.Unbounded_String;
      Archive_Path      : Ada.Strings.Unbounded.Unbounded_String;
      Archive_Size      : Interfaces.Unsigned_64 := 0;
      Archive_Crc32     : Interfaces.Unsigned_32 := 0;
      Indexed_Timestamp : Ada.Strings.Unbounded.Unbounded_String;
      Archive_Modification_Time : Ada.Strings.Unbounded.Unbounded_String;
      Encryption        : Encryption_State := Encryption_Not_Encrypted;
      Verification      : Verification_State := Verification_Unknown;
      Has_Manifest      : Boolean := False;
      Manifest_Trusted  : Boolean := False;
      Parent_Archive_Id : Ada.Strings.Unbounded.Unbounded_String;
      Retention_Group   : Ada.Strings.Unbounded.Unbounded_String;
      Remote_URL        : Ada.Strings.Unbounded.Unbounded_String;
      Remote_Verified   : Boolean := False;
   end record;

   type Entry_Record is record
      Archive_Id        : Ada.Strings.Unbounded.Unbounded_String;
      Archive_Path      : Ada.Strings.Unbounded.Unbounded_String;
      Source_Path       : Ada.Strings.Unbounded.Unbounded_String;
      Kind              : Entry_Kind := Entry_File;
      Method            : Interfaces.Unsigned_16 := 0;
      Crc32             : Interfaces.Unsigned_32 := 0;
      Compressed_Size   : Interfaces.Unsigned_64 := 0;
      Uncompressed_Size : Interfaces.Unsigned_64 := 0;
      Local_Offset      : Interfaces.Unsigned_64 := 0;
      Modification_Time : Ada.Strings.Unbounded.Unbounded_String;
      Verification      : Verification_State := Verification_Unknown;
   end record;

   package Archive_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Archive_Record);

   package Entry_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Entry_Record);

   type Catalog_Data is record
      Archives : Archive_Vectors.Vector;
      Entries  : Entry_Vectors.Vector;
   end record;

   type Query_Mode is
     (Query_All,
      Query_Archives_Only,
      Query_Archive_Name,
      Query_Archive_Date,
      Query_Contents,
      Query_Source_Path,
      Query_Incremental_Lineage,
      Query_Remote_Location,
      Query_Remote_Verified,
      Query_Verification_State,
      Query_Manifest_State,
      Query_Encryption_State,
      Query_Metadata_Size,
      Query_Metadata_Crc32,
      Query_Compression_Method,
      Query_Entry_Kind,
      Query_Retention_Group);

   type Query is record
      Mode : Query_Mode := Query_All;
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Query_Result is record
      Archives : Archive_Vectors.Vector;
      Entries  : Entry_Vectors.Vector;
   end record;

   function Status_Text (Status : Catalog_Status) return String;

   function Parse_Query
     (Text       : String;
      Parsed     : out Query;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Load
     (Catalog_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Save
     (Catalog_Path : String;
      Catalog      : Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Index_Archive
     (Catalog_Path : String;
      Archive_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Index_Archive
     (Catalog_Path : String;
      Archive_Path : String;
      Password     : Backup.Encryption.Password_Source;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Query_Catalog
     (Catalog    : Catalog_Data;
      Filter     : Query;
      Result     : out Query_Result;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;



   function Remove_Indexed_Archive
     (Catalog_Path : String;
      Archive_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Attach_Run_Metadata
     (Catalog_Path      : String;
      Archive_Path      : String;
      Scanned_Entries   : Backup.Scanner.Entry_Vectors.Vector;
      Parent_Archive_Id : String;
      Retention_Group   : String;
      Remote_URL        : String;
      Remote_Verified   : Boolean;
      Catalog           : out Catalog_Data;
      Diagnostic        : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;


   function Record_Verification_Result
     (Catalog_Path : String;
      Archive_Path : String;
      Trusted      : Boolean;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   function Verify_Catalog
     (Catalog_Path : String;
      Catalog      : out Catalog_Data;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Catalog_Status;

   procedure Build_JSON_Report
     (Result : Query_Result;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_Human_Report
     (Result : Query_Result;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);
end Backup.Catalog;
