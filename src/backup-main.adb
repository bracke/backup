with Ada.Command_Line;

with Backup.CLI;

procedure Backup.Main is
   Status : Backup.CLI.Exit_Status;
begin
   Status := Backup.CLI.Run;

   pragma Assert
     (Status in Backup.CLI.Success | Backup.CLI.Failure,
      "CLI returned an invalid exit status");

   case Status is
      when Backup.CLI.Success =>
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      when Backup.CLI.Failure =>
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end case;
end Backup.Main;
