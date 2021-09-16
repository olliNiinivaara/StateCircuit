import random, times, locks, json, std/monotimes
from math import `^`
from strmisc import rpartition
from parseutils import parseBiggestInt
from os import sleep
from httpcore import HttpCode, Http400, Http403, Http500, Http503

import suber
import guildenstern/ctxws
import stashtable

export ctxws, suber, sleep, Http400, Http403, Http500

#[
  x:
  i: initialization (at first websocket upgrade)
  q: query (parallel)
  u: update (instant delivery)
  r: refresh (pullAll within HttpCtx)
  o: server overload (should never happen)
]#

type
  SessionKey* = distinct int64

  Session*[T] = object
    sessionkey*: SessionKey
    userid*: string
    ip*: string
    websocket*: SocketHandle
    starttime*: DateTime
    initialized*: bool
    pendingpullctx*: HttpCtx
    data*: T

  Query*[T] = object
    ctx*: HttpCtx
    session*: Session[T]
    path*: string
    topics*: IntSet
    querynode*: JsonNode

  Payload* = object
    state*: string
    actions*: string

  StateCircus*[T; MaxSessions: static int; MaxTopics: static int] = object
    stash*: StashTable[int64, Session[T], MaxSessions]
    NoSession*: Session[T]
    ipheader*: string
    pendingpulls: int
    lock: Lock
    server*: GuildenServer
    bus*: Suber[Payload, MaxTopics]
    topicstamps*: StashTable[Topic, int64, MaxTopics]
    grantSubscriptions*: proc(session: Session[T], topics: IntSet): bool {.gcsafe, raises: [].}

const
  NoSessionKey* = 0.SessionKey
  RegistrationTimeWindow* {.intdefine.} = 3
  FailurePause* {.intdefine.} = 4000

let
  NoTimestamp* = toMonoTime(0)
  NullNode* = newJNull()
  OverloadMessage* = """{"x":"o"}"""

var
  response* {.threadvar.}: string
  websocketregistrationtimewindow* = initDuration(seconds = RegistrationTimeWindow)
  randomer = initRand(getMonoTime().ticks())


proc `==`*(a,b: SessionKey): bool {.borrow.}
proc `$`*(a: SessionKey): string {.borrow.}

proc isSessionstoragefull[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics]): bool =
  circus.stash.len == MaxSessions

proc startSession*[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], ctx: HttpCtx, userid: string, data: T): SessionKey {.raises: [].} =
  if userid == "": return NoSessionKey
  withLock(circus.lock):
    if circus.isSessionstoragefull(): return NoSessionKey
    let sessionkey = SessionKey(1 + 2^20 * randomer.rand(2^20).int64 + randomer.rand(int32.high).int64)
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
      var msg = """{"logout": true}"""
      ctx.gs[].sendWs(oldsocket, msg)
      ctx.gs[].closeOtherSocket(oldsocket, SecurityThreatened, "user started new session from different socket")

    var headervalue: array[1, string]
    if circus.ipheader != "": ctx.parseHeaders([circus.ipheader], headervalue)
    let session = Session[T](sessionkey: sessionkey, userid: userid, ip: headervalue[0], websocket: InvalidSocket, starttime: now(), initialized: false, pendingpullctx: nil, data: data)
    circus.stash.insert(int64(sessionkey), session)
    return sessionkey

proc registerWebSocket*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionkey: SessionKey, websocket: SocketHandle): bool =
  circus.stash.withValue(int64(sessionkey)):
    if value.websocket != INVALID_SOCKET:
      return false
    if websocketregistrationtimewindow <= now() - value.starttime:
      return false
    value.websocket = websocket
    return true
  do:
    return false

proc unregisterWebSocket*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionkey: SessionKey) =
  circus.stash.withValue(int64(sessionkey)): value.websocket = INVALID_SOCKET

proc findSessionKey*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], websocket: SocketHandle): SessionKey =
  for (k , index) in circus.stash.keys:
    circus.stash.withFound(k, index):
      if value.websocket == websocket: return value.sessionkey
  return NoSessionKey

