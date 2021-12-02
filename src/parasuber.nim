# (C) Olli Niinivaara, 2021
# MIT Licensed

## A Pub/Sub engine.
## 
## Receives messages from multiple sources and delivers them as a serialized stream.
## Publisher threads do not block each other or delivery thread, and delivery does not block publishing.
## Messages can belong to multiple topics.
## Subscribers can subscribe to multiple topics.
## Topics, subscribers and subscriptions can be modified anytime.
## Delivery may be triggered on message push, size of undelivered messages, amount of undelivered messages and on call.
## Keeps a message cache so that subscribers can sync their state at will.
##
## 
## Example
## ==================
##
## .. code-block:: Nim
##  
##  # nim c -r --gc:arc --threads:on --d:release example.nim

when not defined(gcDestructors): {.fatal: "Parasuber requires gc:arc or orc compiler option".}

import std/[intsets, monotimes, tables, deques, locks]
import pkg/[stashtable]
import poolpart
export intsets, monotimes

type
  Topic* = distinct int
  Subscriber* = distinct int
  PendingDelivery*[MessageType] = object
    msg*: MessageType
    exclusivereceiver*: Subscriber
    topics*: IntSet
    subscribers*: IntSet
    timestamp*: MonoTime
    pendingdeliverypoolindex*: int

# template NestedType(U: type): type = PendingDelivery[U]

type  
  TopicDatum = tuple[subscribers: ref IntSet, currenttimestamp: MonoTime]
    
  ParaSuber*[T; MaxTopics: static int] = ref object
    topicdata: StashTable[Topic, TopicDatum, MaxTopics]
    pendingdeliveries: seq[Deque[PoolItem]]
    queuesubscribers: seq[IntSet]
    workers: int
    afterworker: bool
    lock: Lock
    pendingdelivery: PoolPart[PendingDelivery[T], 1000]
    ## The Suber service. Create one with `newSuber`.
    ## 
    ## | TData is the generic parameter that defines the type of message data
    ## | SuberMaxTopics is maximum amount of distinct topics
    ## 
    ## Note: If you have distinct topics (subscriber partitions) and application logic allows,
    ## it may be profitable to have dedicated Suber for each partition.
    ## 

const NoSubscriber* = Subscriber(int.low + 3)
  
{.push checks:off.}

proc `==`*(x, y: Topic): bool {.borrow.}
proc `==`*(x, y: Subscriber): bool {.borrow.}
proc `$`*(x: Topic): string {.borrow.}
proc `$`*(x: Subscriber): string {.borrow.}

converter toTopic*(x: int): Topic = Topic(x)

type FakeMonoTime = object
  ticks: int64

func toMonoTime*(i: int64): MonoTime {.inline.} =
  let monotime = FakeMonoTime(ticks: i)
  result = cast[MonoTime](monotime)

func toIntSet*(x: openArray[Topic]): IntSet {.inline.} =
  result = initIntSet()
  for item in items(x): result.incl(int(item))

func toIntSet*(x: openArray[Subscriber]): IntSet {.inline.} =
  result = initIntSet()
  for item in items(x): result.incl(int(item))

  
func newParaSuber*[T; MaxTopics: static int](): ParaSuber[T, MaxTopics] =
  result = ParaSuber[T, MaxTopics]()
  result.topicdata = newStashTable[Topic, TopicDatum, MaxTopics]()
  result.pendingdeliveries = newSeq[Deque[PoolItem]]()
  result.queuesubscribers = newSeq[IntSet]()
  result.pendingdeliveries.add(initDeque[PoolItem](20))
  result.queuesubscribers.add(initIntSet())
  result.pendingdelivery = newPoolPart[PendingDelivery[T], 1000]()
  for pendel in result.pendingdelivery.all(): pendel.subscribers = initIntSet()
  initLock(result.lock)

# TODO:  fixaa stashtable -> func

proc addTopic*(suber: ParaSuber, topic: Topic | int): bool {.discardable.} =
  ## Adds new topic.
  ## 
  ## Returns false if maximum number of topics is already added.
  var newsetref = new IntSet
  let (index , res) = suber.topicdata.insert(topic, (newsetref , toMonoTime(0)))
  if res:
    suber.topicdata.withFound(topic, index): value.subscribers[] = initIntSet()
  return res
  
