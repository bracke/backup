with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Backup.Verify is
   type Verify_Status is
     (Verify_Ok,
      Verify_Open_Failed,
      Verify_Malformed_Zip,
      Verify_Invalid_Archive_Path,
      Verify_Duplicate_Archive_Path,
      Verify_Invalid_Offset,
      Verify_Truncated_Payload,
      Verify_Metadata_Mismatch,
      Verify_Crc_Mismatch,
      Verify_Invalid_Zip64,
      Verify_Unsupported_Method,
      Verify_Unsupported_Feature,
      Verify_Deflate_Invalid,
      Verify_Manifest_Mismatch);

   type Entry_Kind is
     (Entry_File,
      Entry_Directory,
      Entry_Symlink,
      Entry_Manifest);

   type Verified_Entry is record
      Archive_Path      : Ada.Strings.Unbounded.Unbounded_String;
      Kind              : Entry_Kind := Entry_File;
      Method            : Interfaces.Unsigned_16 := 0;
      Crc32             : Interfaces.Unsigned_32 := 0;
      Compressed_Size   : Interfaces.Unsigned_64 := 0;
      Uncompressed_Size : Interfaces.Unsigned_64 := 0;
      Local_Offset      : Interfaces.Unsigned_64 := 0;
      Dos_Time          : Interfaces.Unsigned_16 := 0;
      Dos_Date          : Interfaces.Unsigned_16 := 33;
      External_Attrs    : Interfaces.Unsigned_32 := 0;
      Has_Owner         : Boolean := False;
      Owner_UID         : Interfaces.Unsigned_32 := 0;
      Owner_GID         : Interfaces.Unsigned_32 := 0;
      Xattr_Blob        : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Link_Target       : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   package Entry_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Verified_Entry);

   type Verification_Report is record
      Status        : Verify_Status := Verify_Malformed_Zip;
      Entries       : Entry_Vectors.Vector;
      Has_Zip64     : Boolean := False;
      Has_Manifest  : Boolean := False;
      Manifest_OK   : Boolean := False;
   end record;

   function Status_Text (Status : Verify_Status) return String;

   function Verify_Archive
     (Archive_Path : String;
      Report       : out Verification_Report;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String)
      return Verify_Status;

   function Verify_Archive
     (Archive_Path  : String;
      Zip_Password  : String;
      Report        : out Verification_Report;
      Diagnostic    : out Ada.Strings.Unbounded.Unbounded_String)
      return Verify_Status;

   procedure Build_Human_Report
     (Report : Verification_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_JSON_Report
     (Report : Verification_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_List_Human_Report
     (Report : Verification_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Build_List_JSON_Report
     (Report : Verification_Report;
      Text   : out Ada.Strings.Unbounded.Unbounded_String);
end Backup.Verify;
