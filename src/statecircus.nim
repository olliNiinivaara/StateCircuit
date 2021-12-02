import random, times, locks, json, std/monotimes
from math import `^`
from strmisc import rpartition
from parseutils import parseBiggestInt
from os import sleep
from httpcore import HttpCode, Http400, Http403, Http500, Http503

import parasuber
import pkg/[guildenstern/ctxws, stashtable]
import poolpart

import statecircus/replies

export ctxws, parasuber, poolpart, replies, sleep, Http400, Http403, Http500, Http503

#[
  x:
  i: initialization (at first websocket upgrade)
  q: query
  u: update
  l: logout
  o: server overload (should never happen)
]#
const
  MaxSessions* {.intdefine.} = 1000
  MaxTopics* {.intdefine.} = 1000
  PoolSizes* {.intdefine.} = 200

type
  SessionKey* = distinct Subscriber

  Session*[T] = object
    sessionkey*: SessionKey
    userid*: string
    ip*: string
    websocket*: SocketHandle
    starttime*: DateTime
    data*: T

  Query*[T] = object
    session*: Session[T]
    path*: string
    topics*: IntSet
    json*: JsonNode
  
  ReplyMessage* = object
    pingsocket*: SocketHandle
    msgstring*: string
    
  StateCircus*[T] = object # maxsessions ja MessagePoolSize ja maxtopics: const static inteiks
    stash*: StashTable[int64, Session[T], MaxSessions]
    NoSession*: Session[T]
    ipheader*: string
    lock: Lock
    server*: GuildenServer
    replymessage*: PoolPart[ReplyMessage, PoolSizes]
    bus*: ParaSuber[PoolItem, MaxTopics]
    text*: PoolPart[string, PoolSizes]
    intset*: PoolPart[IntSet, PoolSizes]
    pendingdelivery*: PoolPart[PendingDelivery[PoolItem], PoolSizes]
    wsdelivery*: PoolPart[WsDelivery, PoolSizes]
    grantSubscriptions*: proc(session: Session[T], topics: IntSet): bool {.gcsafe, raises: [].}


const
  NoSessionKey* = 0.SessionKey
  RegistrationTimeWindow* {.intdefine.} = 3
  FailurePause* {.intdefine.} = 4000

let
  NoTimestamp* = toMonoTime(0)
  NullNode* = newJNull()
  LogoutMessage* = """{"x":"l"}"""
  OverloadMessage* = """{"x":"o"}"""

var
  websocketregistrationtimewindow* = initDuration(seconds = RegistrationTimeWindow)
  # TODO: use new OS random source
  randomer = initRand(getMonoTime().ticks())



proc `==`*(a,b: SessionKey): bool {.borrow.}
proc `$`*(a: SessionKey): string {.inline.} = $(int(a))

proc isSessionstoragefull[T](circus: StateCircus[T]): bool =
  circus.stash.len == MaxSessions

proc startSession*[T](circus: var StateCircus[T], ctx: HttpCtx, userid: string, data: T): SessionKey {.raises: [].} =
  withLock(circus.lock):
    if circus.isSessionstoragefull(): return NoSessionKey
    let sessionkey = SessionKey(1 + 2^20 * randomer.rand(2^20).int64 + randomer.rand(int32.high).int64)
    let userid =
      if userid == "": $sessionkey
      else: userid
    var oldsessionkey = NoSessionKey
    var oldsocket = INVALID_SOCKET
    for (key, index) in circus.stash.keys():
      circus.stash.withFound(key, index):
        if SessionKey(key) == sessionkey: return NoSessionKey # key already in use, improbable
        if value.userid == userid:
          oldsessionkey = SessionKey(key)
          oldsocket = value.websocket
    if not (oldsessionkey == NoSessionKey):
      circus.stash.del(int64(oldsessionkey))
      ctx.gs[].sendWs(oldsocket, LogoutMessage)
      ctx.gs[].closeOtherSocket(oldsocket, SecurityThreatened, "user started new session from different socket")

    var headervalue: array[1, string]
    if circus.ipheader != "": ctx.parseHeaders([circus.ipheader], headervalue)
    let session = Session[T](sessionkey: sessionkey, userid: userid, ip: headervalue[0], websocket: InvalidSocket, starttime: now(), data: data)
    circus.stash.insert(int64(sessionkey), session)
    return sessionkey

