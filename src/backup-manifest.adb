with Interfaces;

with Backup.Metadata;
with Backup.Manifest_Syntax;
with Backup.Paths;

package body Backup.Manifest is
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Backup.Zip.Write_Result;
   use type Backup.Scanner.Entry_Kind;

   Dos_Time_Normalized : constant Unsigned_16 := 0;
   Dos_Date_Normalized : constant Unsigned_16 := 33;
   Q                   : constant String := """";

   function Method_Name
     (Method : Backup.Zip.Compression_Method)
      return String
   is
   begin
      return Backup.Manifest_Syntax.Method_Name (Method);
   end Method_Name;

   function Build_Result_Text
     (Result : Build_Result)
      return String
   is
   begin
      return Backup.Manifest_Syntax.Build_Result_Text (Result);
   end Build_Result_Text;

   function Kind_Name (Kind : Backup.Scanner.Entry_Kind) return String is
   begin
      return Backup.Manifest_Syntax.Kind_Name (Kind);
   end Kind_Name;

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
            when '"' =>
               Append_Escape (Result, '"');
            when '\' =>
               Append_Escape (Result, '\');
            when ASCII.BS =>
               Append_Escape (Result, 'b');
            when ASCII.HT =>
               Append_Escape (Result, 't');
            when ASCII.LF =>
               Append_Escape (Result, 'n');
            when ASCII.FF =>
               Append_Escape (Result, 'f');
            when ASCII.CR =>
               Append_Escape (Result, 'r');
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

   function Decimal (Value : Unsigned_64) return String is
      Image : constant String := Unsigned_64'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Build
     (Entries : Backup.Scanner.Entry_Vectors.Vector;
      Content : out Unbounded_String)
      return Build_Result
   is
      Result : Unbounded_String;
      First  : Boolean := True;
   begin
      Append (Result, "{" & ASCII.LF);
      Append
        (Result,
         "  " & Q & "format" & Q & ": " & Q &
         "backup-manifest-v1" & Q & "," & ASCII.LF);
      Append
        (Result,
         "  " & Q & "manifest_path" & Q & ": " & Q &
         Manifest_Path & Q & "," & ASCII.LF);
      Append
        (Result,
         "  " & Q & "manifest_method" & Q & ": " & Q &
         "stored" & Q & "," & ASCII.LF);
      Append
        (Result,
         "  " & Q & "timestamp" & Q & ": {" &
         Q & "dos_time" & Q & ": ");
      Append (Result, Decimal (Unsigned_64 (Dos_Time_Normalized)));
      Append (Result, ", " & Q & "dos_date" & Q & ": ");
      Append (Result, Decimal (Unsigned_64 (Dos_Date_Normalized)));
      Append (Result, "}," & ASCII.LF);
      Append (Result, "  " & Q & "entries" & Q & ": [" & ASCII.LF);

      for Item of Entries loop
         pragma Assert
           (Backup.Paths.To_String (Item.Archive_Path)'Length > 0,
            "manifest entries have non-empty archive paths");
         if First then
            First := False;
         else
            Append (Result, "," & ASCII.LF);
         end if;

         Append (Result, "    {");
         Append (Result, Q & "source" & Q & ": " & Q);
         Append (Result, "<normalized-input>");
         Append (Result, Q & ", " & Q & "archive_path" & Q & ": " & Q);
         Append
           (Result,
            Json_Escape (Backup.Paths.To_String (Item.Archive_Path)));
         Append
           (Result,
            Q & ", " & Q & "kind" & Q & ": " & Q);
         Append (Result, Kind_Name (Item.Kind));
         Append
           (Result,
            Q & ", " & Q & "compression_method" & Q & ": " & Q);
         Append (Result, Method_Name (Item.Compression_Method));
         if Item.Kind = Backup.Scanner.Entry_Symlink then
            Append
              (Result,
               Q & ", " & Q & "link_target" & Q & ": " & Q);
            Append (Result, Json_Escape (To_String (Item.Link_Target)));
            Append (Result, Q & ", " & Q & "crc32" & Q & ": ");
            Append
              (Result,
               Decimal
                 (Unsigned_64
                    (Backup.Zip.Crc32_Of_Text (Item.Link_Target))));
         else
            declare
               Crc             : Unsigned_32;
               Observed_Size   : Unsigned_64;
               Metadata_Status : constant Backup.Zip.Write_Result :=
                 Backup.Zip.Analyze_File
                   (Item.Source_Path, Crc, Observed_Size);
            begin
               if Metadata_Status = Backup.Zip.Write_Unreadable_Source then
                  Content := Null_Unbounded_String;
                  return Build_Unreadable_Source;
               elsif Metadata_Status /= Backup.Zip.Write_Ok then
                  Content := Null_Unbounded_String;
                  return Build_Unreadable_Source;
               elsif Observed_Size /= Item.Byte_Size then
                  Content := Null_Unbounded_String;
                  return Build_Size_Changed;
               end if;

               Append (Result, Q & ", " & Q & "crc32" & Q & ": ");
               Append (Result, Decimal (Unsigned_64 (Crc)));
            end;
         end if;

         Append (Result, ", " & Q & "uncompressed_size" & Q & ": ");
         Append (Result, Decimal (Item.Byte_Size));
         Append (Result, ", " & Q & "compressed_size" & Q & ": ");
         declare
            Manifest_Compressed_Size : Unsigned_64;
         begin
            if Item.Has_Prepared_Payload then
               Manifest_Compressed_Size := Item.Prepared_Compressed_Size;
            elsif not Backup.Metadata.Estimate_Compressed_Size_For_Direct_Metadata
              (Item.Compression_Method,
               Item.Source_Path,
               Item.Byte_Size,
               Manifest_Compressed_Size)
            then
               Content := Null_Unbounded_String;
               return Build_Size_Limit;
            end if;
            Append (Result, Decimal (Manifest_Compressed_Size));
         end;
         Append
           (Result,
            ", " & Q & "timestamp" & Q & ": {" &
            Q & "dos_time" & Q & ": ");
         Append (Result, Decimal (Unsigned_64 (Dos_Time_Normalized)));
         Append (Result, ", " & Q & "dos_date" & Q & ": ");
         Append (Result, Decimal (Unsigned_64 (Dos_Date_Normalized)));
         Append (Result, "}}");
      end loop;

      Append (Result, ASCII.LF & "  ]" & ASCII.LF);
      Append (Result, "}" & ASCII.LF);
      Content := Result;
      return Build_Ok;
   end Build;

   function Build
     (Entries : Backup.Scanner.Entry_Vectors.Vector)
      return Unbounded_String
   is
      Content : Unbounded_String;
      Status  : constant Build_Result := Build (Entries, Content);
   begin
      pragma Assert
        (Status = Build_Ok,
         "compatibility manifest builder expects readable source files");
      if Status = Build_Ok then
         return Content;
      else
         return Null_Unbounded_String;
      end if;
   end Build;
end Backup.Manifest;
