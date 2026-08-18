DEFINT A-Z
DECLARE SUB AddTo (BYREF Target AS INTEGER, BYVAL Amount AS INTEGER)
DECLARE SUB Forward (BYREF Target AS INTEGER)
DECLARE SUB Touch ()
DECLARE FUNCTION Twice% (BYVAL Number AS INTEGER)
DECLARE FUNCTION Factorial& (BYVAL Number AS INTEGER)

DIM SHARED TouchCount AS INTEGER
GlobalValue = 5
Offset = 1
CALL AddTo(GlobalValue, 3)
AddTo GlobalValue, 2
Forward GlobalValue
CALL Touch()
Touch
FunctionResult = Twice%(GlobalValue)
FactorialResult& = Factorial&(5)
DEF FnPlusOne%(Number%) = Number% + Offset
DefResult = FnPlusOne%(FunctionResult)
END

SUB AddTo (Target AS INTEGER, BYVAL Amount AS INTEGER)
    Target = Target + Amount
END SUB

SUB Forward (Target AS INTEGER)
    AddTo Target, 1
END SUB

SUB Touch ()
    TouchCount = TouchCount + 1
    EXIT SUB
    TouchCount = TouchCount + 100
END SUB

FUNCTION Twice% (BYVAL Number AS INTEGER)
    Twice% = Number * 2
    EXIT FUNCTION
    Twice% = 0
END FUNCTION

FUNCTION Factorial& (BYVAL Number AS INTEGER)
    IF Number <= 1 THEN
        Factorial& = 1
        EXIT FUNCTION
    END IF
    Factorial& = Number * Factorial&(Number - 1)
END FUNCTION
