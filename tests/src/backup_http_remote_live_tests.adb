with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Files;

with Backup.Remote;

with GNAT.OS_Lib;
with GNAT.SHA1;
with GNAT.Sockets;
with Http_Client.Crypto;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

procedure Backup_HTTP_Remote_Live_Tests is
   use Ada.Strings.Unbounded;
   use type Backup.Remote.Remote_Status;
   use type Backup.Remote.Transport_Kind;
   use type Interfaces.C.int;
   use type Interfaces.C.Strings.chars_ptr;
   use type Interfaces.Unsigned_32;
   use type System.Address;
   use type Interfaces.Unsigned_64;
   use type Ada.Streams.Stream_Element_Offset;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   function Temp_Directory return String is
      TMPDIR : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Getenv ("TMPDIR");
      TMP    : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Getenv ("TMP");
      TEMP   : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Getenv ("TEMP");

      function Usable_Temp (Value : String) return Boolean is
      begin
         return Value'Length > 0 and then Ada.Directories.Exists (Value);
      end Usable_Temp;
   begin
      declare
         Result : constant String :=
           (if Usable_Temp (TMPDIR.all) then TMPDIR.all
            elsif Usable_Temp (TMP.all) then TMP.all
            elsif Usable_Temp (TEMP.all) then TEMP.all
            elsif Ada.Directories.Exists ("/tmp") then "/tmp"
            else Ada.Directories.Current_Directory);
      begin
         GNAT.OS_Lib.Free (TMPDIR);
         GNAT.OS_Lib.Free (TMP);
         GNAT.OS_Lib.Free (TEMP);
         return Result;
      end;
   end Temp_Directory;

   Root : constant String :=
     Ada.Directories.Compose
       (Temp_Directory,
        "backup_http_remote_live_tests-" &
        Image
          (Natural
             (GNAT.OS_Lib.Pid_To_Integer
                (GNAT.OS_Lib.Current_Process_Id))));

   function Path (Leaf_Name : String) return String is
   begin
      return Ada.Directories.Compose (Root, Leaf_Name);
   end Path;

   Local : constant String := Path ("local.zip");
   Retry_Local : constant String := Path ("retry.zip");
   Secure_Local : constant String := Path ("secure.zip");
   Secure_Restored : constant String := Path ("secure-restored.zip");
   Restored : constant String := Path ("restored.zip");
   Failures : Natural := 0;
   Saw_PCloud_Rename : Boolean := False;
   Saw_PCloud_Path_Create : Boolean := False;
   Fail_Next_PCloud_Rename : Boolean := False;
   Saw_PCloud_Temp_Cleanup : Boolean := False;
   Saw_PCloud_Nonce_Temp_Name : Boolean := False;
   Saw_PCloud_Progress_Hash : Boolean := False;
   Saw_PCloud_Progress_Poll : Boolean := False;
   Saw_PCloud_Parent_Create : Boolean := False;
   PCloud_Archive_Upload_Count : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Name);
      end if;
   end Check;

   function Fixture_Path (Leaf_Name : String) return String is
      --  The sibling checkout is the lowercase "httpclient" -- both the CI checkout path
      --  and the on-disk directory. The capitalised "HttpClient" (the crate's display
      --  name) only resolved on a case-insensitive filesystem, which is why this passed
      --  on macOS and failed on Linux, where the TLS server could not load its cert and
      --  reported port 0. Try the real lowercase name first, keep the old spelling as a
      --  fallback.
      Candidates : constant array (Positive range <>) of Unbounded_String :=
        [To_Unbounded_String ("../httpclient/tests/fixtures/tls/" & Leaf_Name),
         To_Unbounded_String ("../../httpclient/tests/fixtures/tls/" & Leaf_Name),
         To_Unbounded_String ("../HttpClient/tests/fixtures/tls/" & Leaf_Name),
         To_Unbounded_String ("../../HttpClient/tests/fixtures/tls/" & Leaf_Name),
         To_Unbounded_String ("tests/fixtures/tls/" & Leaf_Name),
         To_Unbounded_String ("fixtures/tls/" & Leaf_Name)];
   begin
      for Candidate of Candidates loop
         declare
            Path : constant String := To_String (Candidate);
         begin
            if Ada.Directories.Exists (Path) then
               return Path;
            end if;
         end;
      end loop;

      return "../httpclient/tests/fixtures/tls/" & Leaf_Name;
   end Fixture_Path;

   function Starts_With (Value : String; Prefix : String) return Boolean is
   begin
      return Value'Length >= Prefix'Length
        and then Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   procedure Write_File (Path : String; Text : String) is
   begin
      Project_Tools.Files.Write_Text_File (Path, Text);
   end Write_File;

   function Read_Text_File (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Text : Unbounded_String;
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         if Length (Text) > 0 then
            Append (Text, ASCII.LF);
         end if;
         Append (Text, Ada.Text_IO.Get_Line (File));
      end loop;
      Ada.Text_IO.Close (File);
      return Ada.Strings.Fixed.Trim (To_String (Text), Ada.Strings.Both);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Read_Text_File;

   function SHA1_File (Path : String) return String is
      File    : Ada.Streams.Stream_IO.File_Type;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 16 * 1024);
      Last    : Ada.Streams.Stream_Element_Offset;
      Context : GNAT.SHA1.Context := GNAT.SHA1.Initial_Context;
   begin
      Ada.Streams.Stream_IO.Open
        (File, Ada.Streams.Stream_IO.In_File, Path);
      while not Ada.Streams.Stream_IO.End_Of_File (File) loop
         Ada.Streams.Stream_IO.Read (File, Buffer, Last);
         if Last >= Buffer'First then
            GNAT.SHA1.Update (Context, Buffer (Buffer'First .. Last));
         end if;
      end loop;
      Ada.Streams.Stream_IO.Close (File);
      return GNAT.SHA1.Digest (Context);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end SHA1_File;

   procedure Write_Repeated_File (Path : String; Size : Natural) is
      File      : Ada.Text_IO.File_Type;
      Chunk     : constant String (1 .. 8192) := [others => 'x'];
      Remaining : Natural := Size;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      while Remaining >= Chunk'Length loop
         Ada.Text_IO.Put (File, Chunk);
         Remaining := Remaining - Chunk'Length;
      end loop;
      if Remaining > 0 then
         Ada.Text_IO.Put (File, Chunk (1 .. Remaining));
      end if;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Write_Repeated_File;

   function Header_End (Text : String) return Natural is
      Pos : constant Natural := Ada.Strings.Fixed.Index (Text, CRLF & CRLF);
   begin
      if Pos = 0 then
         return 0;
      end if;
      return Pos + 3;
   end Header_End;

   function Normalize_Path (Target : String) return String is
      Start : Natural := Target'First;
      Stop  : Natural := Target'Last;
   begin
      if Target'Length >= 7
        and then Target (Target'First .. Target'First + 6) = "http://"
      then
         Start := Target'First + 7;
         while Start <= Target'Last and then Target (Start) /= '/' loop
            Start := Start + 1;
         end loop;
         if Start > Target'Last then
            return "/";
         end if;
      end if;

      Stop := Start;
      while Stop <= Target'Last
        and then Target (Stop) /= '?'
        and then Target (Stop) /= '#'
      loop
         Stop := Stop + 1;
      end loop;

      if Stop = Start then
         return "/";
      end if;
      return Target (Start .. Stop - 1);
   end Normalize_Path;

   function Content_Length (Headers : String) return Natural is
      Key : constant String := "Content-Length:";
      Pos : constant Natural := Ada.Strings.Fixed.Index (Headers, Key);
      First : Natural;
      Last  : Natural;
   begin
      if Pos = 0 then
         return 0;
      end if;

      First := Pos + Key'Length;
      while First <= Headers'Last and then Headers (First) = ' ' loop
         First := First + 1;
      end loop;
      Last := First;
      while Last <= Headers'Last and then Headers (Last) in '0' .. '9' loop
         Last := Last + 1;
      end loop;
      if Last = First then
         return 0;
      end if;
      return Natural'Value (Headers (First .. Last - 1));
   exception
      when others =>
         return 0;
   end Content_Length;

   function Header_Value (Headers : String; Name : String) return String is
      Key : constant String := Name & ":";
      Pos : constant Natural := Ada.Strings.Fixed.Index (Headers, Key);
      First : Natural;
      Last  : Natural;
   begin
      if Pos = 0 then
         return "";
      end if;

      First := Pos + Key'Length;
      while First <= Headers'Last and then Headers (First) = ' ' loop
         First := First + 1;
      end loop;
      Last := First;
      while Last <= Headers'Last
        and then Headers (Last) /= Character'Val (13)
        and then Headers (Last) /= Character'Val (10)
      loop
         Last := Last + 1;
      end loop;
      if Last = First then
         return "";
      end if;
      return Headers (First .. Last - 1);
   end Header_Value;


   function Extract_Drive_Multipart_Content (Payload : String) return String is
      Zip_Marker  : constant String := "Content-Type: application/zip" & CRLF & CRLF;
      Text_Marker : constant String := "Content-Type: text/plain" & CRLF & CRLF;
      Start       : Natural := Ada.Strings.Fixed.Index (Payload, Zip_Marker);
      Marker_Len  : Natural := Zip_Marker'Length;
      First       : Natural;
      Stop        : Natural;
   begin
      if Start = 0 then
         Start := Ada.Strings.Fixed.Index (Payload, Text_Marker);
         Marker_Len := Text_Marker'Length;
      end if;
      if Start = 0 then
         return Payload;
      end if;
      First := Start + Marker_Len;
      Stop := Ada.Strings.Fixed.Index
        (Payload (First .. Payload'Last), CRLF & "--backup-drive-boundary-v1");
      if Stop = 0 or else Stop <= First then
         return Payload (First .. Payload'Last);
      end if;
      return Payload (First .. Stop - 1);
   exception
      when others =>
         return Payload;
   end Extract_Drive_Multipart_Content;

   procedure Send_All (Socket : GNAT.Sockets.Socket_Type; Text : String) is
      use Ada.Streams;
      Chunk_Size : constant Natural := 8192;
      Sent       : Natural := 0;
      Count      : Natural;
      Last       : Stream_Element_Offset;
   begin
      while Sent < Text'Length loop
         Count := Natural'Min (Chunk_Size, Text'Length - Sent);
         declare
            Raw : Stream_Element_Array (1 .. Stream_Element_Offset (Count));
         begin
            for Index in Raw'Range loop
               Raw (Index) := Stream_Element
                 (Character'Pos
                    (Text (Text'First + Sent + Natural (Index - Raw'First))));
            end loop;
            GNAT.Sockets.Send_Socket (Socket, Raw, Last);
            exit when Last < Raw'First;
            Sent := Sent + Natural (Last - Raw'First + 1);
         end;
      end loop;
   end Send_All;

   procedure Send_Response
     (Socket        : GNAT.Sockets.Socket_Type;
      Code          : String;
      Payload       : String := "";
      Extra_Headers : String := "")
   is
   begin
      Send_All
        (Socket,
         "HTTP/1.1 " & Code & CRLF &
         "Connection: close" & CRLF &
         "Content-Length: " & Image (Payload'Length) & CRLF &
         "Content-Type: application/octet-stream" & CRLF &
         Extra_Headers & CRLF & Payload);
   end Send_Response;


   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;

   SSL_Filetype_PEM : constant C.int := 1;

   function TLS_Server_Method return System.Address
     with Import, Convention => C, External_Name => "TLS_server_method";
   function SSL_CTX_New (Method : System.Address) return System.Address
     with Import, Convention => C, External_Name => "SSL_CTX_new";
   procedure SSL_CTX_Free (Context : System.Address)
     with Import, Convention => C, External_Name => "SSL_CTX_free";
   function SSL_CTX_Use_Certificate_File
     (Context : System.Address; File : CS.chars_ptr; Kind : C.int) return C.int
     with Import, Convention => C, External_Name => "SSL_CTX_use_certificate_file";
   function SSL_CTX_Use_PrivateKey_File
     (Context : System.Address; File : CS.chars_ptr; Kind : C.int) return C.int
     with Import, Convention => C, External_Name => "SSL_CTX_use_PrivateKey_file";
   function SSL_New (Context : System.Address) return System.Address
     with Import, Convention => C, External_Name => "SSL_new";
   procedure SSL_Free (SSL : System.Address)
     with Import, Convention => C, External_Name => "SSL_free";
   function SSL_Set_FD (SSL : System.Address; FD : C.int) return C.int
     with Import, Convention => C, External_Name => "SSL_set_fd";
   function SSL_Accept (SSL : System.Address) return C.int
     with Import, Convention => C, External_Name => "SSL_accept";
   function SSL_Read
     (SSL : System.Address; Buffer : System.Address; Num : C.int) return C.int
     with Import, Convention => C, External_Name => "SSL_read";
   function SSL_Write
     (SSL : System.Address; Buffer : System.Address; Num : C.int) return C.int
     with Import, Convention => C, External_Name => "SSL_write";

   procedure SSL_Write_All (SSL : System.Address; Text : String) is
      Sent : Natural := 0;
      N    : C.int;
   begin
      while Sent < Text'Length loop
         N := SSL_Write
           (SSL, Text (Text'First + Sent)'Address,
            C.int (Text'Length - Sent));
         exit when N <= 0;
         Sent := Sent + Natural (N);
      end loop;
   end SSL_Write_All;

   procedure Send_TLS_Response
     (SSL          : System.Address;
      Code         : String;
      Payload      : String := "";
      Extra_Headers : String := "")
   is
   begin
      SSL_Write_All
        (SSL,
         "HTTP/1.1 " & Code & CRLF &
         "Connection: close" & CRLF &
         "Content-Length: " & Image (Payload'Length) & CRLF &
         "Content-Type: application/octet-stream" & CRLF &
         Extra_Headers & CRLF & Payload);
   end Send_TLS_Response;

   procedure Receive_TLS_Request
     (SSL    : System.Address;
      Method : out Unbounded_String;
      Path   : out Unbounded_String;
      Headers : out Unbounded_String;
      Payload : out Unbounded_String)
   is
      Buffer : String (1 .. 4096);
      Text   : Unbounded_String;
      N      : C.int;
      End_Pos : Natural := 0;
      Length  : Natural := 0;
   begin
      Method := Null_Unbounded_String;
      Path := Null_Unbounded_String;
      Headers := Null_Unbounded_String;
      Payload := Null_Unbounded_String;

      loop
         N := SSL_Read (SSL, Buffer (Buffer'First)'Address, C.int (Buffer'Length));
         exit when N <= 0;
         Append (Text, Buffer (1 .. Natural (N)));
         declare
            Current : constant String := To_String (Text);
         begin
            End_Pos := Header_End (Current);
            if End_Pos /= 0 then
               Length := Content_Length (Current (Current'First .. End_Pos));
               exit when Current'Length >= End_Pos + Length;
            end if;
         end;
      end loop;

      declare
         Current : constant String := To_String (Text);
         First_Space  : Natural := 0;
         Second_Space : Natural := 0;
      begin
         for Index in Current'Range loop
            if Current (Index) = ' ' then
               First_Space := Index;
               exit;
            end if;
         end loop;

         if First_Space /= 0 then
            for Index in First_Space + 1 .. Current'Last loop
               if Current (Index) = ' ' then
                  Second_Space := Index;
                  exit;
               end if;
            end loop;

            Method := To_Unbounded_String
              (Current (Current'First .. First_Space - 1));
            if Second_Space /= 0 then
               Path := To_Unbounded_String
                 (Current (First_Space + 1 .. Second_Space - 1));
            end if;
         end if;

         if End_Pos /= 0 then
            Headers := To_Unbounded_String
              (Current (Current'First .. End_Pos));
         end if;

         if End_Pos /= 0 and then Length > 0 then
            Payload := To_Unbounded_String
              (Current (End_Pos + 1 .. End_Pos + Length));
         end if;
      end;
   end Receive_TLS_Request;

   task type HTTPS_Object_Store is
      entry Ready (Port : out Natural);
   end HTTPS_Object_Store;

   task body HTTPS_Object_Store is
      Server      : GNAT.Sockets.Socket_Type;
      Peer        : GNAT.Sockets.Socket_Type;
      Server_Addr : GNAT.Sockets.Sock_Addr_Type (GNAT.Sockets.Family_Inet);
      Peer_Addr   : GNAT.Sockets.Sock_Addr_Type;
      Context     : System.Address := System.Null_Address;
      Cert        : CS.chars_ptr := CS.Null_Ptr;
      Key         : CS.chars_ptr := CS.Null_Ptr;
      Object_Payload : Unbounded_String;
      Index_Payload  : Unbounded_String;
      Has_Object  : Boolean := False;
      Has_Index   : Boolean := False;
      Index_Version : Natural := 0;
      Request_Count : Natural := 0;
      Ready_To_Accept : Boolean := False;

      function Current_ETag return String is
      begin
         return Character'Val (34) & "https-index-" & Image (Index_Version) & Character'Val (34);
      end Current_ETag;
   begin
      GNAT.Sockets.Create_Socket (Server);
      GNAT.Sockets.Set_Socket_Option
        (Server, GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Reuse_Address, Enabled => True));
      Server_Addr.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Server_Addr.Port := 0;
      GNAT.Sockets.Bind_Socket (Server, Server_Addr);
      GNAT.Sockets.Listen_Socket (Server);

      Context := SSL_CTX_New (TLS_Server_Method);
      Cert := CS.New_String (Fixture_Path ("server.crt"));
      Key := CS.New_String (Fixture_Path ("server.key"));
      if Context = System.Null_Address
        or else SSL_CTX_Use_Certificate_File (Context, Cert, SSL_Filetype_PEM) /= 1
        or else SSL_CTX_Use_PrivateKey_File (Context, Key, SSL_Filetype_PEM) /= 1
      then
         CS.Free (Cert);
         CS.Free (Key);
         if Context /= System.Null_Address then
            SSL_CTX_Free (Context);
            Context := System.Null_Address;
         end if;
         GNAT.Sockets.Close_Socket (Server);
         accept Ready (Port : out Natural) do
            Port := 0;
         end Ready;
      else
         Ready_To_Accept := True;
      end if;
      if Ready_To_Accept then
         CS.Free (Cert);
         CS.Free (Key);
         Cert := CS.Null_Ptr;
         Key := CS.Null_Ptr;

         declare
            Bound : constant GNAT.Sockets.Sock_Addr_Type :=
              GNAT.Sockets.Get_Socket_Name (Server);
         begin
            accept Ready (Port : out Natural) do
               Port := Natural (Bound.Port);
            end Ready;
         end;
      end if;

      while Ready_To_Accept and then Request_Count < 11 loop
         declare
            SSL : System.Address := System.Null_Address;
         begin
            GNAT.Sockets.Accept_Socket (Server, Peer, Peer_Addr);
            SSL := SSL_New (Context);
            if SSL /= System.Null_Address
              and then SSL_Set_FD (SSL, C.int (GNAT.Sockets.To_C (Peer))) = 1
              and then SSL_Accept (SSL) = 1
            then
               declare
                  Method  : Unbounded_String;
                  Path    : Unbounded_String;
                  Headers : Unbounded_String;
                  Payload : Unbounded_String;
               begin
                  Receive_TLS_Request (SSL, Method, Path, Headers, Payload);
                  Request_Count := Request_Count + 1;
                  declare
                     M : constant String := To_String (Method);
                     P : constant String := Normalize_Path (To_String (Path));
                  begin
                     if M = "GET" and then P = "/https/" then
                        if Has_Index then
                           Send_TLS_Response
                             (SSL, "200 OK", To_String (Index_Payload),
                              "ETag: " & Current_ETag & CRLF);
                        else
                           Send_TLS_Response (SSL, "404 Not Found");
                        end if;
                     elsif M = "PUT" and then P = "/https/" then
                        declare
                           Request_Headers : constant String := To_String (Headers);
                           If_Match : constant String :=
                             Header_Value (Request_Headers, "If-Match");
                           If_None_Match : constant String :=
                             Header_Value (Request_Headers, "If-None-Match");
                        begin
                           if Has_Index and then If_Match /= Current_ETag then
                              Send_TLS_Response (SSL, "412 Precondition Failed");
                           elsif not Has_Index and then If_None_Match /= "*" then
                              Send_TLS_Response (SSL, "412 Precondition Failed");
                           else
                              Index_Payload := Payload;
                              Has_Index := True;
                              Index_Version := Index_Version + 1;
                              Send_TLS_Response
                                (SSL, "204 No Content", "",
                                 "ETag: " & Current_ETag & CRLF);
                           end if;
                        end;
                     elsif M = "PUT" and then P = "/https/secure.zip" then
                        Object_Payload := Payload;
                        Has_Object := True;
                        Send_TLS_Response (SSL, "201 Created");
                     elsif M = "GET" and then P = "/https/secure.zip" then
                        if Has_Object then
                           Send_TLS_Response (SSL, "200 OK", To_String (Object_Payload));
                        else
                           Send_TLS_Response (SSL, "404 Not Found");
                        end if;
                     elsif M = "DELETE" and then P = "/https/secure.zip" then
                        Has_Object := False;
                        Object_Payload := Null_Unbounded_String;
                        Send_TLS_Response (SSL, "204 No Content");
                     else
                        Send_TLS_Response (SSL, "404 Not Found");
                     end if;
                  end;
               end;
            end if;

            if SSL /= System.Null_Address then
               SSL_Free (SSL);
            end if;
            GNAT.Sockets.Close_Socket (Peer);
         exception
            when others =>
               if SSL /= System.Null_Address then
                  SSL_Free (SSL);
               end if;
               begin
                  GNAT.Sockets.Close_Socket (Peer);
               exception
                  when others =>
                     null;
               end;
         end;
      end loop;

      SSL_CTX_Free (Context);
      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         if Cert /= CS.Null_Ptr then
            CS.Free (Cert);
         end if;
         if Key /= CS.Null_Ptr then
            CS.Free (Key);
         end if;
         if Context /= System.Null_Address then
            SSL_CTX_Free (Context);
         end if;
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others =>
               null;
         end;
   end HTTPS_Object_Store;

   task type Fixture_Server is
      entry Ready (Port : out Natural);
   end Fixture_Server;

   task body Fixture_Server is
      use Ada.Streams;
      Server      : GNAT.Sockets.Socket_Type;
      Peer        : GNAT.Sockets.Socket_Type;
      Server_Addr : GNAT.Sockets.Sock_Addr_Type (GNAT.Sockets.Family_Inet);
      Peer_Addr   : GNAT.Sockets.Sock_Addr_Type;
      Object_Payload : Unbounded_String;
      Object_Crc32   : Unbounded_String;
      Index_Payload  : Unbounded_String;
      Has_Object  : Boolean := False;
      Has_Index   : Boolean := False;
      Index_Version : Natural := 0;
      S3_Upload_List_Page : Natural := 0;
      Drive_Object_Payload : Unbounded_String;
      Drive_Index_Payload  : Unbounded_String;
      Drive_Resumable_Started : Boolean := False;
      Has_Drive_Object : Boolean := False;
      Has_Drive_Index  : Boolean := False;
      PCloud_Object_Payload : Unbounded_String;
      PCloud_Object_Name    : Unbounded_String;
      PCloud_Index_Payload  : Unbounded_String;
      PCloud_Index_Name     : Unbounded_String;
      Has_PCloud_Object : Boolean := False;
      Has_PCloud_Index  : Boolean := False;
      Has_PCloud_Child_Folder : Boolean := False;
      Has_PCloud_Child_Temp : Boolean := False;
      Fail_Next_PCloud_Upload : Boolean := True;
      Fail_Next_Drive_List : Boolean := True;
      Fail_Next_Drive_Upload : Boolean := True;
      Fail_Next_Drive_Delete : Boolean := True;
      Fail_Next_Retry_Put : Boolean := True;
      Inject_Index_Conflict : Boolean := False;

      function Current_ETag return String is
      begin
         return Character'Val (34) & "index-" & Image (Index_Version) & Character'Val (34);
      end Current_ETag;

      procedure Receive_Request
        (Method  : out Unbounded_String;
         Path    : out Unbounded_String;
         Headers : out Unbounded_String;
         Payload : out Unbounded_String)
      is
         Raw : Stream_Element_Array (1 .. 4096);
         Last : Stream_Element_Offset;
         Text : Unbounded_String;
         End_Pos : Natural := 0;
         Length : Natural := 0;
      begin
         Method := Null_Unbounded_String;
         Path := Null_Unbounded_String;
         Headers := Null_Unbounded_String;
         Payload := Null_Unbounded_String;

         loop
            GNAT.Sockets.Receive_Socket (Peer, Raw, Last);
            exit when Last < Raw'First;
            for Index in Raw'First .. Last loop
               Append (Text, Character'Val (Raw (Index)));
            end loop;

            declare
               Current : constant String := To_String (Text);
            begin
               End_Pos := Header_End (Current);
               if End_Pos /= 0 then
                  Length := Content_Length (Current (Current'First .. End_Pos));
                  exit when Current'Length >= End_Pos + Length;
               end if;
            end;
         end loop;

         declare
            Current : constant String := To_String (Text);
            First_Space  : Natural := 0;
            Second_Space : Natural := 0;
         begin
            for Index in Current'Range loop
               if Current (Index) = ' ' then
                  First_Space := Index;
                  exit;
               end if;
            end loop;

            if First_Space /= 0 then
               for Index in First_Space + 1 .. Current'Last loop
                  if Current (Index) = ' ' then
                     Second_Space := Index;
                     exit;
                  end if;
               end loop;

               Method := To_Unbounded_String
                 (Current (Current'First .. First_Space - 1));
               if Second_Space /= 0 then
                  Path := To_Unbounded_String
                    (Current (First_Space + 1 .. Second_Space - 1));
               end if;
            end if;

            if End_Pos /= 0 then
               Headers := To_Unbounded_String
                 (Current (Current'First .. End_Pos));
            end if;

            if End_Pos /= 0 and then Length > 0 then
               Payload := To_Unbounded_String
                 (Current (End_Pos + 1 .. End_Pos + Length));
            end if;
         end;
      end Receive_Request;
   begin
      GNAT.Sockets.Create_Socket (Server);
      GNAT.Sockets.Set_Socket_Option
        (Server, GNAT.Sockets.Socket_Level,
         (Name => GNAT.Sockets.Reuse_Address, Enabled => True));
      Server_Addr.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Server_Addr.Port := 0;
      GNAT.Sockets.Bind_Socket (Server, Server_Addr);
      GNAT.Sockets.Listen_Socket (Server);

      declare
         Bound : constant GNAT.Sockets.Sock_Addr_Type :=
           GNAT.Sockets.Get_Socket_Name (Server);
      begin
         accept Ready (Port : out Natural) do
            Port := Natural (Bound.Port);
         end Ready;
      end;

      loop
         GNAT.Sockets.Accept_Socket (Server, Peer, Peer_Addr);
         declare
            Method  : Unbounded_String;
            Path    : Unbounded_String;
            Headers : Unbounded_String;
            Payload : Unbounded_String;
         begin
            Receive_Request (Method, Path, Headers, Payload);
            declare
               M : constant String := To_String (Method);
               Raw_Target : constant String := To_String (Path);
               P : constant String := Normalize_Path (Raw_Target);
               Is_S3_Part_Upload : constant Boolean :=
                 Ada.Strings.Fixed.Index (Raw_Target, "partNumber=") > 0;
               Is_S3_Initiate : constant Boolean :=
                 Ada.Strings.Fixed.Index (Raw_Target, "?uploads") > 0;
               Request_Headers : constant String := To_String (Headers);
               Auth_OK : constant Boolean :=
                 Header_Value (Request_Headers, "Authorization") =
                   "Bearer secret-token";
               S3_Auth_OK : constant Boolean :=
                 Starts_With
                   (Header_Value (Request_Headers, "Authorization"),
                    "AWS4-HMAC-SHA256 ")
                 and then Header_Value (Request_Headers, "x-amz-date")'Length = 16
                 and then Header_Value
                   (Request_Headers, "x-amz-content-sha256") =
                   "UNSIGNED-PAYLOAD";
               Virtual_S3 : constant Boolean :=
                 Starts_With (Header_Value (Request_Headers, "Host"), "s3-bucket.");
               SSE_OK : constant Boolean :=
                 Header_Value
                   (Request_Headers, "x-amz-server-side-encryption") = "aws:kms"
                 and then Header_Value
                   (Request_Headers,
                    "x-amz-server-side-encryption-aws-kms-key-id") = "kms-key";
               S3_Checksum_OK : constant Boolean :=
                 Header_Value (Request_Headers, "x-amz-checksum-crc32")'Length > 0;
               S3_Checksum_Algorithm_OK : constant Boolean :=
                 Header_Value (Request_Headers, "x-amz-checksum-algorithm") = "CRC32";
               Drive_Auth_OK : constant Boolean :=
                 Header_Value (Request_Headers, "Authorization") =
                   "Bearer drive-token"
                 or else Header_Value (Request_Headers, "Authorization") =
                   "Bearer refreshed-drive-token";
               PCloud_Auth_OK : constant Boolean :=
                 Header_Value (Request_Headers, "Authorization") =
                   "Bearer pcloud-token"
                 or else Header_Value (Request_Headers, "Authorization") =
                   "Bearer refreshed-pcloud-token";
            begin
               if (Starts_With (P, "/s3-bucket/") or else Virtual_S3)
                 and then not S3_Auth_OK
               then
                  Send_Response (Peer, "403 Forbidden");
               elsif (Virtual_S3 or else Starts_With (P, "/s3-bucket/"))
                 and then ((M = "PUT" and then not Is_S3_Part_Upload)
                           or else Is_S3_Initiate)
                 and then not SSE_OK
               then
                  Send_Response (Peer, "400 Bad Request");
               elsif (Virtual_S3 or else Starts_With (P, "/s3-bucket/"))
                 and then Is_S3_Initiate
                 and then not S3_Checksum_Algorithm_OK
               then
                  Send_Response (Peer, "400 Bad Request");
               elsif Starts_With (P, "/secure/") and then not Auth_OK then
                  Send_Response (Peer, "401 Unauthorized");
               elsif M = "POST" and then P = "/oauth/token" then
                  if Ada.Strings.Fixed.Index
                    (To_String (Payload), "grant_type=refresh_token") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "client_id=fixture-client") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "client_secret=fixture-secret") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "refresh_token=fixture-refresh") > 0
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""access_token"":""refreshed-drive-token""," &
                        """token_type"":""Bearer""," &
                        """expires_in"":3600}");
                  else
                     Send_Response (Peer, "400 Bad Request");
                  end if;
               elsif M = "POST" and then P = "/pcloud/oauth2_token" then
                  if Ada.Strings.Fixed.Index
                    (To_String (Payload), "grant_type=refresh_token") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "client_id=pcloud-client") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "refresh_token=pcloud-refresh") > 0
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""access_token"":""refreshed-pcloud-token""," &
                        """token_type"":""Bearer""," &
                        """expires_in"":3600}");
                  elsif Ada.Strings.Fixed.Index
                    (To_String (Payload), "grant_type=authorization_code") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "client_id=pcloud-client") > 0
                    and then Ada.Strings.Fixed.Index
                      (To_String (Payload), "code=pcloud-code") > 0
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""access_token"":""pcloud-code-token""," &
                        """refresh_token"":""pcloud-refresh""}");
                  else
                     Send_Response (Peer, "400 Bad Request");
                  end if;
               elsif M = "GET" and then P = "/shutdown" then
                  Send_Response (Peer, "200 OK", "ok" & ASCII.LF);
                  GNAT.Sockets.Close_Socket (Peer);
                  exit;
               elsif M = "GET" and then P = "/drop-s3-index" then
                  Has_Index := False;
                  Index_Payload := Null_Unbounded_String;
                  Send_Response (Peer, "200 OK", "ok" & ASCII.LF);
               elsif M = "GET" and then P = "/seed-pcloud-temp" then
                  Has_PCloud_Object := True;
                  PCloud_Object_Name :=
                    To_Unbounded_String ("backups/stale.zip.backup-upload-seeded");
                  PCloud_Object_Payload := To_Unbounded_String ("stale");
                  Send_Response (Peer, "200 OK", "ok" & ASCII.LF);
               elsif M = "GET" and then P = "/seed-pcloud-recursive-temp" then
                  Has_PCloud_Child_Folder := True;
                  Has_PCloud_Child_Temp := True;
                  Send_Response (Peer, "200 OK", "ok" & ASCII.LF);
               elsif Starts_With (P, "/pcloud/") and then not PCloud_Auth_OK then
                  Send_Response (Peer, "401 Unauthorized");
               elsif M = "GET" and then P = "/pcloud/createfolderifnotexists" then
                  Saw_PCloud_Path_Create := True;
                  if Ada.Strings.Fixed.Index (Raw_Target, "path=") > 0
                    and then Ada.Strings.Fixed.Index (Raw_Target, "NeedsParents") > 0
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":2005,""error"":""Directory does not exist""}");
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "folderid=") > 0 then
                     Saw_PCloud_Parent_Create := True;
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""metadata"":{""folderid"":888}}");
                  else
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""metadata"":{""folderid"":777}}");
                  end if;
               elsif M = "GET" and then P = "/pcloud/userinfo" then
                  Send_Response
                    (Peer, "200 OK",
                     "{""result"":0,""quota"":20000000,""usedquota"":1234,""freequota"":19998766}");
               elsif M = "GET" and then P = "/pcloud/uploadprogress" then
                  Saw_PCloud_Progress_Poll := True;
                  Send_Response
                    (Peer, "200 OK",
                     "{""result"":0,""total"":100,""uploaded"":100,""finished"":true}");
               elsif M = "GET" and then P = "/pcloud/listfolder" then
                  declare
                     Contents : Unbounded_String;
                     Needs_Comma : Boolean := False;

                     procedure Append_Comma is
                     begin
                        if Needs_Comma then
                           Append (Contents, ",");
                        end if;
                        Needs_Comma := True;
                     end Append_Comma;
                  begin
                     Append (Contents, "{ ""result"" : 0, ""metadata"" : { ""folderid"" : 777, ""contents"" : [");
                     if Ada.Strings.Fixed.Index (Raw_Target, "folderid=888") > 0 then
                        if Has_PCloud_Child_Temp then
                           Append_Comma;
                           Append
                             (Contents,
                              "{ ""name"" : ""nested.zip.backup-upload-seeded"", " &
                              """isfolder"" : false, ""fileid"" : 103 }");
                        end if;
                     else
                        if Has_PCloud_Object then
                           Append_Comma;
                           Append
                             (Contents,
                              "{ ""name"" : """ &
                              To_String (PCloud_Object_Name) &
                              """, ""isfolder"" : false, ""fileid"" : 101 }");
                        end if;
                        if Has_PCloud_Index then
                           Append_Comma;
                           Append
                             (Contents,
                              "{ ""name"" : """ &
                              To_String (PCloud_Index_Name) &
                              """, ""isfolder"" : false, ""fileid"" : 102 }");
                        end if;
                        if Has_PCloud_Child_Folder then
                           Append_Comma;
                           Append
                             (Contents,
                              "{ ""name"" : ""nested"", ""isfolder"" : true, " &
                              """folderid"" : 888 }");
                        end if;
                     end if;
                     Append (Contents, "] } }");
                     Send_Response (Peer, "200 OK", To_String (Contents));
                  end;
               elsif M = "PUT" and then P = "/pcloud/uploadfile" then
                  if Ada.Strings.Fixed.Index (Raw_Target, "progresshash=") > 0 then
                     Saw_PCloud_Progress_Hash := True;
                  end if;
                  if Ada.Strings.Fixed.Index (Raw_Target, "backup-remote-index-v1") = 0
                    and then Fail_Next_PCloud_Upload
                  then
                     Fail_Next_PCloud_Upload := False;
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":4000,""error"":""temporary pCloud throttle""}");
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "backup-remote-index-v1") > 0 then
                     PCloud_Index_Payload := Payload;
                     PCloud_Index_Name := To_Unbounded_String ("backup-remote-index-v1.backup-upload");
                     Has_PCloud_Index := True;
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""fileids"":[102],""metadata"":[{""fileid"":102,""isfolder"":false}]}");
                  else
                     PCloud_Archive_Upload_Count := PCloud_Archive_Upload_Count + 1;
                     PCloud_Object_Payload := Payload;
                     if Ada.Strings.Fixed.Index (Raw_Target, "large-pcloud.zip") > 0 then
                        PCloud_Object_Name := To_Unbounded_String ("large-pcloud.zip.backup-upload");
                     elsif Ada.Strings.Fixed.Index (Raw_Target, "path-local.zip") > 0 then
                        PCloud_Object_Name := To_Unbounded_String ("path-local.zip.backup-upload");
                     elsif Ada.Strings.Fixed.Index (Raw_Target, "parents-pcloud.zip") > 0 then
                        PCloud_Object_Name := To_Unbounded_String ("parents-pcloud.zip.backup-upload");
                     elsif Ada.Strings.Fixed.Index (Raw_Target, "sha1-bad-pcloud.zip") > 0 then
                        PCloud_Object_Name := To_Unbounded_String ("backups/sha1-bad-pcloud.zip.backup-upload");
                     elsif Ada.Strings.Fixed.Index (Raw_Target, "sha1-pcloud.zip") > 0 then
                        PCloud_Object_Name := To_Unbounded_String ("backups/sha1-pcloud.zip.backup-upload");
                     else
                        PCloud_Object_Name := To_Unbounded_String ("local.zip.backup-upload");
                     end if;
                     if Ada.Strings.Fixed.Index (Raw_Target, ".backup-upload-") > 0 then
                        Saw_PCloud_Nonce_Temp_Name := True;
                     end if;
                     Has_PCloud_Object := True;
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""fileids"":[101],""metadata"":[{""fileid"":101,""isfolder"":false}]}");
                  end if;
               elsif M = "GET" and then P = "/pcloud/renamefile" then
                  Saw_PCloud_Rename := True;
                  if Fail_Next_PCloud_Rename then
                     Fail_Next_PCloud_Rename := False;
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":4000,""error"":""temporary pCloud rename failure""}");
                  else
                     if Ada.Strings.Fixed.Index (Raw_Target, "fileid=101") > 0 then
                        if Ada.Strings.Fixed.Index (Raw_Target, "large-pcloud.zip") > 0 then
                           PCloud_Object_Name := To_Unbounded_String ("backups/large-pcloud.zip");
                        elsif Ada.Strings.Fixed.Index (Raw_Target, "path-local.zip") > 0 then
                           PCloud_Object_Name := To_Unbounded_String ("path-local.zip");
                        elsif Ada.Strings.Fixed.Index (Raw_Target, "parents-pcloud.zip") > 0 then
                           PCloud_Object_Name := To_Unbounded_String ("parents-pcloud.zip");
                        elsif Ada.Strings.Fixed.Index (Raw_Target, "sha1-bad-pcloud.zip") > 0 then
                           PCloud_Object_Name := To_Unbounded_String ("backups/sha1-bad-pcloud.zip");
                        elsif Ada.Strings.Fixed.Index (Raw_Target, "sha1-pcloud.zip") > 0 then
                           PCloud_Object_Name := To_Unbounded_String ("backups/sha1-pcloud.zip");
                        else
                           PCloud_Object_Name := To_Unbounded_String ("backups/local.zip");
                        end if;
                     elsif Ada.Strings.Fixed.Index (Raw_Target, "fileid=102") > 0 then
                        if Ada.Strings.Fixed.Index (Raw_Target, "backups") > 0
                          and then Ada.Strings.Fixed.Index (Raw_Target, "backup-remote-index-v1") > 0
                        then
                           PCloud_Index_Name := To_Unbounded_String ("backups/backup-remote-index-v1");
                        else
                           PCloud_Index_Name := To_Unbounded_String ("backup-remote-index-v1");
                        end if;
                     end if;
                     Send_Response (Peer, "200 OK", "{""result"":0}");
                  end if;
               elsif M = "GET" and then P = "/pcloud/checksumfile" then
                  if Ada.Strings.Fixed.Index (Raw_Target, "fileid=101") > 0
                    and then Has_PCloud_Object
                  then
                     if To_String (PCloud_Object_Name) = "backups/sha1-pcloud.zip" then
                        Send_Response
                          (Peer, "200 OK",
                           "{""result"":0,""metadata"":{""size"":" &
                           Image (Length (PCloud_Object_Payload)) &
                           ",""sha1"":""" &
                           SHA1_File (Ada.Directories.Compose (Root, "sha1-pcloud.zip")) &
                           """}}");
                     elsif To_String (PCloud_Object_Name) = "backups/sha1-bad-pcloud.zip" then
                        Send_Response
                          (Peer, "200 OK",
                           "{""result"":0,""metadata"":{""size"":" &
                           Image (Length (PCloud_Object_Payload)) &
                           ",""sha1"":""0000000000000000000000000000000000000000""}}");
                     elsif Length (PCloud_Object_Payload) > 1024 * 1024 then
                        Send_Response
                          (Peer, "200 OK",
                           "{""result"":0,""metadata"":{""size"":" &
                           Image (Length (PCloud_Object_Payload)) & "}}");
                     else
                        Send_Response
                          (Peer, "200 OK",
                           "{""result"":0,""metadata"":{""size"":" &
                           Image (Length (PCloud_Object_Payload)) &
                           ",""sha256"":""" &
                           Http_Client.Crypto.Digest_SHA256_Hex
                             (To_String (PCloud_Object_Payload)) &
                           """}}");
                     end if;
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "fileid=102") > 0
                    and then Has_PCloud_Index
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""metadata"":{""size"":" &
                        Image (Length (PCloud_Index_Payload)) & "}}");
                  else
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":2009,""error"":""File not found""}");
                  end if;
               elsif M = "GET" and then P = "/pcloud/getfilelink" then
                  if Ada.Strings.Fixed.Index (Raw_Target, "fileid=101") > 0
                    and then Has_PCloud_Object
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""url"":""http://" &
                        Header_Value (Request_Headers, "Host") &
                        "/pcloud-download/object""}");
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "fileid=102") > 0
                    and then Has_PCloud_Index
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "{""result"":0,""url"":""http://" &
                        Header_Value (Request_Headers, "Host") &
                        "/pcloud-download/index""}");
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "GET" and then P = "/pcloud/deletefile" then
                  if Ada.Strings.Fixed.Index (Raw_Target, "fileid=101") > 0 then
                     Saw_PCloud_Temp_Cleanup := True;
                     Has_PCloud_Object := False;
                     PCloud_Object_Payload := Null_Unbounded_String;
                     PCloud_Object_Name := Null_Unbounded_String;
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "fileid=102") > 0 then
                     Has_PCloud_Index := False;
                     PCloud_Index_Payload := Null_Unbounded_String;
                     PCloud_Index_Name := Null_Unbounded_String;
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "fileid=103") > 0 then
                     Saw_PCloud_Temp_Cleanup := True;
                     Has_PCloud_Child_Temp := False;
                  end if;
                  Send_Response (Peer, "200 OK", "{""result"":0}");
               elsif M = "GET" and then P = "/pcloud-download/object" then
                  if Has_PCloud_Object then
                     Send_Response (Peer, "200 OK", To_String (PCloud_Object_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "GET" and then P = "/pcloud-download/index" then
                  if Has_PCloud_Index then
                     Send_Response (Peer, "200 OK", To_String (PCloud_Index_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif Starts_With (P, "/drive/v3/")
                 and then not Drive_Auth_OK
               then
                  Send_Response (Peer, "401 Unauthorized");
               elsif Starts_With (P, "/upload/drive/v3/")
                 and then not Drive_Auth_OK
               then
                  Send_Response (Peer, "401 Unauthorized");
               elsif M = "GET" and then P = "/drive/v3/files"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "backup-remote-index-v1") > 0
               then
                  if Has_Drive_Index then
                     Send_Response
                       (Peer, "200 OK",
                        "{""files"":[{""id"":""drive-index"",""name"":""backup-remote-index-v1""}]}");
                  else
                     Send_Response (Peer, "200 OK", "{""files"":[]}");
                  end if;
               elsif M = "GET" and then P = "/drive/v3/files"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "retry-drive.zip") > 0
                 and then Fail_Next_Drive_List
               then
                  Fail_Next_Drive_List := False;
                  Send_Response
                    (Peer, "403 Forbidden",
                     "{""error"":{""errors"":[{""reason"":""rateLimitExceeded""}]}}");
               elsif M = "GET" and then P = "/drive/v3/files"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "retry-drive.zip") > 0
               then
                  if Has_Drive_Object then
                     Send_Response
                       (Peer, "200 OK",
                        "{""files"":[{""id"":""drive-object"",""name"":""backups/retry-drive.zip""}]}");
                  else
                     Send_Response (Peer, "200 OK", "{""files"":[]}");
                  end if;
               elsif M = "GET" and then P = "/drive/v3/files"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "local.zip") > 0
               then
                  if Has_Drive_Object then
                     Send_Response
                       (Peer, "200 OK",
                        "{""files"":[{""id"":""drive-object"",""name"":""backups/local.zip""}]}");
                  else
                     Send_Response (Peer, "200 OK", "{""files"":[]}");
                  end if;
               elsif M = "GET" and then P = "/drive/v3/files/drive-object" then
                  if Has_Drive_Object then
                     Send_Response (Peer, "200 OK", To_String (Drive_Object_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "GET" and then P = "/drive/v3/files/drive-index" then
                  if Has_Drive_Index then
                     Send_Response (Peer, "200 OK", To_String (Drive_Index_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "POST" and then P = "/upload/drive/v3/files"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "uploadType=resumable") > 0
               then
                  Drive_Resumable_Started := True;
                  Send_Response
                    (Peer, "200 OK", "",
                     "Location: http://" & Header_Value (Request_Headers, "Host") &
                     "/drive-upload-session" & CRLF);
               elsif M = "PUT" and then P = "/drive-upload-session" then
                  if Drive_Resumable_Started then
                     Drive_Object_Payload := Payload;
                     Has_Drive_Object := True;
                     Send_Response (Peer, "200 OK", "{""id"":""drive-object""}");
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "POST" and then P = "/upload/drive/v3/files"
                 and then Ada.Strings.Fixed.Index (To_String (Payload), "retry-drive.zip") > 0
                 and then Fail_Next_Drive_Upload
               then
                  Fail_Next_Drive_Upload := False;
                  Send_Response (Peer, "429 Too Many Requests", "{""error"":""rateLimitExceeded""}");
               elsif (M = "POST" and then P = "/upload/drive/v3/files")
                 or else (M = "PATCH" and then P = "/upload/drive/v3/files/drive-object")
                 or else (M = "PATCH" and then P = "/upload/drive/v3/files/drive-index")
               then
                  if Ada.Strings.Fixed.Index (To_String (Payload), "backup-remote-index-v1") > 0 then
                     Drive_Index_Payload := To_Unbounded_String
                       (Extract_Drive_Multipart_Content (To_String (Payload)));
                     Has_Drive_Index := True;
                     Send_Response (Peer, "200 OK", "{""id"":""drive-index""}");
                  else
                     Drive_Object_Payload := To_Unbounded_String
                       (Extract_Drive_Multipart_Content (To_String (Payload)));
                     Has_Drive_Object := True;
                     Send_Response (Peer, "200 OK", "{""id"":""drive-object""}");
                  end if;
               elsif M = "DELETE" and then P = "/drive/v3/files/drive-object"
                 and then Fail_Next_Drive_Delete
               then
                  Fail_Next_Drive_Delete := False;
                  Send_Response (Peer, "500 Internal Server Error");
               elsif M = "DELETE" and then P = "/drive/v3/files/drive-object" then
                  Has_Drive_Object := False;
                  Drive_Object_Payload := Null_Unbounded_String;
                  Send_Response (Peer, "204 No Content");
               elsif M = "DELETE" and then P = "/drive/v3/files/drive-index" then
                  Has_Drive_Index := False;
                  Drive_Index_Payload := Null_Unbounded_String;
                  Send_Response (Peer, "204 No Content");
               elsif M = "GET" and then P = "/s3-bucket"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "list-type=2") > 0
               then
                  if Has_Object then
                     Send_Response
                       (Peer, "200 OK",
                        "<ListBucketResult>" &
                        "<IsTruncated>false</IsTruncated>" &
                        "<Contents><Key>backups/local.zip</Key>" &
                        "<LastModified>2026-06-12T10:11:12.000Z</LastModified>" &
                        "<Size>" & Image (Length (Object_Payload)) & "</Size>" &
                        "</Contents></ListBucketResult>");
                  else
                     Send_Response
                       (Peer, "200 OK",
                        "<ListBucketResult><IsTruncated>false</IsTruncated>" &
                        "</ListBucketResult>");
                  end if;
               elsif M = "GET" and then P = "/s3-bucket"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "uploads=") > 0
               then
                  S3_Upload_List_Page := S3_Upload_List_Page + 1;
                  if S3_Upload_List_Page = 1 then
                     Send_Response
                       (Peer, "200 OK",
                        "<ListMultipartUploadsResult>" &
                        "<IsTruncated>true</IsTruncated>" &
                        "<Upload><Key>backups/older.zip</Key>" &
                        "<UploadId>old-upload</UploadId></Upload>" &
                        "<NextKeyMarker>backups/older.zip</NextKeyMarker>" &
                        "<NextUploadIdMarker>old-upload</NextUploadIdMarker>" &
                        "</ListMultipartUploadsResult>");
                  elsif Ada.Strings.Fixed.Index (Raw_Target, "key-marker=") > 0
                    and then Ada.Strings.Fixed.Index (Raw_Target, "upload-id-marker=") > 0
                  then
                     Send_Response
                       (Peer, "200 OK",
                        "<ListMultipartUploadsResult>" &
                        "<IsTruncated>false</IsTruncated>" &
                        "</ListMultipartUploadsResult>");
                  else
                     Send_Response (Peer, "400 Bad Request");
                  end if;
               elsif M = "GET"
                 and then P = "/s3-bucket/backups/backup-remote-index-v1"
               then
                  if Has_Index then
                     Send_Response
                       (Peer, "200 OK", To_String (Index_Payload),
                        "ETag: " & Current_ETag & CRLF);
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "PUT"
                 and then P = "/s3-bucket/backups/backup-remote-index-v1"
               then
                  declare
                     If_Match : constant String :=
                       Header_Value (Request_Headers, "If-Match");
                     If_None_Match : constant String :=
                       Header_Value (Request_Headers, "If-None-Match");
                  begin
                     if Has_Index and then If_Match /= Current_ETag then
                        Send_Response (Peer, "412 Precondition Failed");
                     elsif not Has_Index and then If_None_Match /= "*" then
                        Send_Response (Peer, "412 Precondition Failed");
                     else
                        Index_Payload := Payload;
                        Has_Index := True;
                        Index_Version := Index_Version + 1;
                        Send_Response
                          (Peer, "204 No Content", "",
                           "ETag: " & Current_ETag & CRLF);
                     end if;
                  end;
               elsif M = "POST" and then P = "/s3-bucket/backups/local.zip"
                 and then Is_S3_Initiate
               then
                  Object_Payload := Null_Unbounded_String;
                  Object_Crc32 := To_Unbounded_String
                    (Header_Value (Request_Headers, "x-amz-meta-backup-crc32"));
                  Has_Object := False;
                  Send_Response
                    (Peer, "200 OK",
                     "<InitiateMultipartUploadResult><UploadId>upload-1" &
                     "</UploadId></InitiateMultipartUploadResult>");
               elsif M = "PUT" and then P = "/s3-bucket/backups/local.zip"
                 and then Is_S3_Part_Upload
                 and then not S3_Checksum_OK
               then
                  Send_Response (Peer, "400 Bad Request");
               elsif M = "PUT" and then P = "/s3-bucket/backups/local.zip"
                 and then Is_S3_Part_Upload
               then
                  Append (Object_Payload, To_String (Payload));
                  Send_Response
                    (Peer, "200 OK", "",
                     "ETag: " & Character'Val (34) & "part-" &
                     Image (Content_Length (Request_Headers)) &
                     Character'Val (34) & CRLF);
               elsif M = "POST" and then P = "/s3-bucket/backups/local.zip"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "uploadId=upload-1") > 0
                 and then Ada.Strings.Fixed.Index (To_String (Payload), "<ChecksumCRC32>") = 0
               then
                  Send_Response (Peer, "400 Bad Request");
               elsif M = "POST" and then P = "/s3-bucket/backups/local.zip"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "uploadId=upload-1") > 0
               then
                  Has_Object := True;
                  Send_Response (Peer, "200 OK");
               elsif M = "DELETE" and then P = "/s3-bucket/backups/local.zip"
                 and then Ada.Strings.Fixed.Index (Raw_Target, "uploadId=upload-1") > 0
               then
                  Has_Object := False;
                  Object_Payload := Null_Unbounded_String;
                  Object_Crc32 := Null_Unbounded_String;
                  Send_Response (Peer, "204 No Content");
               elsif M = "PUT" and then P = "/s3-bucket/backups/local.zip"
                 and then not S3_Checksum_OK
               then
                  Send_Response (Peer, "400 Bad Request");
               elsif M = "PUT" and then P = "/s3-bucket/backups/local.zip" then
                  Object_Payload := Payload;
                  Object_Crc32 := To_Unbounded_String
                    (Header_Value (Request_Headers, "x-amz-meta-backup-crc32"));
                  Has_Object := True;
                  Send_Response (Peer, "201 Created");
               elsif M = "HEAD" and then P = "/s3-bucket/backups/local.zip" then
                  if Has_Object then
                     Send_Response
                       (Peer, "200 OK", "",
                        "x-amz-meta-backup-crc32: " & To_String (Object_Crc32) & CRLF);
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "GET" and then P = "/s3-bucket/backups/local.zip" then
                  if Has_Object then
                     Send_Response (Peer, "200 OK", To_String (Object_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "DELETE" and then P = "/s3-bucket/backups/local.zip" then
                  Has_Object := False;
                  Object_Payload := Null_Unbounded_String;
                  Object_Crc32 := Null_Unbounded_String;
                  Send_Response (Peer, "204 No Content");
               elsif M = "GET" and then (P = "/backups/" or else P = "/secure/") then
                  if Has_Index then
                     Send_Response
                       (Peer, "200 OK", To_String (Index_Payload),
                        "ETag: " & Current_ETag & CRLF);
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "PUT" and then (P = "/backups/" or else P = "/secure/") then
                  declare
                     Request_Headers : constant String := To_String (Headers);
                     If_Match : constant String :=
                       Header_Value (Request_Headers, "If-Match");
                     If_None_Match : constant String :=
                       Header_Value (Request_Headers, "If-None-Match");
                  begin
                     if Has_Index and then If_Match /= Current_ETag then
                        Send_Response (Peer, "412 Precondition Failed");
                     elsif not Has_Index and then If_None_Match /= "*" then
                        Send_Response (Peer, "412 Precondition Failed");
                     elsif Inject_Index_Conflict then
                        Inject_Index_Conflict := False;
                        Index_Version := Index_Version + 1;
                        Send_Response (Peer, "412 Precondition Failed");
                     else
                        Index_Payload := Payload;
                        Has_Index := True;
                        Index_Version := Index_Version + 1;
                        Send_Response
                          (Peer, "204 No Content", "",
                           "ETag: " & Current_ETag & CRLF);
                     end if;
                  end;
               elsif M = "PUT" and then P = "/backups/local.zip" then
                  Object_Payload := Payload;
                  Has_Object := True;
                  Send_Response (Peer, "201 Created");
               elsif M = "PUT" and then P = "/backups/retry.zip" then
                  if Fail_Next_Retry_Put then
                     Fail_Next_Retry_Put := False;
                     Send_Response (Peer, "503 Service Unavailable");
                  else
                     Object_Payload := Payload;
                     Has_Object := True;
                     Inject_Index_Conflict := True;
                     Send_Response (Peer, "201 Created");
                  end if;
               elsif M = "PUT" and then P = "/secure/secure.zip" then
                  Object_Payload := Payload;
                  Has_Object := True;
                  Send_Response (Peer, "201 Created");
               elsif M = "GET" and then P = "/backups/local.zip" then
                  if Has_Object then
                     Send_Response (Peer, "200 OK", To_String (Object_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "GET" and then P = "/backups/retry.zip" then
                  if Has_Object then
                     Send_Response (Peer, "200 OK", To_String (Object_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "GET" and then P = "/secure/secure.zip" then
                  if Has_Object then
                     Send_Response (Peer, "200 OK", To_String (Object_Payload));
                  else
                     Send_Response (Peer, "404 Not Found");
                  end if;
               elsif M = "DELETE" and then P = "/backups/local.zip" then
                  Has_Object := False;
                  Object_Payload := Null_Unbounded_String;
                  Object_Crc32 := Null_Unbounded_String;
                  Send_Response (Peer, "204 No Content");
               else
                  Send_Response (Peer, "404 Not Found");
               end if;
            end;
            GNAT.Sockets.Close_Socket (Peer);
         exception
            when others =>
               begin
                  GNAT.Sockets.Close_Socket (Peer);
               exception
                  when others =>
                     null;
               end;
         end;
      end loop;

      GNAT.Sockets.Close_Socket (Server);
   end Fixture_Server;

   procedure Shutdown (Port : Natural) is
      Socket : GNAT.Sockets.Socket_Type;
      Addr   : GNAT.Sockets.Sock_Addr_Type (GNAT.Sockets.Family_Inet);
   begin
      GNAT.Sockets.Create_Socket (Socket);
      Addr.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Addr.Port := GNAT.Sockets.Port_Type (Port);
      GNAT.Sockets.Connect_Socket (Socket, Addr);
      Send_All
        (Socket,
         "GET /shutdown HTTP/1.1" & CRLF &
         "Host: 127.0.0.1" & CRLF &
         "Connection: close" & CRLF & CRLF);
      GNAT.Sockets.Close_Socket (Socket);
   exception
      when others =>
         null;
   end Shutdown;


   procedure Seed_PCloud_Temp (Port : Natural) is
      Socket : GNAT.Sockets.Socket_Type;
      Addr   : GNAT.Sockets.Sock_Addr_Type (GNAT.Sockets.Family_Inet);
   begin
      GNAT.Sockets.Create_Socket (Socket);
      Addr.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Addr.Port := GNAT.Sockets.Port_Type (Port);
      GNAT.Sockets.Connect_Socket (Socket, Addr);
      Send_All
        (Socket,
         "GET /seed-pcloud-temp HTTP/1.1" & CRLF &
         "Host: 127.0.0.1" & CRLF &
         "Connection: close" & CRLF & CRLF);
      GNAT.Sockets.Close_Socket (Socket);
   exception
      when others =>
         null;
   end Seed_PCloud_Temp;


   procedure Seed_PCloud_Recursive_Temp (Port : Natural) is
      Socket : GNAT.Sockets.Socket_Type;
      Addr   : GNAT.Sockets.Sock_Addr_Type (GNAT.Sockets.Family_Inet);
   begin
      GNAT.Sockets.Create_Socket (Socket);
      Addr.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Addr.Port := GNAT.Sockets.Port_Type (Port);
      GNAT.Sockets.Connect_Socket (Socket, Addr);
      Send_All
        (Socket,
         "GET /seed-pcloud-recursive-temp HTTP/1.1" & CRLF &
         "Host: 127.0.0.1" & CRLF &
         "Connection: close" & CRLF & CRLF);
      GNAT.Sockets.Close_Socket (Socket);
   exception
      when others =>
         null;
   end Seed_PCloud_Recursive_Temp;


   procedure Drop_S3_Index (Port : Natural) is
      Socket : GNAT.Sockets.Socket_Type;
      Addr   : GNAT.Sockets.Sock_Addr_Type (GNAT.Sockets.Family_Inet);
   begin
      GNAT.Sockets.Create_Socket (Socket);
      Addr.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Addr.Port := GNAT.Sockets.Port_Type (Port);
      GNAT.Sockets.Connect_Socket (Socket, Addr);
      Send_All
        (Socket,
         "GET /drop-s3-index HTTP/1.1" & CRLF &
         "Host: 127.0.0.1" & CRLF &
         "Connection: close" & CRLF & CRLF);
      GNAT.Sockets.Close_Socket (Socket);
   exception
      when others =>
         null;
   end Drop_S3_Index;

   Server : Fixture_Server;
   Port   : Natural;
   URL    : Unbounded_String;
   Status : Backup.Remote.Remote_Status;
   Report : Backup.Remote.Transfer_Report;
   Diagnostic : Unbounded_String;
   Inventory : Backup.Remote.Archive_Metadata_Vectors.Vector;
begin
   if Ada.Directories.Exists (Root) then
      Project_Tools.Files.Delete_Tree (Root);
   end if;
   Ada.Directories.Create_Path (Root);
   Write_File (Local, "archive" & ASCII.LF);
   Write_File (Retry_Local, "retry archive" & ASCII.LF);
   Write_File (Secure_Local, "secure archive" & ASCII.LF);

   Server.Ready (Port);
   URL := To_Unbounded_String ("http://127.0.0.1:" & Image (Port) & "/backups/");

   Status := Backup.Remote.Upload_Archive
     (To_String (URL), Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP upload, readback verify, and index publish succeed: " &
          To_String (Diagnostic));
   Check (Report.Verified, "HTTP upload report is verified");

   Status := Backup.Remote.Read_Inventory
     (To_String (URL), Local, Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP inventory reads published index: " & To_String (Diagnostic));
   declare
      Saw_Local : Boolean := False;
   begin
      for Item of Inventory loop
         if To_String (Item.Archive_Id) = "local.zip" then
            Saw_Local := True;
            Check (Item.Size = Report.Size, "HTTP index preserves size");
            Check (Item.Crc32 = Report.Crc32, "HTTP index preserves CRC32");
            Check (Item.Has_Timestamp, "HTTP index exposes timestamp");
         end if;
      end loop;
      Check (Saw_Local, "HTTP inventory includes uploaded object");
   end;

   Status := Backup.Remote.Download_Archive
     (To_String (URL) & "local.zip", Restored,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP download succeeds: " & To_String (Diagnostic));
   Check (Ada.Directories.Exists (Restored), "HTTP download writes local file");

   Status := Backup.Remote.Verify_Remote_Archive
     (To_String (URL), Local, Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP verify succeeds: " & To_String (Diagnostic));

   Status := Backup.Remote.Delete_Remote_Object
     (To_String (URL), Local, "local.zip", Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP delete and index removal succeed: " & To_String (Diagnostic));

   Status := Backup.Remote.Read_Inventory
     (To_String (URL), Local, Inventory, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP inventory reads index after delete: " & To_String (Diagnostic));
   declare
      Saw_Local : Boolean := False;
   begin
      for Item of Inventory loop
         if To_String (Item.Archive_Id) = "local.zip" then
            Saw_Local := True;
         end if;
      end loop;
      Check (not Saw_Local, "HTTP index no longer contains deleted object");
   end;

   Status := Backup.Remote.Download_Archive
     (To_String (URL) & "local.zip", Restored,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 0,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Not_Found,
          "HTTP download reports not found after delete");

   Status := Backup.Remote.Upload_Archive
     (To_String (URL), Retry_Local,
      (Require_Encrypted => False,
       Upload_Behavior   => Backup.Remote.Upload_Atomic,
       Retry_Count       => 1,
       Timeout_Seconds   => 60,
       others            => <>),
      Report, Diagnostic);
   Check (Status = Backup.Remote.Remote_Ok,
          "HTTP upload retries a failed streaming PUT: " &
          To_String (Diagnostic));
   Check (Report.Retried = 1,
          "HTTP upload reports the streaming retry attempt");
   Check (Report.Verified, "HTTP index conflict is refetched and retried");

   declare
      Auth_URL : constant String :=
        "http://127.0.0.1:" & Image (Port) & "/secure/";
      Auth_Options : constant Backup.Remote.Remote_Options :=
        (Require_Encrypted => False,
         Upload_Behavior   => Backup.Remote.Upload_Atomic,
         Retry_Count       => 0,
         Timeout_Seconds   => 60,
         HTTP_Auth         => Backup.Remote.HTTP_Auth_Bearer,
         HTTP_Bearer_Token => To_Unbounded_String ("secret-token"),
         others            => <>);
   begin
      Status := Backup.Remote.Upload_Archive
        (Auth_URL, Secure_Local, Auth_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "authenticated HTTP upload, verify, and index publish succeed: " &
             To_String (Diagnostic));
      Check (Report.Verified, "authenticated HTTP upload report is verified");

      Status := Backup.Remote.Read_Inventory
        (Auth_URL, Secure_Local, Auth_Options, Inventory, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "authenticated HTTP inventory succeeds: " &
             To_String (Diagnostic));

      Status := Backup.Remote.Download_Archive
        (Auth_URL & "secure.zip", Secure_Restored, Auth_Options, Report,
         Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "authenticated HTTP download succeeds: " &
             To_String (Diagnostic));
   end;

   declare
      HTTPS_Server : HTTPS_Object_Store;
      HTTPS_Port   : Natural := 0;
      HTTPS_URL    : Unbounded_String;
      HTTPS_Restored : constant String := Path ("https-restored.zip");
      HTTPS_Options : constant Backup.Remote.Remote_Options :=
        (Require_Encrypted => False,
         Upload_Behavior   => Backup.Remote.Upload_Atomic,
         Retry_Count       => 0,
         Timeout_Seconds   => 60,
         TLS_CA_File       => To_Unbounded_String (Fixture_Path ("ca.crt")),
         others            => <>);
   begin
      HTTPS_Server.Ready (HTTPS_Port);
      Check (HTTPS_Port > 0, "HTTPS mutable object-store fixture starts");
      if HTTPS_Port > 0 then
         HTTPS_URL := To_Unbounded_String
           ("https://127.0.0.1:" & Image (HTTPS_Port) & "/https/");

         Status := Backup.Remote.Upload_Archive
           (To_String (HTTPS_URL), Secure_Local, HTTPS_Options, Report,
            Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "HTTPS upload, readback verify, and index publish succeed: " &
                To_String (Diagnostic));
         Check (Report.Transport = Backup.Remote.Transport_HTTPS,
                "HTTPS upload report records HTTPS transport");
         Check (Report.Verified, "HTTPS upload report is verified");

         Status := Backup.Remote.Read_Inventory
           (To_String (HTTPS_URL), Secure_Local, HTTPS_Options, Inventory,
            Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "HTTPS inventory reads published index: " &
                To_String (Diagnostic));
         declare
            Saw_Secure : Boolean := False;
         begin
            for Item of Inventory loop
               if To_String (Item.Archive_Id) = "secure.zip" then
                  Saw_Secure := True;
                  Check (Item.Size = Report.Size, "HTTPS index preserves size");
                  Check (Item.Crc32 = Report.Crc32, "HTTPS index preserves CRC32");
               end if;
            end loop;
            Check (Saw_Secure, "HTTPS inventory includes uploaded object");
         end;

         Status := Backup.Remote.Download_Archive
           (To_String (HTTPS_URL) & "secure.zip", HTTPS_Restored,
            HTTPS_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "HTTPS download and verification succeed: " &
                To_String (Diagnostic));
         Check (Ada.Directories.Exists (HTTPS_Restored),
                "HTTPS download writes local file");

         Status := Backup.Remote.Delete_Remote_Object
           (To_String (HTTPS_URL), Secure_Local, "secure.zip", HTTPS_Options,
            Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "HTTPS delete and index removal succeed: " &
                To_String (Diagnostic));

         Status := Backup.Remote.Read_Inventory
           (To_String (HTTPS_URL), Secure_Local, HTTPS_Options, Inventory,
            Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "HTTPS inventory reads index after delete: " &
                To_String (Diagnostic));
         declare
            Saw_Secure : Boolean := False;
         begin
            for Item of Inventory loop
               if To_String (Item.Archive_Id) = "secure.zip" then
                  Saw_Secure := True;
               end if;
            end loop;
            Check (not Saw_Secure,
                   "HTTPS index no longer contains deleted object");
         end;
      end if;
   end;

   declare
      Drive_URL : constant String := "gdrive://folder-123/backups/";
      Drive_Restored : constant String := Path ("drive-restored.zip");
      Drive_Options : constant Backup.Remote.Remote_Options :=
        (Require_Encrypted => False,
         Upload_Behavior   => Backup.Remote.Upload_Atomic,
         Retry_Count       => 1,
         Timeout_Seconds   => 60,
         Google_Drive_API_Base => To_Unbounded_String
           ("http://127.0.0.1:" & Image (Port) & "/drive/v3"),
         Google_Drive_Upload_Base => To_Unbounded_String
           ("http://127.0.0.1:" & Image (Port) & "/upload/drive/v3"),
         Google_Drive_Access_Token => To_Unbounded_String ("drive-token"),
         Google_Drive_Supports_All_Drives => True,
         Google_Drive_Drive_Id => To_Unbounded_String ("fixture-drive"),
         others           => <>);
   begin
      Write_File (Local, "drive archive" & ASCII.LF);
      Status := Backup.Remote.Upload_Archive
        (Drive_URL, Local, Drive_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "Google Drive upload, readback verify, and index publish succeed: " &
             To_String (Diagnostic));
      Check (Report.Transport = Backup.Remote.Transport_Google_Drive,
             "Google Drive upload report records Drive transport");
      Check (Report.Verified, "Google Drive upload report is verified");

      Status := Backup.Remote.Read_Inventory
        (Drive_URL, Local, Drive_Options, Inventory, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "Google Drive inventory reads published index: " &
             To_String (Diagnostic));
      declare
         Saw_Local : Boolean := False;
      begin
         for Item of Inventory loop
            if To_String (Item.Archive_Id) = "local.zip" then
               Saw_Local := True;
               Check (Item.Size = Report.Size, "Google Drive index preserves size");
               Check (Item.Crc32 = Report.Crc32, "Google Drive index preserves CRC32");
            end if;
         end loop;
         Check (Saw_Local, "Google Drive inventory includes uploaded object");
      end;

      Status := Backup.Remote.Download_Archive
        (Drive_URL & "local.zip", Drive_Restored, Drive_Options, Report,
         Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "Google Drive download and verification succeed: " &
             To_String (Diagnostic));
      Check (Ada.Directories.Exists (Drive_Restored),
             "Google Drive download writes local file");

      Status := Backup.Remote.Delete_Remote_Object
        (Drive_URL, Local, "local.zip", Drive_Options, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "Google Drive delete and index removal succeed: " &
             To_String (Diagnostic));

      Write_File (Path ("drive-token.txt"), "drive-token" & ASCII.LF);
      Write_File (Path ("token-file-drive.zip"),
                  "drive token-file archive" & ASCII.LF);
      declare
         Token_File_Drive_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 0,
            Timeout_Seconds   => 60,
            Google_Drive_API_Base => Drive_Options.Google_Drive_API_Base,
            Google_Drive_Upload_Base => Drive_Options.Google_Drive_Upload_Base,
            Google_Drive_Access_Token_File => To_Unbounded_String
              (Path ("drive-token.txt")),
            Google_Drive_Supports_All_Drives => True,
            Google_Drive_Drive_Id => To_Unbounded_String ("fixture-drive"),
            others           => <>);
      begin
         Status := Backup.Remote.Upload_Archive
           (Drive_URL & "local.zip", Path ("token-file-drive.zip"),
            Token_File_Drive_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "Google Drive token-file auth uploads and verifies: " &
                To_String (Diagnostic));
         Check (Report.Verified,
                "Google Drive token-file upload report is verified");

         Status := Backup.Remote.Delete_Remote_Object
           (Drive_URL, Path ("token-file-drive.zip"), "local.zip",
            Token_File_Drive_Options, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "Google Drive token-file auth deletes test object: " &
                To_String (Diagnostic));
      end;

      Write_File (Path ("refresh-drive.zip"), "drive refresh archive" & ASCII.LF);
      declare
         Refresh_Drive_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 0,
            Timeout_Seconds   => 60,
            Google_Drive_API_Base => Drive_Options.Google_Drive_API_Base,
            Google_Drive_Upload_Base => Drive_Options.Google_Drive_Upload_Base,
            Google_Drive_Refresh_Token => To_Unbounded_String ("fixture-refresh"),
            Google_Drive_Client_Id => To_Unbounded_String ("fixture-client"),
            Google_Drive_Client_Secret => To_Unbounded_String ("fixture-secret"),
            Google_Drive_Token_URI => To_Unbounded_String
              ("http://127.0.0.1:" & Image (Port) & "/oauth/token"),
            Google_Drive_Supports_All_Drives => True,
            Google_Drive_Drive_Id => To_Unbounded_String ("fixture-drive"),
            others           => <>);
      begin
         Status := Backup.Remote.Upload_Archive
           (Drive_URL & "local.zip", Path ("refresh-drive.zip"),
            Refresh_Drive_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "Google Drive refresh-token auth uploads and verifies: " &
                To_String (Diagnostic));
         Check (Report.Verified,
                "Google Drive refresh-token upload report is verified");

         Status := Backup.Remote.Delete_Remote_Object
           (Drive_URL, Path ("refresh-drive.zip"), "local.zip",
            Refresh_Drive_Options, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "Google Drive refresh-token auth deletes test object: " &
                To_String (Diagnostic));
      end;

      Write_File (Path ("retry-drive.zip"), "drive retry archive" & ASCII.LF);
      declare
         Retry_Drive_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 1,
            Timeout_Seconds   => 60,
            Google_Drive_API_Base => Drive_Options.Google_Drive_API_Base,
            Google_Drive_Upload_Base => Drive_Options.Google_Drive_Upload_Base,
            Google_Drive_Access_Token => Drive_Options.Google_Drive_Access_Token,
            Google_Drive_Supports_All_Drives => True,
            Google_Drive_Drive_Id => To_Unbounded_String ("fixture-drive"),
            others           => <>);
      begin
         Status := Backup.Remote.Upload_Archive
           (Drive_URL, Path ("retry-drive.zip"), Retry_Drive_Options,
            Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "Google Drive retries rate-limited lookup and upload: " &
                To_String (Diagnostic));

         Status := Backup.Remote.Delete_Remote_Object
           (Drive_URL, Path ("retry-drive.zip"), "retry-drive.zip",
            Retry_Drive_Options, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "Google Drive retries transient delete failure: " &
                To_String (Diagnostic));
      end;
   end;

   declare
      PCloud_URL : constant String := "pcloud://0/backups/";
      PCloud_Restored : constant String := Path ("pcloud-restored.zip");
      PCloud_Options : constant Backup.Remote.Remote_Options :=
        (Require_Encrypted => False,
         Upload_Behavior   => Backup.Remote.Upload_Atomic,
         Retry_Count       => 1,
         Timeout_Seconds   => 60,
         PCloud_API_Base => To_Unbounded_String
           ("http://127.0.0.1:" & Image (Port) & "/pcloud"),
         PCloud_Access_Token => To_Unbounded_String ("pcloud-token"),
         PCloud_Large_Upload_Threshold => 1024,
         PCloud_Poll_Progress => True,
         others           => <>);
   begin
      declare
         Token_JSON : Unbounded_String;
      begin
         Status := Backup.Remote.Exchange_PCloud_Authorization_Code
           ("pcloud-client", "", "pcloud-code", "https://example.test/callback",
            "http://127.0.0.1:" & Image (Port) & "/pcloud",
            Token_JSON, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud OAuth code exchange returns token JSON: " &
                To_String (Diagnostic));
         Check
           (Ada.Strings.Fixed.Index
              (To_String (Token_JSON), "pcloud-code-token") > 0,
            "pCloud OAuth code exchange includes access token");
      end;

      Write_File (Local, "pCloud archive" & ASCII.LF);
      Status := Backup.Remote.Upload_Archive
        (PCloud_URL, Local, PCloud_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud upload, readback verify, and index publish succeed: " &
             To_String (Diagnostic));
      Check (Report.Transport = Backup.Remote.Transport_PCloud,
             "pCloud upload report records pCloud transport");
      Check (Report.Verified, "pCloud upload report is verified through checksumfile SHA-256");
      Check (Report.Retried > 0,
             "pCloud retries provider result-code throttling");
      Check (Saw_PCloud_Rename,
             "pCloud upload publishes final objects through renamefile");
      Check (Saw_PCloud_Nonce_Temp_Name,
             "pCloud temporary upload names include collision-resistant nonce");
      Check (Saw_PCloud_Progress_Hash,
             "pCloud uploadfile requests include progresshash tracking");
      Check (Saw_PCloud_Progress_Poll,
             "pCloud uploadprogress is polled when enabled");

      Status := Backup.Remote.Check_PCloud_Remote
        (PCloud_URL, PCloud_Options, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud preflight checks auth, region, quota, and namespace: " &
             To_String (Diagnostic));
      Check (Ada.Strings.Fixed.Index (To_String (Diagnostic), "quota=") > 0,
             "pCloud preflight reports quota metadata");

      Status := Backup.Remote.Read_Inventory
        (PCloud_URL, Local, PCloud_Options, Inventory, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud inventory reads published index: " &
             To_String (Diagnostic));
      declare
         Saw_Local : Boolean := False;
      begin
         for Item of Inventory loop
            if To_String (Item.Archive_Id) = "local.zip" then
               Saw_Local := True;
               Check (Item.Size = Report.Size, "pCloud index preserves size");
               Check (Item.Crc32 = Report.Crc32, "pCloud index preserves CRC32");
            end if;
         end loop;
         Check (Saw_Local, "pCloud inventory includes uploaded object");
      end;

      Status := Backup.Remote.Download_Archive
        (PCloud_URL & "local.zip", PCloud_Restored, PCloud_Options, Report,
         Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud download and verification succeed: " &
             To_String (Diagnostic));
      Check (Ada.Directories.Exists (PCloud_Restored),
             "pCloud download writes local file");

      Status := Backup.Remote.Delete_Remote_Object
        (PCloud_URL, Local, "local.zip", PCloud_Options, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud delete and index removal succeed: " &
             To_String (Diagnostic));

      Write_File (Path ("pcloud-token.txt"), "pcloud-token" & ASCII.LF);
      Write_File (Path ("token-file-pcloud.zip"),
                  "pCloud token-file archive" & ASCII.LF);
      declare
         Token_File_PCloud_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 0,
            Timeout_Seconds   => 60,
            PCloud_API_Base => PCloud_Options.PCloud_API_Base,
            PCloud_Access_Token_File => To_Unbounded_String
              (Path ("pcloud-token.txt")),
            others           => <>);
      begin
         Status := Backup.Remote.Upload_Archive
           (PCloud_URL & "local.zip", Path ("token-file-pcloud.zip"),
            Token_File_PCloud_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud token-file auth uploads and verifies: " &
                To_String (Diagnostic));
         Check (Report.Verified,
                "pCloud token-file upload report is verified");

         Status := Backup.Remote.Delete_Remote_Object
           (PCloud_URL, Path ("token-file-pcloud.zip"), "local.zip",
            Token_File_PCloud_Options, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud token-file auth deletes test object: " &
                To_String (Diagnostic));
      end;

      Write_File (Path ("refresh-pcloud.zip"),
                  "pCloud refresh-token archive" & ASCII.LF);
      declare
         Refresh_PCloud_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 0,
            Timeout_Seconds   => 60,
            PCloud_API_Base => PCloud_Options.PCloud_API_Base,
            PCloud_Refresh_Token => To_Unbounded_String ("pcloud-refresh"),
            PCloud_Client_Id => To_Unbounded_String ("pcloud-client"),
            PCloud_Token_URI => To_Unbounded_String
              ("http://127.0.0.1:" & Image (Port) & "/pcloud/oauth2_token"),
            PCloud_Token_Cache_File => To_Unbounded_String
              (Path ("pcloud-token-cache.txt")),
            others           => <>);
      begin
         Status := Backup.Remote.Upload_Archive
           (PCloud_URL & "local.zip", Path ("refresh-pcloud.zip"),
            Refresh_PCloud_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud refresh-token auth uploads and verifies: " &
                To_String (Diagnostic));
         Check (Report.Verified,
                "pCloud refresh-token upload report is verified");
         Check
           (Read_Text_File (Path ("pcloud-token-cache.txt")) =
            "refreshed-pcloud-token",
            "pCloud refresh-token auth writes token cache file");

         Status := Backup.Remote.Delete_Remote_Object
           (PCloud_URL, Path ("refresh-pcloud.zip"), "local.zip",
            Refresh_PCloud_Options, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud refresh-token auth deletes test object: " &
                To_String (Diagnostic));
      end;

      Write_File (Path ("rename-fail-pcloud.zip"),
                  "pCloud rename failure archive" & ASCII.LF);
      declare
         Cleanup_PCloud_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 0,
            Timeout_Seconds   => 60,
            PCloud_API_Base => PCloud_Options.PCloud_API_Base,
            PCloud_Access_Token => PCloud_Options.PCloud_Access_Token,
            PCloud_Large_Upload_Threshold => PCloud_Options.PCloud_Large_Upload_Threshold,
            others           => <>);
      begin
         Fail_Next_PCloud_Rename := True;
         Saw_PCloud_Temp_Cleanup := False;
         Status := Backup.Remote.Upload_Archive
           (PCloud_URL & "rename-fail-pcloud.zip",
            Path ("rename-fail-pcloud.zip"), Cleanup_PCloud_Options,
            Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Write_Failed,
                "pCloud cleans temporary upload when renamefile fails");
         Check (Saw_PCloud_Temp_Cleanup,
                "pCloud failed rename temporary object is deleted");
      end;

      Write_File (Path ("path-local.zip"),
                  "pCloud path namespace archive" & ASCII.LF);
      Status := Backup.Remote.Upload_Archive
        ("pcloud://created/path/path-local.zip", Path ("path-local.zip"),
         PCloud_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud path URL creates folder path and uploads: " &
             To_String (Diagnostic));
      Check (Saw_PCloud_Path_Create,
             "pCloud path URL uses createfolderifnotexists");

      Write_File (Path ("parents-pcloud.zip"),
                  "pCloud parent fallback archive" & ASCII.LF);
      Status := Backup.Remote.Upload_Archive
        ("pcloud://NeedsParents/Child/parents-pcloud.zip",
         Path ("parents-pcloud.zip"), PCloud_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud path URL creates missing parent folders: " &
             To_String (Diagnostic));
      Check (Saw_PCloud_Parent_Create,
             "pCloud path fallback creates parent folders component by component");

      Write_File (Path ("sha1-pcloud.zip"), "pCloud sha1 archive" & ASCII.LF);
      Status := Backup.Remote.Upload_Archive
        (PCloud_URL & "sha1-pcloud.zip", Path ("sha1-pcloud.zip"),
         PCloud_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud SHA-1-only checksum metadata verifies upload: " &
             To_String (Diagnostic));
      Check (Report.Verified, "pCloud SHA-1-only upload report is verified");

      Write_File (Path ("sha1-bad-pcloud.zip"), "pCloud sha1 archive" & ASCII.LF);
      Status := Backup.Remote.Upload_Archive
        (PCloud_URL & "sha1-bad-pcloud.zip", Path ("sha1-bad-pcloud.zip"),
         PCloud_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Metadata_Mismatch,
             "pCloud SHA-1 checksum mismatch is rejected");

      Write_Repeated_File (Path ("large-pcloud.zip"), 2 * 1024 * 1024 + 17);
      declare
         Resume_PCloud_Options : constant Backup.Remote.Remote_Options :=
           (PCloud_Options with delta
            Upload_Behavior => Backup.Remote.Upload_Resume_If_Supported);
         Large_Upload_Count : Natural;
      begin
         Status := Backup.Remote.Upload_Archive
           (PCloud_URL & "large-pcloud.zip", Path ("large-pcloud.zip"),
            Resume_PCloud_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud large upload uses streamed uploadfile path (" &
                Backup.Remote.Status_Text (Status) & "): " &
                To_String (Diagnostic));
         Check (Report.Verified, "pCloud large upload report is verified");
         Check (not Report.Resumed,
                "pCloud initial large upload starts fresh");

         Large_Upload_Count := PCloud_Archive_Upload_Count;
         Status := Backup.Remote.Upload_Archive
           (PCloud_URL & "large-pcloud.zip", Path ("large-pcloud.zip"),
            Resume_PCloud_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud remote-resume reuses matching large upload: " &
                To_String (Diagnostic));
         Check (Report.Verified,
                "pCloud resumed large upload report is verified");
         Check (Report.Resumed,
                "pCloud remote-resume reports reused provider object");
         Check (PCloud_Archive_Upload_Count = Large_Upload_Count,
                "pCloud remote-resume skips duplicate large uploadfile request");
      end;

      Status := Backup.Remote.Delete_Remote_Object
        (PCloud_URL, Path ("large-pcloud.zip"), "large-pcloud.zip",
         PCloud_Options, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "pCloud large upload cleanup deletes remote object: " &
             To_String (Diagnostic));

      Seed_PCloud_Temp (Port);
      declare
         Deleted : Natural := 0;
      begin
         Status := Backup.Remote.Cleanup_Remote_Temporary_Objects
           (PCloud_URL, PCloud_Options, Deleted, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud temporary cleanup deletes stale upload objects: " &
                To_String (Diagnostic));
         Check (Deleted = 1, "pCloud temporary cleanup reports deleted object");
      end;

      Seed_PCloud_Recursive_Temp (Port);
      declare
         Deleted : Natural := 0;
         Recursive_Options : constant Backup.Remote.Remote_Options :=
           (PCloud_Options with delta PCloud_Clean_Recursive => True);
      begin
         Status := Backup.Remote.Cleanup_Remote_Temporary_Objects
           (PCloud_URL, Recursive_Options, Deleted, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "pCloud recursive temporary cleanup walks child folders: " &
                To_String (Diagnostic));
         Check (Deleted = 1,
                "pCloud recursive temporary cleanup reports nested object");
      end;
   end;

   declare
      S3_URL : constant String := "s3://s3-bucket/backups/";
      S3_Restored : constant String := Path ("s3-restored.zip");
      S3_Options : constant Backup.Remote.Remote_Options :=
        (Require_Encrypted => False,
         Upload_Behavior   => Backup.Remote.Upload_Resume_If_Supported,
         Retry_Count       => 0,
         Timeout_Seconds   => 60,
         S3_Endpoint      => To_Unbounded_String
           ("http://127.0.0.1:" & Image (Port)),
         S3_Region        => To_Unbounded_String ("test-region-1"),
         S3_Access_Key    => To_Unbounded_String ("test-access"),
         S3_Secret_Key    => To_Unbounded_String ("test-secret"),
         S3_Server_Side_Encryption => To_Unbounded_String ("aws:kms"),
         S3_SSE_KMS_Key_Id => To_Unbounded_String ("kms-key"),
         S3_Multipart_Threshold => 1,
         S3_Multipart_Part_Size => 5 * 1024 * 1024,
         others           => <>);
   begin
      Write_Repeated_File (Local, 5 * 1024 * 1024 + 9);
      Status := Backup.Remote.Upload_Archive
        (S3_URL, Local, S3_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "S3 upload, readback verify, and index publish succeed: " &
             To_String (Diagnostic));
      Check (Report.Transport = Backup.Remote.Transport_S3,
             "S3 upload report records S3 transport");
      Check (Report.Verified, "S3 upload report is verified");

      Status := Backup.Remote.Read_Inventory
        (S3_URL, Local, S3_Options, Inventory, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "S3 inventory reads published index: " & To_String (Diagnostic));
      declare
         Saw_Local : Boolean := False;
      begin
         for Item of Inventory loop
            if To_String (Item.Archive_Id) = "local.zip" then
               Saw_Local := True;
               Check (Item.Size = Report.Size, "S3 index preserves size");
               Check (Item.Crc32 = Report.Crc32, "S3 index preserves CRC32");
            end if;
         end loop;
         Check (Saw_Local, "S3 inventory includes uploaded object");
      end;

      Drop_S3_Index (Port);
      Status := Backup.Remote.Read_Inventory
        (S3_URL, Local, S3_Options, Inventory, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "S3 fallback inventory reads ListObjectsV2 metadata: " &
             To_String (Diagnostic));
      declare
         Saw_Local : Boolean := False;
      begin
         for Item of Inventory loop
            if To_String (Item.Archive_Id) = "local.zip" then
               Saw_Local := True;
               Check (Item.Size = Report.Size, "S3 fallback preserves size");
               Check (Item.Crc32 = Report.Crc32,
                      "S3 fallback preserves CRC32 from object metadata");
            end if;
         end loop;
         Check (Saw_Local, "S3 fallback inventory includes uploaded object");
      end;

      Status := Backup.Remote.Download_Archive
        (S3_URL & "local.zip", S3_Restored, S3_Options, Report, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "S3 download and verification succeed: " &
             To_String (Diagnostic));
      Check (Ada.Directories.Exists (S3_Restored),
             "S3 download writes local file");

      Status := Backup.Remote.Delete_Remote_Object
        (S3_URL, Local, "local.zip", S3_Options, Diagnostic);
      Check (Status = Backup.Remote.Remote_Ok,
             "S3 delete and index removal succeed: " & To_String (Diagnostic));

      declare
         Single_PUT_Options : constant Backup.Remote.Remote_Options :=
           (Require_Encrypted => False,
            Upload_Behavior   => Backup.Remote.Upload_Atomic,
            Retry_Count       => 0,
            Timeout_Seconds   => 60,
            S3_Endpoint      => To_Unbounded_String
              ("http://127.0.0.1:" & Image (Port)),
            S3_Region        => To_Unbounded_String ("test-region-1"),
            S3_Access_Key    => To_Unbounded_String ("test-access"),
            S3_Secret_Key    => To_Unbounded_String ("test-secret"),
            S3_Server_Side_Encryption => To_Unbounded_String ("aws:kms"),
            S3_SSE_KMS_Key_Id => To_Unbounded_String ("kms-key"),
            S3_Multipart_Threshold => 0,
            S3_Multipart_Part_Size => 5 * 1024 * 1024,
            others           => <>);
      begin
         Write_File (Local, "single put checksum" & ASCII.LF);
         Status := Backup.Remote.Upload_Archive
           (S3_URL, Local, Single_PUT_Options, Report, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "S3 single PUT sends native CRC32 checksum: " &
                To_String (Diagnostic));
         Status := Backup.Remote.Delete_Remote_Object
           (S3_URL, Local, "local.zip", Single_PUT_Options, Diagnostic);
         Check (Status = Backup.Remote.Remote_Ok,
                "S3 single PUT cleanup succeeds: " & To_String (Diagnostic));
      end;
   end;

   Shutdown (Port);
   Project_Tools.Files.Delete_Tree (Root);

   if Failures /= 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      raise Program_Error;
   end if;
exception
   when others =>
      Shutdown (Port);
      if Ada.Directories.Exists (Root) then
         Project_Tools.Files.Delete_Tree (Root);
      end if;
      raise;
end Backup_HTTP_Remote_Live_Tests;
