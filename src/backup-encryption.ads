with Ada.Strings.Unbounded;

package Backup.Encryption is
   type Cipher_Kind is
     (Cipher_AES256_GCM);

   type Password_Source_Kind is
     (Password_None,
      Password_File,
      Password_Env,
      Password_Prompt);

   type Password_Source is record
      Kind  : Password_Source_Kind := Password_None;
      Value : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   type Envelope_Status is
     (Envelope_Ok,
      Envelope_Not_Encrypted,
      Envelope_Open_Failed,
      Envelope_Read_Failed,
      Envelope_Write_Failed,
      Envelope_Missing_Password,
      Envelope_Unsupported_Cipher,
      Envelope_Malformed,
      Envelope_Authentication_Failed);

   function Cipher_Name (Cipher : Cipher_Kind) return String;

   function Parse_Cipher
     (Value      : String;
      Cipher     : out Cipher_Kind;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Boolean;

   function Status_Text (Status : Envelope_Status) return String;

   function Resolve_Password
     (Source     : Password_Source;
      Password   : out Ada.Strings.Unbounded.Unbounded_String;
      Diagnostic : out Ada.Strings.Unbounded.Unbounded_String)
      return Envelope_Status;

   function Is_Encrypted (Path : String) return Boolean;

   function Encrypt_File
     (Plaintext_Path : String;
      Encrypted_Path : String;
      Source         : Password_Source;
      Cipher         : Cipher_Kind;
      Diagnostic     : out Ada.Strings.Unbounded.Unbounded_String)
      return Envelope_Status;

   function Decrypt_File
     (Encrypted_Path : String;
      Plaintext_Path : String;
      Source         : Password_Source;
      Diagnostic     : out Ada.Strings.Unbounded.Unbounded_String)
      return Envelope_Status;
end Backup.Encryption;
