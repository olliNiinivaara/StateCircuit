import locks
export withLock
 
var
  dblock*: Lock
  values: seq[string]

proc insertValue*(value: string) =
   {.gcsafe.}: values.add(value)

proc getValues*(): seq[string] =
  {.gcsafe.}: return values

dblock.initLock()