proc registerWebSocket*[T](circus: StateCircus[T], sessionkey: SessionKey, websocket: SocketHandle): bool =
  circus.stash.withValue(int64(sessionkey)):
    if value.websocket != INVALID_SOCKET:
      return false
    if websocketregistrationtimewindow <= now() - value.starttime:
      return false
    value.websocket = websocket
    return true
  do:
    return false

proc unregisterWebSocket*[T](circus: StateCircus[T], sessionkey: SessionKey) =
  circus.stash.withValue(int64(sessionkey)): value.websocket = INVALID_SOCKET

proc findSessionKey*[T](circus: StateCircus[T], websocket: SocketHandle): SessionKey =
  for (k , index) in circus.stash.keys:
    circus.stash.withFound(k, index):
      if value.websocket == websocket: return value.sessionkey
  return NoSessionKey

proc endSession*[T](circus: StateCircus[T], sessionkey: SessionKey) =
  circus.stash.del(int64(sessionkey))

proc getSession*[T](circus: StateCircus[T], sessionkey: SessionKey | Subscriber | int): Session[T] {.inline.} =
  circus.stash.withValue(int64(sessionkey)):
    return value[]
  do:
    return circus.NoSession

proc getSession*[T](circus: StateCircus[T], sessionkey: SessionKey, ctx: Ctx): Session[T] =
  let session = circus.getSession(sessionkey)
  if session.sessionkey == NoSessionKey or session.websocket != ctx.socketdata.socket:
    ctx.closeSocket(SecurityThreatened)
  return session

proc getSessionPtr*[T](circus: StateCircus[T], sessionkey: SessionKey | Subscriber | int): ptr Session[T] {.inline.} =
  circus.stash.withValue(int64(sessionkey)):
    return value
  do:
    return nil

proc addTopic*[T](circus: StateCircus[T], topic: Topic): bool {.inline, discardable.} =
  {.gcsafe.}: return circus.bus.addTopic(topic)

proc removeTopic*[T](circus: StateCircus[T], topic: Topic) {.inline.} =
  {.gcsafe.}: circus.bus.removeTopic(topic)

proc subscribe*[T](circus: StateCircus[T], sessionKey: SessionKey, topic: Topic) =
  {.gcsafe.}: discard circus.bus.subscribe(sessionKey.Subscriber, topic, true)

proc subscribe*[T](circus: StateCircus[T], sessionKey: SessionKey, topics: IntSet) =
  {.gcsafe.}:
    for topic in topics:
      discard circus.bus.subscribe(sessionKey.Subscriber, topic, true)

template replyFail*(httpfailcode = Http500, failmsg = "", replywithfailmsg = false) =
  if httpfailcode.int >= 500: ctx.gs[].log(ERROR, failmsg)
  elif httpfailcode.int >= 400: ctx.gs[].log(NOTICE, failmsg)
  else: ctx.gs[].log(INFO, failmsg)
  if replywithfailmsg:
    let msg = failmsg
    ctx.reply(httpfailcode, msg)
  else: ctx.reply(httpfailcode)
  return

proc replyLogin*(ctx: HttpCtx, websocketpath: string, sessionkey: SessionKey) =
  if sessionkey == NoSessionKey: replyFail(Http403)
  else:
    var s = $(%*{"websocketpath": websocketpath, "sessionkey": sessionkey.int64})
    ctx.reply(Http200, s)

proc validateIp[T](circus: StateCircus[T], ctx: HttpCtx, session: Session): bool =
  var headervalue: array[1, string]
  if circus.ipheader != "": ctx.parseHeaders([circus.ipheader], headervalue)
  return headervalue[0] == session.ip

proc getSessionkey*[T](circus: StateCircus[T], ctx: HttpCtx, bodyjson: JsonNode): SessionKey =
  result =
    try: bodyjson["k"].getInt().SessionKey
    except: replyFail(Http400, "no sessionkey")
  let session = circus.getSession(result)
  if (unlikely)session.sessionkey == NoSessionKey: replyFail(Http400, "no session")
  if unlikely(not circus.validateIp(ctx, session)):
    result = NoSessionKey
    replyFail(Http400, "wrong ip")

template addQuerystamps() =
  if topicstamps.len > 0:
    queryreply.add(""""tos":[""")
    for topicstamp in topicstamps:
      queryreply.add("""{"to":""")
      queryreply.add($topicstamp[0])
      queryreply.add(""","at":""")    
      queryreply.add($topicstamp[1])
      queryreply.add("},")
    queryreply[queryreply.high] = ']'
    queryreply.add(",")