proc endSession*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionkey: SessionKey) =
  circus.stash.del(int64(sessionkey))

proc getSession*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionkey: SessionKey | Subscriber | int): Session[T] {.inline.} =
  circus.stash.withValue(int64(sessionkey)):
    return value[]
  do:
    return circus.NoSession

proc getSession*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionkey: SessionKey, ctx: Ctx): Session[T] =
  let session = circus.getSession(sessionkey)
  if session.sessionkey == NoSessionKey or session.websocket != ctx.socketdata.socket:
    ctx.closeSocket(SecurityThreatened)
  return session

proc addTopic*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], topic: Topic): bool {.inline, discardable.} =
  {.gcsafe.}:
    circus.topicstamps.insert(topic, 0)
    return circus.bus.addTopic(topic)

proc removeTopic*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], topic: Topic) {.inline.} =
  {.gcsafe.}:
    circus.topicstamps.del(topic)
    circus.bus.removeTopic(topic)

proc subscribe*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionKey: SessionKey, topic: Topic) =
  {.gcsafe.}:
    circus.topicstamps.insert(topic, 0)
    discard circus.bus.subscribe(sessionKey.Subscriber, topic, true)

proc subscribe*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionKey: SessionKey, topics: IntSet) =
  {.gcsafe.}:
    for topic in topics:
      circus.topicstamps.insert(topic.Topic, 0)
      discard circus.bus.subscribe(sessionKey.Subscriber, topic, true)

proc push*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], topics: sink openArray[Topic], state: sink JsonNode, actions: sink JsonNode = NullNode) {.inline.} =
  {.gcsafe.}:
    if topics.len == 1: circus.bus.push(topics[0], Payload(state: $state, actions: $actions))
    else: circus.bus.push(topics.toIntSet(), Payload(state: $state, actions: $actions))

proc pushActions*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], topics: sink openArray[Topic], actions: sink JsonNode) {.inline.} =
  {.gcsafe.}:
    if topics.len == 1: circus.bus.push(topics[0], Payload(state: "null", actions: $actions))
    else: circus.bus.push(topics.toIntSet(), Payload(state: "null", actions: $actions))

proc push*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], topic: Topic, state: sink JsonNode, actions: sink JsonNode = NullNode) {.inline.} =
  {.gcsafe.}: circus.bus.push(topic, Payload(state: $state, actions: $actions))

proc pushActions*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], topic: Topic, actions: sink JsonNode) {.inline.} =
  {.gcsafe.}:circus.bus.push(topic, Payload(state: "null", actions: $actions))

proc pull*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionKey: SessionKey, topics: sink openArray[Topic], aftertimestamp: int64): bool {.discardable.} =
  {.gcsafe.}: return circus.bus.pull(sessionKey.Subscriber, toIntSet(topics), toMonotime(aftertimestamp))

proc doSynced*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], callback: proc() {.raises:[].}) =
  {.gcsafe.}: circus.bus.doSynced(callback)

template replyFail*(httpfailcode = Http500, failmsg = "") =
  when defined(fulldebug):
    if failmsg != "": echo failmsg
    elif getCurrentExceptionMsg() != "": echo getCurrentExceptionMsg()
  sleep(FailurePause)
  ctx.reply(httpfailcode)
  return

proc replyLogin*(ctx: HttpCtx, websocketpath: string, sessionkey: SessionKey) =
  if sessionkey == NoSessionKey: replyFail(Http403)
  else:
    var s = $(%*{"websocketpath": websocketpath, "sessionkey": sessionkey.int64})
    ctx.reply(Http200, s)

proc validateIp[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], ctx: HttpCtx, session: Session): bool =
  var headervalue: array[1, string]
  if circus.ipheader != "": ctx.parseHeaders([circus.ipheader], headervalue)
  return headervalue[0] == session.ip

