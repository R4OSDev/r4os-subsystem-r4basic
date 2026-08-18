DEFINT A-Z
DIM EgaImage&(0 TO 7)
DIM CgaImage&(0 TO 2)

FOR I = 0 TO 7
  READ EgaImage&(I)
NEXT I
FOR I = 0 TO 2
  READ CgaImage&(I)
NEXT I

SCREEN 9
PUT (10, 10), EgaImage&, PSET
FOR Y = 10 TO 16
  FOR X = 10 TO 15
    EgaSolid = EgaSolid + POINT(X, Y)
  NEXT X
NEXT Y
PUT (10, 10), EgaImage&, XOR
FOR Y = 10 TO 16
  FOR X = 10 TO 15
    EgaErased = EgaErased + POINT(X, Y)
  NEXT X
NEXT Y
PUT (10, 10), EgaImage&, XOR
FOR Y = 10 TO 16
  FOR X = 10 TO 15
    EgaRestored = EgaRestored + POINT(X, Y)
  NEXT X
NEXT Y

SCREEN 1
PUT (10, 10), CgaImage&, PSET
FOR Y = 10 TO 14
  FOR X = 10 TO 12
    CgaSolid = CgaSolid + POINT(X, Y)
  NEXT X
NEXT Y
PUT (10, 10), CgaImage&, XOR
FOR Y = 10 TO 14
  FOR X = 10 TO 12
    CgaErased = CgaErased + POINT(X, Y)
  NEXT X
NEXT Y
PUT (10, 10), CgaImage&, XOR
FOR Y = 10 TO 14
  FOR X = 10 TO 12
    CgaRestored = CgaRestored + POINT(X, Y)
  NEXT X
NEXT Y
END

DATA 458758, -67108612, -67108612, -67108612, -67108612, -67108612, -67108612, -67108612
DATA 327686, -50529028, 252
