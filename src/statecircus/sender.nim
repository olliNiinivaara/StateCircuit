var subscribers {.threadvar.}: IntSet
var wsd {.threadvar.}: WsDelivery
var wsdmessage {.threadvar.}: string

template sendDelivery() =
  if unlikely(wsd.message == nil): wsd.message = addr wsdmessage
  wsd.sockets.setLen(0)
  wsd.binary = false
  wsd.message[].setLen(0)
  wsd.message[].add("""{"x":"u", """)
  if topicstamps.len > 0:
    wsd.message[].add(""""tos":[""")
    for topicstamp in topicstamps:
      wsd.message[].add("""{"to":""")
      wsd.message[].add($topicstamp.topic)
      wsd.message[].add(""","old":""")
      wsd.message[].add($topicstamp.old)
      wsd.message[].add(""","now":""")
      wsd.message[].add($topicstamp.now)
      wsd.message[].add("},")
    if wsd.message[wsd.message[].high] == ',':
      wsd.message[wsd.message[].high] = ']'
    else: wsd.message[].add(']')
    wsd.message[].add(",")
  wsd.message[].add(msg)
  wsd.message[].add("}")
  for clientkey in subscribers:
    let session = circus.getConnection(clientkey)
    if session.clientkey == NoClientKey or session.websocket == INVALID_SOCKET: continue
    wsd.sockets.add(session.websocket)
  discard circus.server.send(addr wsd)

proc sendToSubscribers*(circus: StateCircus, topicstamps: openArray[TopicStamp], msg: sink string) =
  circus.sub.getSubscribers(topicstamps, subscribers)
  if subscribers.len > 0: sendDelivery()

proc sendToOne*(circus: StateCircus, clientkey: ClientKey, topicstamps: openArray[TopicStamp], msg: sink string) =
  subscribers.clear()
  subscribers.incl(clientkey.int)
  sendDelivery()

proc sendToOne*(circus: StateCircus, clientkey: ClientKey, msg: sink string) =
  let topicstamps: array[0, TopicStamp] = []
  subscribers.clear()
  subscribers.incl(clientkey.int)
  sendDelivery()