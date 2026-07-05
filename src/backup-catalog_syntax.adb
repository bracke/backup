package body Backup.Catalog_Syntax
  with SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;
   function Verification_Name
     (State : Backup.Catalog.Verification_State) return String
   is
   begin
      case State is
         when Backup.Catalog.Verification_Unknown =>
            return "unknown";
         when Backup.Catalog.Verification_Trusted =>
            return "trusted";
         when Backup.Catalog.Verification_Failed =>
            return "failed";
         when Backup.Catalog.Verification_Stale =>
            return "stale";
      end case;
   end Verification_Name;

   function Encryption_Name
     (State : Backup.Catalog.Encryption_State) return String
   is
   begin
      case State is
         when Backup.Catalog.Encryption_Not_Encrypted =>
            return "none";
         when Backup.Catalog.Encryption_Envelope_Present =>
            return "envelope";
      end case;
   end Encryption_Name;

   function Kind_Name (Kind : Backup.Catalog.Entry_Kind) return String is
   begin
      case Kind is
         when Backup.Catalog.Entry_File =>
            return "file";
         when Backup.Catalog.Entry_Directory =>
            return "directory";
         when Backup.Catalog.Entry_Symlink =>
            return "symlink";
         when Backup.Catalog.Entry_Manifest =>
            return "manifest";
      end case;
   end Kind_Name;

   function Status_Text (Status : Backup.Catalog.Catalog_Status) return String is
   begin
      case Status is
         when Backup.Catalog.Catalog_Ok =>
            return "ok";
         when Backup.Catalog.Catalog_Open_Failed =>
            return "could not open catalog or archive";
         when Backup.Catalog.Catalog_Write_Failed =>
            return "could not write catalog";
         when Backup.Catalog.Catalog_Malformed =>
            return "malformed catalog";
         when Backup.Catalog.Catalog_Duplicate_Archive =>
            return "duplicate archive record in catalog";
         when Backup.Catalog.Catalog_Duplicate_Entry =>
            return "duplicate archive entry record in catalog";
         when Backup.Catalog.Catalog_Verification_Failed =>
            return "archive verification failed during catalog indexing";
         when Backup.Catalog.Catalog_Archive_Not_Found =>
            return "archive referenced by catalog was not found";
         when Backup.Catalog.Catalog_Stale_Metadata =>
            return "catalog metadata is stale";
         when Backup.Catalog.Catalog_Unsupported_Query =>
            return "unsupported catalog query";
      end case;
   end Status_Text;

   function Parse_Verification (Text : String) return Verification_Parse is
   begin
      if Text = "unknown" then
         return (Valid => True, State => Backup.Catalog.Verification_Unknown);
      elsif Text = "trusted" then
         return (Valid => True, State => Backup.Catalog.Verification_Trusted);
      elsif Text = "failed" then
         return (Valid => True, State => Backup.Catalog.Verification_Failed);
      elsif Text = "stale" then
         return (Valid => True, State => Backup.Catalog.Verification_Stale);
      else
         return (Valid => False, State => Backup.Catalog.Verification_Unknown);
      end if;
   end Parse_Verification;

   function Parse_Encryption (Text : String) return Encryption_Parse is
   begin
      if Text = "none" then
         return (Valid => True, State => Backup.Catalog.Encryption_Not_Encrypted);
      elsif Text = "envelope" then
         return (Valid => True, State => Backup.Catalog.Encryption_Envelope_Present);
      else
         return (Valid => False, State => Backup.Catalog.Encryption_Not_Encrypted);
      end if;
   end Parse_Encryption;

   function Parse_Kind (Text : String) return Kind_Parse is
   begin
      if Text = "file" then
         return (Valid => True, Kind => Backup.Catalog.Entry_File);
      elsif Text = "directory" then
         return (Valid => True, Kind => Backup.Catalog.Entry_Directory);
      elsif Text = "symlink" then
         return (Valid => True, Kind => Backup.Catalog.Entry_Symlink);
      elsif Text = "manifest" then
         return (Valid => True, Kind => Backup.Catalog.Entry_Manifest);
      else
         return (Valid => False, Kind => Backup.Catalog.Entry_File);
      end if;
   end Parse_Kind;

   function Boolean_Text (Value : Boolean) return String is
   begin
      if Value then
         return "true";
      else
         return "false";
      end if;
   end Boolean_Text;

   function Is_Boolean_Text (Text : String) return Boolean is
   begin
      return Text = "true" or else Text = "false";
   end Is_Boolean_Text;

   function Is_Flexible_Boolean_Text (Text : String) return Boolean is
   begin
      return Text = "true" or else Text = "false"
        or else Text = "yes" or else Text = "no"
        or else Text = "1" or else Text = "0";
   end Is_Flexible_Boolean_Text;

   function Is_Manifest_Query_Text (Text : String) return Boolean is
   begin
      return Text = "present" or else Text = "trusted"
        or else Text = "untrusted" or else Is_Boolean_Text (Text);
   end Is_Manifest_Query_Text;

   function Is_Encryption_Query_Text (Text : String) return Boolean is
   begin
      return Is_Flexible_Boolean_Text (Text)
        or else Text = "envelope" or else Text = "none";
   end Is_Encryption_Query_Text;

   function Is_Digit (Ch : Character) return Boolean is
   begin
      return Ch in '0' .. '9';
   end Is_Digit;

   function Parse_U64_Text (Text : String) return U64_Parse
   is
      Accumulated : Interfaces.Unsigned_64 := 0;
      Digit       : Interfaces.Unsigned_64;
   begin
      if Text'Length = 0 then
         return (Valid => False, Value => 0);
      end if;

      for Ch of Text loop
         if not Is_Digit (Ch) then
            return (Valid => False, Value => 0);
         end if;

         Digit := Interfaces.Unsigned_64
           (Character'Pos (Ch) - Character'Pos ('0'));
         if Accumulated > (Interfaces.Unsigned_64'Last - Digit) / 10 then
            return (Valid => False, Value => 0);
         end if;

         Accumulated := Accumulated * 10 + Digit;
      end loop;

      return (Valid => True, Value => Accumulated);
   end Parse_U64_Text;

   function Parse_U32_Text (Text : String) return U32_Parse
   is
      Parsed : constant U64_Parse := Parse_U64_Text (Text);
   begin
      if not Parsed.Valid
        or else Parsed.Value > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
      then
         return (Valid => False, Value => 0);
      end if;

      return (Valid => True, Value => Interfaces.Unsigned_32 (Parsed.Value));
   end Parse_U32_Text;

   function Parse_U16_Text (Text : String) return U16_Parse
   is
      Parsed : constant U64_Parse := Parse_U64_Text (Text);
   begin
      if not Parsed.Valid
        or else Parsed.Value > Interfaces.Unsigned_64 (Interfaces.Unsigned_16'Last)
      then
         return (Valid => False, Value => 0);
      end if;

      return (Valid => True, Value => Interfaces.Unsigned_16 (Parsed.Value));
   end Parse_U16_Text;

   function Is_Method_Query_Text (Text : String) return Boolean is
   begin
      return Text = "store" or else Text = "stored"
        or else Text = "deflate" or else Text = "deflated"
        or else Text = "bzip2" or else Text = "lzma"
        or else Text = "zstd" or else Text = "ppmd"
        or else Parse_U16_Text (Text).Valid;
   end Is_Method_Query_Text;
end Backup.Catalog_Syntax;
