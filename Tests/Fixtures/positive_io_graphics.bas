DIM Pixels(1 TO 64) AS LONG
DIM Name$, Text$, Key$, Score, Index, Pixel, AtEnd
DIM Number#, Clock#

Number# = ABS(-1) + ATN(1) + CINT(1.2) + COS(0) + INT(1.9) + SIN(0)
Text$ = CHR$(65) + LEFT$("R4OS", 2) + LTRIM$(" text")
Text$ = Text$ + MID$("R4OS", 2, 2) + SPACE$(1) + STR$(VAL("2"))
Text$ = UCASE$(Text$)
Index = INSTR(1, Text$, "R4")
Index = Index + INSTR(Text$, "R4")
Text$ = Text$ + MID$("R4OS", 2)
AtEnd = EOF(1)
Pixel = POINT(1, 2)
Number# = Number# + RND(1) + PEEK(1047)
Number# = Number# + RND
Key$ = INKEY$
Clock# = TIMER

SCREEN 0
WIDTH 80, 25
COLOR , 1
CLS 2
LOCATE , 2, 0
VIEW PRINT 1 TO 20
PRINT TAB(4); Text$; Number#
INPUT "Name"; Name$
LINE INPUT "Text"; Text$
RANDOMIZE TIMER
SLEEP 1
BEEP
PLAY "T120O4L4C"

SCREEN 1
SCREEN 9
PALETTE 1, 2
PSET (1, 2), 3
PRESET STEP (1, 1)
LINE (1, 2)-(8, 9), 3, B
LINE (2, 3)-(9, 10), 4, BF
LINE -STEP (2, 1), 2, , &HAAAA
CIRCLE (10, 10), 5, 2, , , 1.0
PAINT (10, 10), 2, 3
DRAW "C3BR2R2"
GET (0, 0)-(7, 7), Pixels
PUT (1, 1), Pixels, PSET
PUT (1, 1), Pixels, PRESET
PUT (1, 1), Pixels, AND
PUT (1, 1), Pixels, OR
PUT (2, 2), Pixels, XOR
BLOAD "image.bsv", 0
BSAVE "image.bsv", 0, 16

OPEN "input.txt" FOR INPUT AS #1
OPEN "output.txt" FOR OUTPUT AS #2
OPEN "append.txt" FOR APPEND AS #3
INPUT #1, Name$, Score
LINE INPUT #1, Text$
PRINT #2, Text$;
CLOSE #1, #2, #3

DEF SEG = 0
POKE 1047, PEEK(1047)
DEF SEG
END
