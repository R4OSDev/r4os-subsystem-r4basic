TYPE XYPosition
    X AS INTEGER
    Y AS INTEGER
END TYPE

DECLARE SUB Render (BYREF Position AS XYPosition, Values() AS LONG)
DECLARE SUB AcceptAny (Values() AS ANY)
DECLARE FUNCTION Score# (BYVAL Text$)

CONST TRUE = -1, FALSE = 0
DIM SHARED Points(0 TO 3) AS XYPosition, Flags(1 TO 2) AS INTEGER
DIM Grid(0 TO 2, 0 TO 2) AS INTEGER
REDIM Values(1 TO 8) AS LONG

Numbers:
DATA 1, -2, 3.5, "four"
READ Values(1), Values(2)
RESTORE Numbers

DEF FnPick (Limit) = INT(RND(1) * Limit) + 1

SUB Render (Position AS XYPosition, Values() AS LONG) STATIC
    Position.X = Values(1)
    EXIT SUB
END SUB

FUNCTION Score# (BYVAL Text$)
    Score# = VAL(Text$)
END FUNCTION

CALL Render(Points(0), Values())
Render Points(0), Values()
END