proc removeTopic*(suber: ParaSuber, topic: Topic | int) =
  suber.topicdata.del(topic)

func compactTopics() =
  # TODO: remove topics without subscribers
  discard

func hasTopic*(suber: ParaSuber, topic: Topic | int): bool =
  not (findIndex(suber.topicdata, topic) == NotInStash)

func getTopiccount*(suber: ParaSuber): int = suber.topicdata.len

func getSubscribersbytopic*(suber: ParaSuber): seq[tuple[id: Topic; subscribers: IntSet]] =
  ## Reports subscribers for each topic.
  for (topicid , index) in suber.topicdata.keys():
    suber.topicdata.withFound(topicid, index):
      result.add((topicid, value.subscribers[]))

proc subscribe*(suber: ParaSuber, subscriber: Subscriber, topic: Topic | int; createnewtopic = false): bool {.discardable.} =
  ## Creates new subscription. If `createnewtopic` is false, the topic must already exist,
  ## otherwise it is added as needed.
  withValue(suber.topicdata, topic):
    value.subscribers[].incl(int(subscriber))
    return true
  do:
    if not createnewtopic: return false
    var newsetref = new IntSet
    let (index , res) = suber.topicdata.insert(topic, (newsetref , toMonoTime(0)))
    if res:
      suber.topicdata.withFound(topic, index):
        value.subscribers[] = initIntSet()
        value.subscribers[].incl(int(subscriber))
    return res
    
proc unsubscribe*(suber: ParaSuber, subscriber: Subscriber, topic: Topic) =
  ## Removes a subscription.
  suber.topicdata.withValue(topic): value.subscribers[].excl(int(subscriber))

proc removeSubscriber*(suber: ParaSuber, subscriber: Subscriber) =
  ## Removes all subscriptions of the subscriber.
  for (topicid , index) in suber.topicdata.keys():
    suber.topicdata.withFound(topicid, index): value.subscribers[].excl(int(subscriber))
        
func getSubscriptions*(suber: ParaSuber, subscriber: Subscriber): seq[Topic] =
  for (topic , index) in suber.topicdata.keys():
    suber.topicdata.withFound(topic, index):
      if value.subscribers[].contains(int(subscriber)): result.add(topic)

func getSubscribers*(suber: ParaSuber, topic: Topic | int): IntSet =
  suber.topicdata.withValue(topic): return value.subscribers[]

func getSubscribers*(suber: ParaSuber): IntSet =
  for (topic , index) in suber.topicdata.keys():
    suber.topicdata.withFound(topic, index): result.incl(value.subscribers[])
      
func getSubscribers*(suber: ParaSuber, topics: openArray[Topic]): IntSet =
  ## Gets subscribers that are subscribing to any of the topics (set union).
  for topic in topics:
    suber.topicdata.withValue(topic): result.incl(value.subscribers[])

proc getSubscribers*(suber: ParaSuber, topics: IntSet, toset: var IntSet, clear = true) =
  ## Gets subscribers to given message into the `toset` given as parameter.
  ## If `clear` is true, the `toset` is cleared first.
  if clear: toset.clear()
  for topic in topics.items():
    #suber.topicdata.withValue(Topic(topic)): toset.incl(value[].topicdata[])
    suber.topicdata.withValue(Topic(topic)): toset.incl(value.subscribers[])
    

func isSubscriber*(suber: ParaSuber, subscriber: Subscriber, topic: Topic): bool =
  suber.topicdata.withValue(topic): return value.subscribers[].contains(int(subscriber))

template testSubscriber() =
  suber.topicdata.withValue(topic):
    if not value.subscribers[].contains(int(subscriber)): return false
  do: return false

func isSubscriber*(suber: ParaSuber, subscriber: Subscriber, topics: openArray[Topic]): bool =
  for topic in topics: testSubscriber()
  true

