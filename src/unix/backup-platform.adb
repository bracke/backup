with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body Backup.Platform is
   use Ada.Strings.Unbounded;
   use Interfaces;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.Strings.chars_ptr;

   function C_Getpass
     (Prompt : Interfaces.C.Strings.chars_ptr)
      return Interfaces.C.Strings.chars_ptr
      with Import, Convention => C, External_Name => "getpass";

   function C_Readlink
     (Path    : Interfaces.C.Strings.chars_ptr;
      Buffer  : Interfaces.C.Strings.chars_ptr;
      Bufsize : Interfaces.C.size_t)
      return Interfaces.C.int
      with Import, Convention => C, External_Name => "readlink";

   function C_Stat
     (Path : Interfaces.C.Strings.chars_ptr;
      Buf  : System.Address)
      return Interfaces.C.int
      with Import, Convention => C, External_Name => "stat";

   function C_Chmod
     (Path : Interfaces.C.Strings.chars_ptr;
      Mode : Interfaces.C.int)
      return Interfaces.C.int
      with Import, Convention => C, External_Name => "chmod";

   function C_Chown
     (Path  : Interfaces.C.Strings.chars_ptr;
      Owner : Interfaces.C.unsigned;
      Group : Interfaces.C.unsigned)
      return Interfaces.C.int
      with Import, Convention => C, External_Name => "chown";

   function C_Symlink
     (Target : Interfaces.C.Strings.chars_ptr;
      Link   : Interfaces.C.Strings.chars_ptr)
      return Interfaces.C.int
      with Import, Convention => C, External_Name => "symlink";

   function C_Listxattr
     (Path : Interfaces.C.Strings.chars_ptr;
      List : System.Address;
      Size : Interfaces.C.size_t)
      return Interfaces.C.long
      with Import, Convention => C, External_Name => "listxattr";

   function C_Getxattr
     (Path  : Interfaces.C.Strings.chars_ptr;
      Name  : Interfaces.C.Strings.chars_ptr;
      Value : System.Address;
      Size  : Interfaces.C.size_t)
      return Interfaces.C.long
      with Import, Convention => C, External_Name => "getxattr";

   function C_Setxattr
     (Path  : Interfaces.C.Strings.chars_ptr;
      Name  : Interfaces.C.Strings.chars_ptr;
      Value : System.Address;
      Size  : Interfaces.C.size_t;
      Flags : Interfaces.C.int)
      return Interfaces.C.int
      with Import, Convention => C, External_Name => "setxattr";

   function Prompt_Password return String is
      Prompt_C : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ("backup password: ");
      Value_C  : Interfaces.C.Strings.chars_ptr;
   begin
      Value_C := C_Getpass (Prompt_C);
      Interfaces.C.Strings.Free (Prompt_C);
      if Value_C = Interfaces.C.Strings.Null_Ptr then
         return "";
      end if;
      return Interfaces.C.Strings.Value (Value_C);
   exception
      when others =>
         Interfaces.C.Strings.Free (Prompt_C);
         return "";
   end Prompt_Password;

   function Read_Link_Target
     (Path   : String;
      Target : out Unbounded_String)
      return Boolean
   is
      use Interfaces.C.Strings;
      Path_C : chars_ptr := New_String (Path);
      Buffer : chars_ptr := New_String ([1 .. 4096 => ASCII.NUL]);
      Count  : Interfaces.C.int;
   begin
      Target := Null_Unbounded_String;
      Count := C_Readlink (Path_C, Buffer, 4096);
      if Count < 0 then
         Free (Path_C);
         Free (Buffer);
         return False;
      end if;
      Target := To_Unbounded_String (Value (Buffer, Interfaces.C.size_t (Count)));
      Free (Path_C);
      Free (Buffer);
      return True;
   exception
      when others =>
         Free (Path_C);
         Free (Buffer);
         Target := Null_Unbounded_String;
         return False;
   end Read_Link_Target;

   function Create_Symlink
     (Target : String;
      Link   : String)
      return Boolean
   is
      Target_C : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Target);
      Link_C : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Link);
      Result : Interfaces.C.int;
   begin
      Result := C_Symlink (Target_C, Link_C);
      Interfaces.C.Strings.Free (Target_C);
      Interfaces.C.Strings.Free (Link_C);
      return Result = 0;
   exception
      when others =>
         Interfaces.C.Strings.Free (Target_C);
         Interfaces.C.Strings.Free (Link_C);
         return False;
   end Create_Symlink;

   procedure Owner_Ids
     (Path    : String;
      Present : out Boolean;
      UID     : out Unsigned_32;
      GID     : out Unsigned_32)
   is
      Path_C : Interfaces.C.Strings.chars_ptr;
      Info   : String (1 .. 256) := [others => Character'Val (0)];
      Result : Interfaces.C.int;

      function U32_At (Index : Positive) return Unsigned_32 is
      begin
         return Unsigned_32 (Character'Pos (Info (Index)))
           or Shift_Left (Unsigned_32 (Character'Pos (Info (Index + 1))), 8)
           or Shift_Left (Unsigned_32 (Character'Pos (Info (Index + 2))), 16)
           or Shift_Left (Unsigned_32 (Character'Pos (Info (Index + 3))), 24);
      end U32_At;
   begin
      Present := False;
      UID := 0;
      GID := 0;
      Path_C := Interfaces.C.Strings.New_String (Path);
      Result := C_Stat (Path_C, Info'Address);
      Interfaces.C.Strings.Free (Path_C);
      if Result = 0 then
         Present := True;
         UID := U32_At (29);
         GID := U32_At (33);
      end if;
   exception
      when others =>
         Present := False;
         UID := 0;
         GID := 0;
   end Owner_Ids;

   procedure Apply_Owner
     (Path : String;
      UID  : Unsigned_32;
      GID  : Unsigned_32)
   is
      Path_C : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
      Ignored : Interfaces.C.int;
      pragma Unreferenced (Ignored);
   begin
      Ignored := C_Chown
        (Path_C, Interfaces.C.unsigned (UID), Interfaces.C.unsigned (GID));
      Interfaces.C.Strings.Free (Path_C);
   exception
      when others =>
         Interfaces.C.Strings.Free (Path_C);
   end Apply_Owner;

   function Set_Permissions
     (Path : String;
      Mode : Unsigned_32)
      return Boolean
   is
      Path_C : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
      Result : Interfaces.C.int;
   begin
      Result := C_Chmod (Path_C, Interfaces.C.int (Mode));
      Interfaces.C.Strings.Free (Path_C);
      return Result = 0;
   exception
      when others =>
         Interfaces.C.Strings.Free (Path_C);
         return False;
   end Set_Permissions;

   procedure Apply_Mode
     (Path : String;
      Mode : Unsigned_32)
   is
      Ignored : constant Boolean := Set_Permissions (Path, Mode);
      pragma Unreferenced (Ignored);
   begin
      null;
   end Apply_Mode;

   procedure Append_U16
     (Text  : in out Unbounded_String;
      Value : Unsigned_16)
   is
   begin
      Append (Text, Character'Val (Integer (Value and 16#00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 8))));
   end Append_U16;

   procedure Append_U32
     (Text  : in out Unbounded_String;
      Value : Unsigned_32)
   is
   begin
      Append (Text, Character'Val (Integer (Value and 16#0000_00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 8) and 16#0000_00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 16) and 16#0000_00FF#)));
      Append (Text, Character'Val (Integer (Shift_Right (Value, 24) and 16#0000_00FF#)));
   end Append_U32;

   function Xattr_Blob (Path : String) return Unbounded_String is
      Max_Metadata_Length : constant Natural := 60_000;
      Path_C : Interfaces.C.Strings.chars_ptr;
      List_Size : Interfaces.C.long;
      Result : Unbounded_String;
      Entries : Unbounded_String;
      Count : Unsigned_16 := 0;
   begin
      Path_C := Interfaces.C.Strings.New_String (Path);
      List_Size := C_Listxattr (Path_C, System.Null_Address, 0);
      if List_Size <= 0 or else List_Size > Interfaces.C.long (Max_Metadata_Length) then
         Interfaces.C.Strings.Free (Path_C);
         return Null_Unbounded_String;
      end if;

      declare
         Names : String (1 .. Natural (List_Size)) := [others => Character'Val (0)];
         Actual : constant Interfaces.C.long :=
           C_Listxattr (Path_C, Names'Address, Interfaces.C.size_t (Names'Length));
         Pos : Positive := Names'First;
      begin
         if Actual <= 0 then
            Interfaces.C.Strings.Free (Path_C);
            return Null_Unbounded_String;
         end if;

         while Pos <= Natural (Actual) loop
            declare
               Start : constant Positive := Pos;
            begin
               while Pos <= Natural (Actual) and then Names (Pos) /= Character'Val (0) loop
                  Pos := Pos + 1;
               end loop;
               if Pos > Start then
                  declare
                     Name : constant String := Names (Start .. Pos - 1);
                     Name_C : Interfaces.C.Strings.chars_ptr :=
                       Interfaces.C.Strings.New_String (Name);
                     Value_Size : constant Interfaces.C.long :=
                       C_Getxattr (Path_C, Name_C, System.Null_Address, 0);
                  begin
                     if Value_Size >= 0
                       and then Name'Length <= Natural (Unsigned_16'Last)
                       and then Value_Size <= Interfaces.C.long (Unsigned_32'Last)
                       and then Length (Entries) + Name'Length + Natural (Value_Size) + 6
                         <= Max_Metadata_Length
                       and then Count < Unsigned_16'Last
                     then
                        Append_U16 (Entries, Unsigned_16 (Name'Length));
                        Append_U32 (Entries, Unsigned_32 (Value_Size));
                        Append (Entries, Name);
                        if Value_Size > 0 then
                           declare
                              Value : String (1 .. Natural (Value_Size)) :=
                                [others => Character'Val (0)];
                              Read_Size : constant Interfaces.C.long :=
                                C_Getxattr
                                  (Path_C, Name_C, Value'Address,
                                   Interfaces.C.size_t (Value'Length));
                           begin
                              if Read_Size = Value_Size then
                                 Append (Entries, Value);
                                 Count := Count + 1;
                              else
                                 Entries := Null_Unbounded_String;
                                 Count := 0;
                                 exit;
                              end if;
                           end;
                        else
                           Count := Count + 1;
                        end if;
                     end if;
                     Interfaces.C.Strings.Free (Name_C);
                  exception
                     when others =>
                        Interfaces.C.Strings.Free (Name_C);
                  end;
               end if;
               Pos := Pos + 1;
            end;
         end loop;
      end;

      Interfaces.C.Strings.Free (Path_C);
      if Count = 0 then
         return Null_Unbounded_String;
      end if;
      Append_U16 (Result, Count);
      Append (Result, To_String (Entries));
      return Result;
   exception
      when others =>
         begin
            Interfaces.C.Strings.Free (Path_C);
         exception
            when others => null;
         end;
         return Null_Unbounded_String;
   end Xattr_Blob;

   function Set_Xattr
     (Path  : String;
      Name  : String;
      Value : String)
      return Boolean
   is
      Path_C : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
      Name_C : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Name);
      Result : Interfaces.C.int;
   begin
      if Value'Length = 0 then
         Result := C_Setxattr (Path_C, Name_C, System.Null_Address, 0, 0);
      else
         Result := C_Setxattr
           (Path_C, Name_C, Value'Address, Interfaces.C.size_t (Value'Length), 0);
      end if;
      Interfaces.C.Strings.Free (Path_C);
      Interfaces.C.Strings.Free (Name_C);
      return Result = 0;
   exception
      when others =>
         Interfaces.C.Strings.Free (Path_C);
         Interfaces.C.Strings.Free (Name_C);
         return False;
   end Set_Xattr;

   function Get_Xattr
     (Path : String;
      Name : String)
      return String
   is
      Path_C : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
      Name_C : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Name);
      Buffer : String (1 .. 4096) := [others => Character'Val (0)];
      Size : Interfaces.C.long;
   begin
      Size := C_Getxattr
        (Path_C, Name_C, Buffer'Address, Interfaces.C.size_t (Buffer'Length));
      Interfaces.C.Strings.Free (Path_C);
      Interfaces.C.Strings.Free (Name_C);
      if Size <= 0 or else Size > Interfaces.C.long (Buffer'Length) then
         return "";
      end if;
      return Buffer (1 .. Natural (Size));
   exception
      when others =>
         Interfaces.C.Strings.Free (Path_C);
         Interfaces.C.Strings.Free (Name_C);
         return "";
   end Get_Xattr;
end Backup.Platform;
