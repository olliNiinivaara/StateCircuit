
when not defined(gcDestructors): {.fatal: "gc:arc or orc compiler option required".}

import std/[intsets, sets, monotimes, deques, locks]
import pkg/stashtable
export intsets, monotimes, incl

const StateCircusMaxTopics* {.intdefine.} = 10000
const StateCircusMaxTopicsPerDelivery* {.intdefine.} = 20

type
  Topic* = distinct int
  Subscriber* = distinct int
  TopicStamp* = tuple[topic: Topic, old: MonoTime , now: MonoTime]
  TopicDatum = tuple[subscribers: ref IntSet, currenttimestamp: MonoTime]
  Subber* = StashTable[Topic, TopicDatum, StateCircusMaxTopics]

const NoTopic* = Topic(int.low + 3)
const NoSubscriber* = Subscriber(int.low + 3)
  
{.push checks:off.}

proc `==`*(x, y: Topic): bool {.borrow.}
proc `==`*(x, y: Subscriber): bool {.borrow.}
proc `$`*(x: Topic): string {.borrow.}
proc `$`*(x: Subscriber): string {.borrow.}

converter toTopic(x: int): Topic = Topic(x)

type FakeMonoTime = object
  ticks: int64

func toMonoTime*(i: int64): MonoTime {.inline.} =
  let monotime = FakeMonoTime(ticks: i)
  result = cast[MonoTime](monotime)

let ZeroTime* = toMonoTime(0)

func newSubber*(): Subber =
  return newStashTable[Topic, TopicDatum, StateCircusMaxTopics]()


proc addTopic*(sub: Subber, topic: Topic | int): bool {.discardable.} =
  ## Adds new topic.
  ## 
  ## Returns false if maximum number of topics is already added.
  var newsetref = new IntSet
  let (index , res) = sub.insert(topic, (newsetref , toMonoTime(0)))
  if res:
    sub.withFound(topic, index): value.subscribers[] = initIntSet()
  return res
  
proc removeTopic*(sub: Subber, topic: Topic) = sub.del(topic)

proc removeTopic*(sub: Subber, topic: int) = sub.del(toTopic(topic))

#[proc compactTopics() =
  # TODO: remove topics without subscribers
  discard]#

proc hasTopic*(sub: Subber, topic: Topic | int): bool =
  not (findIndex(sub, topic) == NotInStash)

proc getTopiccount*(sub: Subber): int = sub.len

proc getSubscribersbytopic*(sub: Subber): seq[tuple[id: Topic; subscribers: IntSet]] =
  ## Reports subscribers for each topic.
  for (topicid , index) in sub.keys():
    sub.withFound(topicid, index):
      result.add((topicid, value.subscribers[]))

proc subscribe*(sub: Subber, subscriber: Subscriber, topic: Topic | int; createnewtopic = true): bool {.discardable.} =
  ## Creates new subscription. If `createnewtopic` is false, the topic must already exist,
  ## otherwise it is added as needed.
  withValue(sub, topic):
    value.subscribers[].incl(int(subscriber))
    return true
  do:
    if not createnewtopic: return false
    var newsetref = new IntSet
    let (index , res) = sub.insert(topic, (newsetref , toMonoTime(0)))
    if res:
      sub.withFound(topic, index):
        value.subscribers[] = initIntSet()
        value.subscribers[].incl(int(subscriber))
    return res
    
proc unsubscribe*(sub: Subber, subscriber: Subscriber, topic: Topic) =
  ## Removes a subscription.
  sub.withValue(topic): value.subscribers[].excl(int(subscriber))

proc removeSubscriber*(sub: Subber, subscriber: Subscriber) =
  ## Removes all subscriptions of the subscriber.
  for (topicid , index) in sub.keys():
    sub.withFound(topicid, index): value.subscribers[].excl(int(subscriber))
        
proc getSubscriptions*(sub: Subber, subscriber: Subscriber): seq[Topic] =
  for (topic , index) in sub.keys():
    sub.withFound(topic, index):
      if value.subscribers[].contains(int(subscriber)): result.add(topic)

proc getSubscribers*(sub: Subber, topic: Topic | int): IntSet =
  sub.withValue(topic): return value.subscribers[]

proc getAllSubscribers*(sub: Subber): IntSet =
  for (topic , index) in sub.keys():
    sub.withFound(topic, index): result.incl(value.subscribers[])

proc getSubscribers*(sub: Subber, topicstamps: openArray[TopicStamp], toset: var IntSet) =
  ## Gets subscribers that are subscribing to any of the topics (set union) toset.
  toset.clear()
  for topicstamp in topicstamps:
    sub.withValue(topicstamp.topic): toset.incl(value.subscribers[])
    
proc isSubscriber*(sub: Subber, subscriber: Subscriber, topic: Topic): bool =
  sub.withValue(topic): return value.subscribers[].contains(int(subscriber))

template testSubscriber() =
  sub.withValue(topic):
    if not value.subscribers[].contains(int(subscriber)): return false
  do: return false

proc isSubscriber*(sub: Subber, subscriber: Subscriber, topics: openArray[Topic]): bool =
  for topic in topics: testSubscriber()
  true

proc isSubscriber*(sub: Subber, subscriber: Subscriber, topics: IntSet): bool =
  for topic in topics.items(): testSubscriber()
  true

proc getOldTimestamp*(sub: Subber, topic: Topic): TopicStamp =
  sub.withValue(topic):
    result[0] = topic
    result[1] = value.currenttimestamp
    result[2] = value.currenttimestamp
  do:
    result = (NoTopic, ZeroTime , ZeroTime)

proc getNewTimestamp*(sub: Subber, topic: Topic): TopicStamp =
  sub.withValue(topic):
    result[0] = topic
    result[1] = value.currenttimestamp
    value.currenttimestamp = getMonoTime()
    result[2] = value.currenttimestamp
  do:
    result = (NoTopic, ZeroTime , ZeroTime)