proc replyToRefresh*[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], ctx: HttpCtx) =
  var session: Session[T]
  try:
    if circus.bus.getChannelQueueLengths[0] == circus.bus.getChannelQueueSize():
      replyFail(Http503, "server overload")
      return

    let body = parseJson(ctx.getBody())
    let sessionkey = body["k"].getInt().SessionKey
    session = circus.getSession(sessionkey)
    if (unlikely)session.sessionkey == NoSessionKey: replyFail(Http400, "no session")
    if unlikely(not circus.validateIp(ctx, session)): replyFail(Http400, "wrong ip")
    if (unlikely)session.pendingpullctx != nil: replyFail(Http400, "refresh pull already pending")
    circus.stash.withValue(int64(sessionkey)): value[].pendingpullctx = ctx
    do: replyFail(Http400, "no session")
    let aftertimestamp = body["at"].getInt()
    {.gcsafe.}:
      if not circus.bus.pullAll(sessionKey.Subscriber, toMonotime(aftertimestamp)):
        circus.stash.withValue(int64(sessionkey)): value[].pendingpullctx = nil
        ctx.reply(Http204)
    discard circus.pendingpulls.atomicInc()
  except:
    when defined(fulldebug): echo ctx.getBody()
    if session.sessionkey != NoSessionKey:
      circus.stash.withValue(int64(session.sessionkey)): value[].pendingpullctx = nil
    replyFail()

proc getQuery*[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], ctx: HttpCtx): Query[T] =
  try:
    result.path = ctx.getUri().substr(3)
    let body = parseJson(ctx.getBody())
    result.session = circus.getSession(body["k"].getInt().SessionKey)
    if (unlikely)result.session.sessionkey == NoSessionKey: (result.path = "" ; replyFail(Http400, "no session"))
    if unlikely(not circus.validateIp(ctx, result.session)): (result.path = "" ; replyFail(Http400, "wrong ip"))
    if body.hasKey("t"):
      result.topics = body["t"].to(seq[int]).toIntSet()
      if unlikely(not circus.bus.isSubscriber(Subscriber(result.session.sessionkey), result.topics)):
        if unlikely(circus.grantSubscriptions == nil) or not circus.grantSubscriptions(result.session, result.topics):
          (result.path = "" ; replyFail(Http403, "subscription(s) not granted"))
    result.querynode = body.getOrDefault("q")
  except: (result.path = "" ; replyFail())
  result.ctx = ctx

template addQuerystamps() =
  queryreply.add(""""tos":[""")
  for topicstamp in topicstamps:
    queryreply.add("""{"to":""")
    queryreply.add($topicstamp[0])
    queryreply.add(""","at":""")    
    queryreply.add($topicstamp[1])
    queryreply.add("},")
  queryreply[queryreply.high] = ']'

proc replyToQuery*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], ctx: HttpCtx, query: sink Query, queryproc: proc(parameters: JsonNode): string {.gcsafe, raises: [].}, parameters: JsonNode = NullNode) {.gcsafe.} =  
  var
    queryresult: string
    failures = 0
    topicstamps: seq[(Topic , int64)] = @[]
  while true:
    var failed = false
    topicstamps.setLen(0)
    for topic in query.topics.items():
      circus.topicstamps.withValue(topic):
        topicstamps.add((Topic(topic) , value[]))
    queryresult = queryproc(parameters)
    if queryresult == "": queryresult = "null"
    for topicstamp in topicstamps:
      circus.topicstamps.withValue(topicstamp[0]):
        if value[] != topicstamp[1]:
          failed = true
          break
    failures = failures + (if failed: 1 else: 100)
    if failures > 9: break

  if failures == 10: replyFail(Http503, "Failed to get query with valid topic stamps")
  var queryreply = """{"x":"q", "d":{"""
  addQuerystamps()
  queryreply.add(",")
  queryreply.add(""""st": """)
  queryreply.add(queryresult)
  queryreply.add("}}")
  ctx.reply(queryreply)

