with Ada.Command_Line;

with AUnit;
with AUnit.Reporter.Text;
with AUnit.Run;

with All_Suites;

--  Test_Runner exits zero whatever happens, so the suite could not fail: a failing test
--  reported success and "alr test" was green over it. Report the status, so a failure is
--  a failure.
procedure Tests is
   use type AUnit.Status;

   function Runner is new AUnit.Run.Test_Runner_With_Status (All_Suites.Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
begin
   if Runner (Reporter) /= AUnit.Success then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests;
