DEFINT A-Z
DECLARE SUB Spin ()
DIM SHARED Counter AS INTEGER
CALL Spin
END

SUB Spin ()
    DO
        Counter = Counter + 1
    LOOP
END SUB