proc connectWebsocket*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], ctx: WsCtx): Session[T] {.raises: [].} =
  var sessionkey = NoSessionKey
  try:
    discard parseBiggestInt(ctx.getUri().rpartition("/S")[2], sessionkey.BiggestInt)
  except:
    when defined(fulldebug): echo "could not parse session key from: ", ctx.getUri()
    return
  {.gcsafe.}:
    if circus.registerWebSocket(sessionkey, ctx.socketdata.socket): return circus.getSession(sessionkey)

proc initMessage*(session: var Session, state = newJObject(), debug = not defined(release)): string =
  if session.initialized: return ""
  session.initialized = true
  var state = state
  state.add("debug", newJBool(debug))
  $(%*{"x":"i","st": state})

template handlePingAndOverload*() =
  if ctx.isRequest("PING"):
    circus.bus.doSynced(proc() = {.gcsafe.}: (circus.server.sendPong(ctx.socketdata.socket)))
    return
  if circus.bus.getChannelQueueLengths[0] == circus.bus.getChannelQueueSize():
    circus.bus.doSynced(proc() = {.gcsafe.}: (discard circus.server.sendWs(ctx.socketdata.socket, OverloadMessage)))
    return

proc receiveMessage*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], ctx: WsCtx): (Session[T] , string, JsonNode) {.raises: [].} =
  {.gcsafe.}:
    #[if ctx.isRequest("PING"):
      circus.bus.doSynced(proc() = {.gcsafe.}: (circus.server.sendPong(ctx.socketdata.socket)))
      return (circus.NoSession, "PING", NullNode)
      # fails with:  Error: cannot generate destructor for generic type: StashTableObject
      # see: https://github.com/nim-lang/Nim/issues/17319
      ]#
    try:
      when defined(fulldebug): echo ctx.getRequest()
      let msg = parseJson(ctx.getRequest())
      let sessionKey = msg["k"].getInt().SessionKey
      result[0] = circus.getSession(sessionKey, ctx)
      if result[0].sessionKey == NoSessionKey: return
      result[1] = msg["e"].getStr()
      result[2] = msg["m"]
      if result[1] == "__pull":
        let elems = result[2]["missedtopics"].getElems()
        var missedtopics: seq[Topic]
        for elem in elems: missedtopics.add(elem["to"].getInt().Topic)
        when defined(fulldebug):
          if missedtopics.len == 0: echo("pull request without missed topics")
        circus.pull(sessionKey, missedtopics, result[2]["aftertimestamp"].getInt())
    except:
      echo "receiveMessage failed: ", getCurrentExceptionMsg()

template addTopicstamps() =
  response.add(""""tos":[""")
  for topic in envelope.topics.items():
    circus.topicstamps.withValue(topic):
      response.add("""{"to":""")
      response.add($topic)
      response.add(""","at":""")    
      response.add($value[])
      response.add("},")
      value[] = envelope.timestamp.ticks()
  response[response.high] = ']'

proc writeUpdate*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], envelope: ptr SuberMessage[Payload]) {.inline.} =
  response.add("""{"now": """)
  response.add($envelope.timestamp.ticks())
  response.add(",")
  addTopicstamps()
  response.add(""","st": """)
  response.add(envelope.data.state)
  response.add( """, "a": """)
  response.add(envelope.data.actions)
  response.add("}")

proc onDelivery*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], envelopes: openArray[ptr SuberMessage[Payload]]) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    assert(envelopes.len == 1, "StateCircus only supports instant pub/sub delivery")
    var sessionkeys: IntSet
    var deliveries: seq[WsDelivery]
    var wsd: WsDelivery
    circus.bus.getSubscribers(envelopes[0], sessionkeys)
    if sessionkeys.len == 0: return
    response = """{"x":"u", "d":"""
    circus.writeUpdate(envelopes[0])
    response.add("}")
    wsd.message = response
    for sessionkey in sessionkeys:
      let session = circus.getSession(sessionkey)
      if session.sessionkey == NoSessionKey or session.websocket == INVALID_SOCKET: continue
      wsd.sockets.add(session.websocket)
    deliveries.add(move(wsd))
    discard circus.server.multisendWs(deliveries)
    response = ""

