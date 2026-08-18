DEFINT A-Z
AbsoluteValue = ABS(-5)
RoundedValue = CINT(2.5)
FloorValue = INT(-2.1)
TextValue$ = CHR$(65) + LEFT$("R4OS", 2)
TextValue$ = TextValue$ + LTRIM$("  BASIC")
TextValue$ = TextValue$ + MID$("-CORE-", 2, 4)
TextValue$ = UCASE$(TextValue$) + SPACE$(1) + STR$(7)
TextLength = LEN(TextValue$)
FoundAt = INSTR(1, TextValue$, "BASIC")
Angle# = ATN(1#) + COS(0#) + SIN(0#)
Parsed# = VAL(" 12.5tail")
END
