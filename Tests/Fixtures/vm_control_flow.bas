DEFINT A-Z
Total = 0

FOR Index = 1 TO 5
    IF Index = 3 THEN
        Total = Total + 10
    ELSEIF Index = 4 THEN
        Total = Total + 20
    ELSE
        Total = Total + Index
    END IF
NEXT Index

Count = 0
WHILE Count < 3
    Count = Count + 1
    Total = Total + 1
WEND

DO
    Count = Count - 1
LOOP WHILE Count > 0

DO
    Count = Count + 1
    IF Count = 2 THEN EXIT DO
LOOP

SELECT CASE Total
    CASE 40
        Total = Total + 100
    CASE 41
        Total = Total + 200
    CASE ELSE
        Total = Total + 300
END SELECT

FOR Reverse = 3 TO 1 STEP -1
    Total = Total + Reverse
NEXT Reverse

FOR Escape = 1 TO 10
    IF Escape = 3 THEN EXIT FOR
    Total = Total + Escape
NEXT Escape

DO UNTIL Count = 4
    Count = Count + 1
LOOP

DO
    Count = Count - 1
LOOP UNTIL Count = 1

SELECT CASE Count
    CASE 0
        Total = Total + 100
    CASE 1 TO 2
        Total = Total + 5
    CASE ELSE
        Total = Total + 200
END SELECT

IF Count = 1 THEN Total = Total + 1 ELSE Total = Total + 100

GOSUB Bonus
GOTO Finished

Bonus:
Total = Total + 9
RETURN AfterBonus

AfterBonus:
Finished:
END
