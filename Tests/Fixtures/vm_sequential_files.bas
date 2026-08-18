DEFINT A-Z
OPEN "input.txt" FOR INPUT AS #1
INPUT #1, Name$, Score
LINE INPUT #1, Message$
AtEnd = EOF(1)
CLOSE #1
OPEN "output.txt" FOR OUTPUT AS #2
PRINT #2, Name$; Score
PRINT #2, Message$;
CLOSE #2
OPEN "append.txt" FOR APPEND AS #3
PRINT #3, "tail"
CLOSE #3
OPEN "C:\GAMES\input.txt" FOR INPUT AS #4
LINE INPUT #4, AbsoluteName$
CLOSE #4
OPEN "C:\GAMES\absolute.txt" FOR OUTPUT AS #5
PRINT #5, AbsoluteName$;
CLOSE #5
END
