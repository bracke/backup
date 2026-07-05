with Ada.Directories;
with Ada.Streams.Stream_IO;

package body Backup.Zip_Images is
   use Ada.Streams;
   use Ada.Streams.Stream_IO;
   use Ada.Strings.Unbounded;
   use Interfaces;

   function Lower (Text : String) return String is
      Result : String := Text;
   begin
      for Ch of Result loop
         if Ch in 'A' .. 'Z' then
            Ch := Character'Val
              (Character'Pos (Ch) - Character'Pos ('A') + Character'Pos ('a'));
         end if;
      end loop;
      return Result;
   end Lower;

   function Is_Zip_Path (Path : String) return Boolean is
      L : constant String := Lower (Path);
   begin
      return L'Length >= 4 and then L (L'Last - 3 .. L'Last) = ".zip";
   end Is_Zip_Path;

   function Decimal_No_Space (Value : Positive) return String is
      Image : constant String := Positive'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal_No_Space;

   function Split_Part_Path (Base : String; Number : Positive) return String is
      Num_Text : constant String := Decimal_No_Space (Number);
   begin
      if Number < 10 then
         return Base & ".z0" & Num_Text;
      elsif Number < 100 then
         return Base & ".z" & Num_Text;
      else
         return Base & ".z" & Num_Text;
      end if;
   end Split_Part_Path;

   function File_Size_Of
     (Path       : String;
      Diagnostic : out Unbounded_String;
      Ok         : out Boolean) return Stream_Element_Offset
   is
      File : File_Type;
      Size_Value : Stream_Element_Offset := 0;
   begin
      Ok := False;
      Open (File, In_File, Path);
      Size_Value := Stream_Element_Offset (Size (File));
      Close (File);
      Ok := True;
      return Size_Value;
   exception
      when others =>
         begin
            if Is_Open (File) then
               Close (File);
            end if;
         exception
            when others => null;
         end;
         Diagnostic := To_Unbounded_String ("archive part could not be opened: " & Path);
         return 0;
   end File_Size_Of;

   procedure Read_File_Into
     (Path       : String;
      Data       : in out Stream_Element_Array;
      First      : Stream_Element_Offset;
      Diagnostic : out Unbounded_String;
      Ok         : out Boolean)
   is
      File      : File_Type;
      Last      : Stream_Element_Offset;
      File_Size : Stream_Element_Offset;
   begin
      Ok := False;
      Open (File, In_File, Path);
      File_Size := Stream_Element_Offset (Size (File));
      if File_Size = 0 then
         Close (File);
         Ok := True;
         return;
      end if;
      Read (File, Data (First .. First + File_Size - 1), Last);
      Close (File);
      if Last /= First + File_Size - 1 then
         Diagnostic := To_Unbounded_String ("archive part read was truncated: " & Path);
         return;
      end if;
      Ok := True;
   exception
      when others =>
         begin
            if Is_Open (File) then
               Close (File);
            end if;
         exception
            when others => null;
         end;
         Diagnostic := To_Unbounded_String ("archive part could not be read: " & Path);
   end Read_File_Into;

   function Read_Logical_Zip
     (Archive_Path : String;
      Disk_Starts  : out Disk_Start_Vectors.Vector;
      Diagnostic   : out Unbounded_String;
      Ok           : out Boolean)
      return Stream_Element_Array
   is
      Empty : constant Stream_Element_Array (1 .. 0) := [others => 0];
      Base  : constant String :=
        (if Is_Zip_Path (Archive_Path) then
            Archive_Path (Archive_Path'First .. Archive_Path'Last - 4)
         else
            Archive_Path);
      Split : constant Boolean :=
        Is_Zip_Path (Archive_Path)
        and then Ada.Directories.Exists (Split_Part_Path (Base, 1));
      Total_Size : Stream_Element_Offset := 0;
      Part_Count : Natural := 0;
      Part_Size  : Stream_Element_Offset;
      Part_Ok    : Boolean;
   begin
      Ok := False;
      Diagnostic := Null_Unbounded_String;
      Disk_Starts.Clear;

      if not Split then
         Part_Size := File_Size_Of (Archive_Path, Diagnostic, Part_Ok);
         if not Part_Ok then
            return Empty;
         end if;
         Disk_Starts.Append (1);
         declare
            Data : Stream_Element_Array (1 .. Part_Size);
         begin
            Read_File_Into (Archive_Path, Data, Data'First, Diagnostic, Part_Ok);
            Ok := Part_Ok;
            if not Ok then
               return Empty;
            end if;
            return Data;
         end;
      end if;

      loop
         declare
            Part_Path : constant String := Split_Part_Path (Base, Part_Count + 1);
         begin
            exit when not Ada.Directories.Exists (Part_Path);
            Part_Size := File_Size_Of (Part_Path, Diagnostic, Part_Ok);
            if not Part_Ok then
               return Empty;
            end if;
            if Stream_Element_Offset'Last - Total_Size < Part_Size then
               Diagnostic := To_Unbounded_String ("split ZIP archive is too large to read");
               return Empty;
            end if;
            Disk_Starts.Append (Unsigned_64 (Total_Size) + 1);
            Total_Size := Total_Size + Part_Size;
            Part_Count := Part_Count + 1;
         end;
      end loop;

      Part_Size := File_Size_Of (Archive_Path, Diagnostic, Part_Ok);
      if not Part_Ok then
         return Empty;
      end if;
      if Stream_Element_Offset'Last - Total_Size < Part_Size then
         Diagnostic := To_Unbounded_String ("split ZIP archive is too large to read");
         return Empty;
      end if;
      Disk_Starts.Append (Unsigned_64 (Total_Size) + 1);
      Total_Size := Total_Size + Part_Size;

      declare
         Data : Stream_Element_Array (1 .. Total_Size);
         Pos  : Stream_Element_Offset := Data'First;
      begin
         for Index in 1 .. Part_Count loop
            declare
               Part_Path : constant String := Split_Part_Path (Base, Index);
            begin
               Part_Size := File_Size_Of (Part_Path, Diagnostic, Part_Ok);
               if not Part_Ok then
                  return Empty;
               end if;
               Read_File_Into (Part_Path, Data, Pos, Diagnostic, Part_Ok);
               if not Part_Ok then
                  return Empty;
               end if;
               Pos := Pos + Part_Size;
            end;
         end loop;
         Read_File_Into (Archive_Path, Data, Pos, Diagnostic, Part_Ok);
         Ok := Part_Ok;
         if not Ok then
            return Empty;
         end if;
         return Data;
      end;
   exception
      when others =>
         Ok := False;
         Diagnostic := To_Unbounded_String ("archive could not be read");
         return Empty;
   end Read_Logical_Zip;
end Backup.Zip_Images;