template addTopicstamps() =
  circus.wsdelivery[wsd].message.add(""""tos":[""")
  for topic in pendingDelivery.topics.items():
    circus.wsdelivery[wsd].message.add("""{"to":""")
    circus.wsdelivery[wsd].message.add($topic)
    circus.wsdelivery[wsd].message.add(""","at":""")    
    circus.wsdelivery[wsd].message.add($circus.bus.getCurrentTimestamp(topic))
    circus.wsdelivery[wsd].message.add("},")
  circus.wsdelivery[wsd].message[circus.wsdelivery[wsd].message.high] = ']'
  circus.wsdelivery[wsd].message.add(",")

proc getQuery*[T](circus: var StateCircus[T], ctx: HttpCtx): Query[T] =
  try:
    let body = parseJson(ctx.getBody())
    let sessionkey = circus.getSessionkey(ctx, body)
    if sessionkey == NoSessionKey: return
    result.session = circus.getSession(sessionkey)
    result.path = ctx.getUri().substr(3)
    if body.hasKey("t"):
      result.topics = body["t"].to(seq[int]).toIntSet()
      if unlikely(not circus.bus.isSubscriber(Subscriber(result.session.sessionkey), result.topics)):
        if unlikely(circus.grantSubscriptions == nil) or not circus.grantSubscriptions(result.session, result.topics):
          (result.path = "" ; replyFail(Http403, "subscription(s) not granted"))
    result.json = body.getOrDefault("q")
  except: (result.path = "" ; replyFail())

# TODO: httpreplyn sijaan ws-messageen response (ja d pois)
proc replyToHttp*[T](circus: StateCircus[T], ctx: HttpCtx, query: sink Query, queryproc: proc(): string {.gcsafe, raises: [].}) {.gcsafe.} =  
  var
    queryresult: string
    failures = 0
    topicstamps: seq[(Topic , MonoTime)] = @[]
  while true:
    var failed = false
    topicstamps.setLen(0)
    for topic in query.topics.items():
      topicstamps.add((Topic(topic) , circus.bus.getCurrentTimestamp(Topic(topic))))
    queryresult = queryproc()
    if queryresult == "": queryresult = "null"
    for topicstamp in topicstamps:
      if circus.bus.getCurrentTimestamp(topicstamp[0]) != topicstamp[1]:
          failed = true
          break
    failures = failures + (if failed: 1 else: 100)
    if failures > 9: break

  if failures == 10: replyFail(Http503, "Failed to get query with valid topic stamps")
  var queryreply = """{"x":"q", "d":{"""
  addQuerystamps()
  queryreply.add(""""st": {""")
  queryreply.add(queryresult)
  queryreply.add("}}}")
  ctx.reply(queryreply)

proc connectWebsocket*[T](circus: StateCircus[T], ctx: WsCtx): Session[T] {.raises: [].} =
  var sessionkey = NoSessionKey
  try:
    var i: BiggestInt
    discard parseBiggestInt(ctx.getUri().rpartition("/S")[2], i)
    sessionkey = i.SessionKey
  except:
    circus.server.log(WARN, "could not parse session key from: " & ctx.getUri())
    return
  {.gcsafe.}:
    if circus.registerWebSocket(sessionkey, ctx.socketdata.socket): return circus.getSession(sessionkey)

proc tryToLock*[T](circus: StateCircus[T], ctx: HttpCtx) =
  let success = "true"
  let body = 
    try: parseJson(ctx.getBody())
    except: replyFail(Http400)
  let sessionkey = circus.getSessionkey(ctx, body)
  if sessionkey == NoSessionKey: return
  # TODO: lock may require that userid is subscribed to a topic
  # TODO: if now - lockedsince > maxlockduration, release lock
  # TODO: if lock owner == userid, only refresh lockedsince
  ctx.reply(success)

proc releaseLock*[T](circus: StateCircus[T], sessionkey: SessionKey, lock: string) =
  # TODO ...
  discard