proc writeHistory*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], envelope: ptr SuberMessage[Payload]) {.inline.} =
  response.add("""{"then": """)
  response.add($envelope.timestamp.ticks())
  response.add(",")
  response.add(""""to":[""")
  for topic in envelope.topics.items():
    response.add($topic)
    response.add(",")
  response[response.high] = ']'
  response.add(""","st": """)
  response.add(envelope.data.state)
  response.add( """, "a": """)
  response.add(envelope.data.actions)
  response.add("}")
  
{.push hints:off.}
proc onPull*[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], sessionkey: Subscriber, expiredtopics: openArray[Topic], envelopes: openArray[ptr SuberMessage[Payload]]) {.raises:[].} =
  {.gcsafe.}:
    let session = circus.getSession(sessionkey)
    if session.sessionkey == NoSessionKey or session.pendingpullctx == nil or session.pendingpullctx.socketdata == nil or session.pendingpullctx.socketdata.socket == INVALID_SOCKET: return
    try:
      response.add("""{"x":"r", "d":[""")
      for index in countdown(high(envelopes), 0):
        circus.writeHistory(envelopes[index])
        if index > 0: response.add(",")
      if expiredtopics.len > 0:
        if envelopes.len > 0: response.add(",")
        response.add("""{"expiredtopics": """)
        response.add($expiredtopics)
        response.add("}")
      response.add("]}")
      reply(session.pendingpullctx, response)
    finally:
      circus.stash.withValue(int64(sessionkey)): value[].pendingpullctx = nil
      circus.pendingpulls.atomicDec()
      response = ""
{.pop.}

proc logOut*[T, MaxSessions, MaxTopics](circus: StateCircus[T, MaxSessions, MaxTopics], sessionKey: SessionKey, closesocket = true): Session[T] =
  circus.bus.removeSubscriber(sessionKey.Subscriber)
  result = circus.getSession(sessionKey)
  if result.sessionKey == NoSessionKey: return
  circus.endSession(result.sessionKey)
  if closesocket and result.websocket != INVALID_SOCKET:
    circus.server.closeOtherSocket(result.websocket, CloseCalled)

proc removePendingpull[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], ctx: Ctx) =
  for (sessionkey, session) in circus.stash.keys():
    circus.stash.withFound(sessionkey, session):
      if value[].pendingpullctx.socketdata.socket == ctx.socketdata.socket:
        circus.pendingpulls.atomicDec()
        break

proc onClose*[T, MaxSessions, MaxTopics](circus: var StateCircus[T, MaxSessions, MaxTopics], ctx: Ctx, socket: SocketHandle, cause: SocketCloseCause): Session[T] =
  if ctx.getProtocolName() != "websocket":
    if circus.pendingpulls > 0: circus.removePendingpull(ctx)
    circus.NoSession
  else:
    {.gcsafe.}:
      let sessionKey = circus.findSessionKey(socket)
      if sessionKey == NoSessionKey: circus.NoSession
      else:
        circus.unregisterWebSocket(sessionKey)
        if cause == ConnectionLost: circus.NoSession
        else: circus.logOut(sessionKey, false)

proc newStateCircus*[T; MaxSessions; MaxTopics](ipheader = ""): StateCircus[T, MaxSessions, MaxTopics] =
  result = StateCircus[T, MaxSessions, MaxTopics]()
  result.stash = newStashTable[int64, Session[T], MaxSessions]()
  result.NoSession = Session[T]()
  result.lock.initLock()
  result.bus = newSuber[Payload, MaxTopics](maxdelivery = 0)  
  result.server = new GuildenServer
  result.topicstamps = newStashTable[Topic, int64, MaxTopics]()
  result.ipheader = ipheader