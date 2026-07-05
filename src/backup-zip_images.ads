with Ada.Containers.Vectors;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Interfaces;

package Backup.Zip_Images is
   use type Interfaces.Unsigned_64;
   package Disk_Start_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Interfaces.Unsigned_64);

   function Read_Logical_Zip
     (Archive_Path : String;
      Disk_Starts  : out Disk_Start_Vectors.Vector;
      Diagnostic   : out Ada.Strings.Unbounded.Unbounded_String;
      Ok           : out Boolean)
      return Ada.Streams.Stream_Element_Array;
end Backup.Zip_Images;