proc send*[T](circus: StateCircus[T], topics: openArray[Topic], msg: string, pingsocket = INVALID_SOCKET) =
  var deliveryindices: seq[PoolItem] = newSeq[PoolItem]()
  var deliveries: seq[ptr WsDelivery] = newSeq[ptr WsDelivery]()

  let reply = circus.replymessage.reserve()
  circus.replymessage[reply].pingsocket = pingsocket
  circus.replymessage[reply].msgstring = msg
  for pendingDelivery in circus.bus.send(toIntSet(topics), reply):
    if circus.replymessage[pendingDelivery.msg].pingsocket != INVALID_SOCKET:
      circus.server.sendPong(circus.replymessage[pendingDelivery.msg].pingsocket)
      circus.replymessage.release(pendingDelivery.msg)
      circus.bus.release(pendingDelivery)
      continue
    deliveryindices.setLen(0)
    deliveries.setLen(0)
    var wsd = circus.wsdelivery.reserve()
    try:
      circus.wsdelivery[wsd].sockets.setLen(0)
      circus.wsdelivery[wsd].binary = false
      circus.wsdelivery[wsd].message = """{"x":"u", "d":{"now": """
      circus.wsdelivery[wsd].message.add($pendingDelivery.timestamp.ticks())
      circus.wsdelivery[wsd].message.add(",")
      addTopicstamps()
      circus.wsdelivery[wsd].message.add(circus.replymessage[pendingDelivery.msg].msgstring)
      circus.wsdelivery[wsd].message.add("}}")
      for sessionkey in pendingDelivery.subscribers:
        let session = circus.getSession(sessionkey)
        if session.sessionkey == NoSessionKey or session.websocket == INVALID_SOCKET: continue
        circus.wsdelivery[wsd].sockets.add(session.websocket)
      deliveries.add(addr circus.wsdelivery[wsd])  
      deliveryindices.add(move(wsd))
      discard circus.server.multisendWs(deliveries)
    finally:
      for wsdindex in deliveryindices: circus.wsdelivery.release(wsdindex)
      circus.replymessage.release(pendingDelivery.msg)
      circus.bus.updateTimestamps(pendingDelivery)


proc receiveMessage*[T](circus: StateCircus[T], ctx: WsCtx): (Session[T] , string, JsonNode) {.raises: [].} =
  # tSEKKAA että pooleissa on tilaa ennen kuin websockettia aletaan ees  prosessoida ja palauttaa heti overload-messagen jos
  # yksikin pooleista on täynnä
  const NoTopics: array[0, Topic] = []
  {.gcsafe.}:
    try:
      if circus.server.loglevel == TRACE: echo ctx.getRequest()
      if ctx.isRequest("PING"):
        result[0].sessionKey = NoSessionKey
        circus.send(NoTopics, "PING", ctx.socketdata.socket)
        return
      let msg = parseJson(ctx.getRequest())
      let sessionKey = msg["k"].getInt().SessionKey
      result[0] = circus.getSession(sessionKey, ctx)
      if result[0].sessionKey == NoSessionKey: return
      result[1] = msg["e"].getStr()
      result[2] = msg["m"]
    except: circus.server.log(ERROR, "receiveMessage failed")

proc logOut*[T](circus: StateCircus[T], sessionKey: SessionKey, closesocket = true): Session[T] =
  circus.bus.removeSubscriber(sessionKey.Subscriber)   # TODO: if last subscriber for a topic, compact parasuber
  result = circus.getSession(sessionKey)
  if result.sessionKey == NoSessionKey: return
  circus.endSession(result.sessionKey)
  # TODO: release all locks held by this userid
  if closesocket and result.websocket != INVALID_SOCKET:
    circus.server.closeOtherSocket(result.websocket, CloseCalled)

proc onClose*[T](circus: var StateCircus[T], ctx: Ctx, socket: SocketHandle, cause: SocketCloseCause): Session[T] =
  if ctx.getProtocolName() != "websocket": return
  {.gcsafe.}:
    let sessionKey = circus.findSessionKey(socket)
    if sessionKey == NoSessionKey: circus.NoSession
    else:
      circus.unregisterWebSocket(sessionKey)
      if cause == ConnectionLost: circus.NoSession
      else: circus.logOut(sessionKey, false)

proc newStateCircus*[T](ipheader = ""): StateCircus[T] =
  result = StateCircus[T]()
  result.stash = newStashTable[int64, Session[T], MaxSessions]()
  result.NoSession = Session[T]()
  result.lock.initLock()
  result.bus = newParaSuber[PoolItem, MaxTopics]()  
  result.server = new GuildenServer
  result.replymessage = newPoolPart[ReplyMessage, PoolSizes]()
  result.ipheader = ipheader
  result.text = newPoolPart[string, PoolSizes]()
  result.wsdelivery = newPoolPart[WsDelivery, PoolSizes]()
  result.intset = newPoolPart[IntSet, PoolSizes]()
  for intset in result.intset.all(): intset = initIntSet()