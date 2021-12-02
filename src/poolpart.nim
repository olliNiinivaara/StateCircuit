import std/locks

type
  PoolItem* = int

  PoolPart*[T; Capacity: static int] = ref object
    mem: array[Capacity, T] 
    stack: array[Capacity, PoolItem]
    head: int
    lock: Lock


const PoolFull* = -100.PoolItem


func newPoolPart*[T; Capacity: static int](): PoolPart[T, Capacity] =
  result = PoolPart[T, Capacity]()
  for i in countup(0, Capacity - 1): result.stack[i] = i


proc reserve*[T, Capacity](p: PoolPart[T, Capacity]): PoolItem =
    withLock(p.lock):
      if p.head == Capacity: return PoolFull
      result = p.stack[p.head]
      p.head += 1
      

proc release*[T, Capacity](p: PoolPart[T, Capacity], item: PoolItem) =
    withLock(p.lock):
      p.head -= 1
      p.stack[p.head] = item


proc `[]`*[T, Capacity](p: PoolPart[T, Capacity], item: PoolItem): var T =
  p.mem[item]


proc `[]=`*[T, Capacity](p: PoolPart[T, Capacity], item: PoolItem, value: T) =
  p.mem[item] = value


func getFreeCapacity*[T, Capacity](p: PoolPart[T, Capacity]): int =
  Capacity - p.head


func getUtilizationRate*[T, Capacity](p: PoolPart[T, Capacity]): int =
  debugEcho(p.head)
  (100 * p.head) div Capacity


template withItem*[T, Capacity](p: PoolPart[T, Capacity], body1, body2: untyped) =
  let i = p.reserve()
  if i == PoolFull: body2
  else:
    try:
      {.push used.}
      var item {.inject.} = p.mem[i]
      {.pop.}
      body1
    finally:
      p.release(i)


iterator all*[T, Capacity](p: PoolPart[T, Capacity]): var T {.nosideeffect.} =
  {.nosideeffect.}:
    withLock(p.lock):
      for i in countup(0, Capacity - 1 ): yield p.mem[i]

# ------------------------------------------------------
#[
import std/random
from os import sleep

type
  TestiOlio = object
    teksti: string
    arvo: int

const Cap = 20

let pool = newPoolPart[TestiOlio, Cap]()

proc luuppaa(i: int) =
  {.gcsafe.}:
    let luup = 5
    for l in countup(1, luup):
      let item = pool.reserve()
      sleep(rand(60))
      if item == PoolFull:
        echo "pool täysi"
        break
      pool[item].teksti = $i & " = " & $l
      pool[item].arvo = l
      echo "poolissa ", item , " = ", pool[item]
      if i != 0: pool.release(item)
      pool.withItem():
        item.teksti = "jjee jee " & $l
      do:
        echo "pool täysi"
        break

proc main() =
  var threads: array[2, Thread[int]]
  for i in 0 ..< 2: createThread(threads[i], luuppaa, i)
  joinThreads threads
  echo pool.getFreeCapacity()
  for olio in pool.all: echo olio


main()]#