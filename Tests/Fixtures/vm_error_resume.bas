DEFINT A-Z

ON ERROR GOTO RetryHandler
Mode = 9
SCREEN Mode
AfterRetry = 1

ON ERROR GOTO NextHandler
Mode = 9
SCREEN Mode
AfterNext = 1
ON ERROR GOTO 0
END

RetryHandler:
RetryCount = RetryCount + 1
Mode = 1
RESUME

NextHandler:
NextCount = NextCount + 1
Mode = 1
RESUME NEXT