proc isSubscriber*(suber: ParaSuber, subscriber: Subscriber, topics: IntSet): bool =
  for topic in topics.items(): testSubscriber()
  true

proc getCurrentTimestamp*(suber: ParaSuber, topic: Topic): MonoTime =
  suber.topicdata.withValue(topic): return value.currenttimestamp

proc updateTimestamps*(suber: Parasuber, topics: Intset, timestamp: MonoTime) =
  for topic in topics.items():
    suber.topicdata.withValue(topic): value.currenttimestamp = timestamp

proc updateTimestamps*(suber: Parasuber, pendel: PendingDelivery) =
  suber.updateTimestamps(pendel.topics, pendel.timestamp)
  suber.pendingdelivery.release(pendel.pendingdeliverypoolindex)

proc release*(suber: Parasuber, pendel: PendingDelivery) =
  suber.pendingdelivery.release(pendel.pendingdeliverypoolindex)

template loop() =
  while true:
    if suber.afterworker and queue != 0: continue
    if suber.pendingdeliveries[queue].len == 0:
      withLock(suber.lock):
        if suber.pendingdeliveries[queue].len == 0:
          suber.queuesubscribers[queue].clear()
          # vapauta kaikki varatut pendelit (täytyy kerätä seqqiin...)
          suber.workers -= 1
          if queue == 0:
            suber.afterworker = false
            break
          elif not suber.afterworker and suber.workers == 0 and suber.pendingdeliveries[0].len > 0:
            suber.workers = 1
            suber.afterworker = true
            queue = 0
          else: break
    let timestamp = getMonoTime()
    suber.pendingdelivery[suber.pendingdeliveries[queue][suber.pendingdeliveries[queue].len - 1]].timestamp = timestamp
    yield suber.pendingdelivery[suber.pendingdeliveries[queue].popLast()]

iterator send*[T, MaxTopics](suber: ParaSuber[T, MaxTopics], topics: sink IntSet, message: T, exclusivereceiver = NoSubscriber): PendingDelivery[T] =
  # PendingDeliveryt poolista (tarvii laittaa item-inttti talteen jotta voi releasata)
  # subscriberit PendingDeliveryen
  # var pendingdelivery = PendingDelivery[T](exclusivereceiver: NoSubscriber, topics: topics, msg: message)
  var iterate = true
  let pendel = suber.pendingdelivery.reserve()
  if pendel == PoolFull: iterate = false
  if iterate:
    suber.pendingdelivery[pendel].pendingdeliverypoolindex = pendel
    suber.pendingdelivery[pendel].subscribers.clear()
    suber.pendingdelivery[pendel].topics = topics
    suber.pendingdelivery[pendel].msg = message
    if exclusivereceiver != NoSubscriber: suber.pendingdelivery[pendel].subscribers.incl(exclusivereceiver.int)
    else: suber.getSubscribers(topics, suber.pendingdelivery[pendel].subscribers)
    if suber.pendingdelivery[pendel].subscribers.len == 0:
      suber.pendingdelivery.release(pendel)
      iterate = false
  
  if iterate:
    var queue = - 1  
    withLock(suber.lock):
      var uniquejointq = -1
      for q in countup(1, suber.pendingdeliveries.len - 1):
        if disjoint(suber.pendingdelivery[pendel].subscribers, suber.queuesubscribers[q]):
          if uniquejointq == -1 and suber.queuesubscribers[q].len == 0: queue = q
        else:
          if uniquejointq == -1: uniquejointq = q
          else:
            uniquejointq = -1
            queue = 0
            break
      if uniquejointq != -1: queue = uniquejointq
      if queue == -1:
        suber.pendingdeliveries.add(initDeque[PoolItem](20))
        suber.queuesubscribers.add(initIntSet())
        queue = suber.pendingdeliveries.len - 1
      suber.pendingdeliveries[queue].addFirst(pendel)
      iterate = queue != 0 and suber.queuesubscribers[queue].len == 0
      if iterate: suber.workers += 1
      suber.queuesubscribers[queue].incl(suber.pendingdelivery[pendel].subscribers)

      #[for x in countup(1, suber.pendingdeliveries.len - 1):
        for y in countup(1, suber.pendingdeliveries.len - 1):
          if x == y: continue
          if not disjoint(suber.queuesubscribers[x], suber.queuesubscribers[y]):
            echo "buggy"
            echo "q: ", queue
            echo queue, ": ", suber.queuesubscribers[queue]
            echo x, ": ", suber.queuesubscribers[x]
            echo y, ": ", suber.queuesubscribers[y]
            quit()]#

    if iterate: loop
    

