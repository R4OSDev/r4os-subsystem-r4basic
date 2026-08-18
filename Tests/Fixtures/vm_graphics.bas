DEFINT A-Z
DIM Sprite&(0 TO 64)

SCREEN 9
PALETTE 1, 46
LINE (2, 2)-(7, 8), 9, BF
GET (2, 2)-(7, 8), Sprite&
Captured = POINT(2, 2)

CLS 1
PUT (20, 20), Sprite&, PSET
Placed = POINT(20, 20)
PUT (20, 20), Sprite&, XOR
Xored = POINT(20, 20)
PUT (20, 20), Sprite&, XOR
Restored = POINT(20, 20)

CIRCLE (100, 100), 10, 2
PAINT (100, 100), 3, 2
Painted = POINT(100, 100)

PSET (5, 5), 2
PSET STEP (2, 3), 3
StepColor = POINT(7, 8)
Outside = POINT(-1, -1)
END
