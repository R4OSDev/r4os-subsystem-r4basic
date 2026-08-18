DEFINT A-Z
DECLARE SUB Advance ()
DIM SHARED Counter AS INTEGER
CALL Advance
END

SUB Advance ()
    DO
        Counter = Counter + 1
        IF Counter = 4 THEN Broken = 1 / 0
    LOOP
END SUB
