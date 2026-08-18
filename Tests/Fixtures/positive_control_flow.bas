StartHere:
FOR Counter = 1 TO 3 STEP 1
    IF Counter = 1 THEN
        PRINT Counter
    ELSEIF Counter = 2 THEN
        SELECT CASE Counter
            CASE 1, 2 TO 3
                PRINT "middle"
            CASE ELSE
                PRINT "other"
        END SELECT
    ELSE
        EXIT FOR
    END IF
NEXT Counter

WHILE Counter > 0
    Counter = Counter - 1
WEND

DO WHILE Counter < 2
    Counter = Counter + 1
    IF Counter > 10 THEN EXIT DO
LOOP

DO
    Counter = Counter - 1
LOOP UNTIL Counter = 0

IF Counter = 0 THEN GOTO Done ELSE GOSUB Helper
ON ERROR GOTO Handler
ON ERROR GOTO 0

Handler:
RESUME
RESUME NEXT

Helper:
RETURN

Done:
END
