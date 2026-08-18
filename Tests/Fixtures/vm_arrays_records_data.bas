DEFINT A-Z
'$DYNAMIC

TYPE XYPoint
  XCoor AS INTEGER
  YCoor AS INTEGER
END TYPE

DECLARE SUB FillPoints(Points() AS ANY)
DECLARE SUB AddLong(Value AS LONG)
DECLARE SUB ShiftPoint(Entry AS XYPoint)
DECLARE SUB TouchShared()

DIM SHARED Grid&(-1 TO 1, 2 TO 3)
DIM SHARED Points(1 TO 2) AS XYPoint
DIM SHARED Image&(Placeholder)
DIM SHARED SharedCount

RESTORE ImageData
REDIM Image&(2)
FOR Index = 0 TO 2
  READ Image&(Index)
NEXT Index

Grid&(-1, 2) = Image&(0)
Grid&(1, 3) = Image&(1)
CALL FillPoints(Points())
CALL AddLong(Image&(2))
CALL ShiftPoint(Points(2))
CALL TouchShared
END

ImageData:
DATA 458758, -2134835200, 1886416896

SUB FillPoints(Points() AS XYPoint)
  Points(1).XCoor = 12
  Points(1).YCoor = 34
  Points(2).XCoor = Points(1).XCoor + 1
  Points(2).YCoor = Points(1).YCoor + 1
END SUB

SUB AddLong(Value AS LONG)
  Value = Value + 4
END SUB

SUB ShiftPoint(Entry AS XYPoint)
  Entry.XCoor = Entry.XCoor + 10
  Entry.YCoor = Entry.YCoor + 20
END SUB

SUB TouchShared
  SharedCount = SharedCount + 1
  Grid&(0, 3) = Grid&(-1, 2) + SharedCount
END SUB
