DEFINT A-Z
DECLARE FUNCTION CalcDelay! ()
DECLARE SUB Rest (t#)
CONST SPEEDCONST = 500
DIM SHARED MachSpeed AS SINGLE
MachSpeed = CalcDelay!()
Before# = TIMER
CALL Rest(.1)
After# = TIMER
END

FUNCTION CalcDelay!
  s! = TIMER
  DO
    i! = i! + 1
  LOOP UNTIL TIMER - s! >= .5
  CalcDelay! = i!
END FUNCTION

SUB Rest (t#)
  s# = TIMER
  t2# = MachSpeed * t# / SPEEDCONST
  DO
  LOOP UNTIL TIMER - s# > t2#
END SUB