# template send*(suber: ParaSuber, topics: openArray[Topic], message: untyped): untyped =
#   suber.send(toIntSet(topics), message)

let emptyset: IntSet = initIntSet()

iterator send*[T, MaxTopics](suber: ParaSuber[T, MaxTopics], receiver: Subscriber, message: T): PendingDelivery[T] =
  for pendel in suber.send(topics: emptyset, message, exclusivereceiver: receiver): yield pendel
  #[var queue = - 1
  var iterate = false
  withLock(suber.lock):
    var uniquejointq = -1
    for q in countup(1, suber.pendingdeliveries.len - 1):
      if not suber.queuesubscribers[q].contains(receiver):
        if suber.queuesubscribers[q].len == 0: queue = q
      else:
        queue = q
        break
    if queue == -1:
      suber.pendingdeliveries.add(initDeque[NestedType(T)](20))
      suber.queuesubscribers.add(initIntSet())
      queue = suber.pendingdeliveries.len - 1
    suber.pendingdeliveries[queue].addFirst(PendingDelivery[T](exclusivereceiver: receiver, topics: topics, msg: message))
    iterate = queue != 0 and suber.queuesubscribers[queue].len == 0
    if iterate: suber.workers += 1
    suber.queuesubscribers[queue].incl(receiver)
  if iterate: loop]#

{.pop.}

#[ import std/segfaults

import os, random

randomize()


let topics = ["Art", "Science", "Nim", "Fishing"]
let subscribers = ["Amy", "Bob", "Chas", "Dave"]
let messagedatas = ["Good News", "Bad News", "Breaking News", "Old News"]
let publishers = ["Helsinki", "Tallinn", "Oslo", "Edinburgh"]
let bus = newParaSuber[string, 4]() # string datas, max 4 topics  

var stop = false

proc writeMessage(message: PendingDelivery) =
  try:
    var subscriberids: IntSet
    stdout.write("to ")      
    bus.getSubscribers(message.topics, subscriberids)
    for subscriberid in subscriberids: stdout.write(subscribers[subscriberid] & " & ")
    stdout.write("\b\bconcerning ")
    for topic in message.topics.items(): stdout.write(topics[topic.int] & " & ")
    stdout.writeLine("\b\b: " & message.msg)
    for topic in message.topics.items():
      stdout.writeLine(topics[topic.int] & ": " & $bus.getCurrentTimestamp(topic) & "->" & $message.timestamp)
    stdout.writeLine("")
    stdout.flushFile()
    # if subscriber > -1: echo "--"
  except: discard # write IOError

proc generateMessages(publisher: int) {.thread.} =
  {.gcsafe.}:
    var x = 0
    while true:
      if x == 10: break
      x += 1
      #if stop: break else: (sleep(100+rand(500)) ; if stop: break)      
      # write(stdout, $publishers[publisher] & ", "); flushFile(stdout)
      var messagetopics = initIntSet()
      for topicnumber in 1 .. 1 + rand(1): messagetopics.incl(rand(3))
      let msg = messagedatas[rand(3)] & " from " & publishers[publisher]
      for message in bus.send(messagetopics, msg):
        writeMessage(message)
        # echo message

# for i in 0 ..< 4: (for j in 0 .. i: bus.subscribe(i.Subscriber, j.Topic, true))

for i in 0 ..< 4: bus.subscribe(i.Subscriber, i.Topic, true)

var publisherthreads: array[4, Thread[int]]
for i in 0 ..< 4: createThread(publisherthreads[i], generateMessages, i)
joinThreads publisherthreads

# generateMessages(1) ]#