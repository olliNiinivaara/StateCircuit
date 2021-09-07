# nim c -r -p:. --gc:arc --d:release --threads:on --d:threadsafe exampleapp.nim

import json, statecircus, guildenstern/ctxbody, simplefileserver, simpledb

type SessionData* = object

const
  MaxTopics = 1
  MaxSessions = 1000
  BroadcastTopic = 1.Topic

var circus* = newStateCircus[SessionData, MaxSessions, MaxTopics]()

proc validateLogin(ctx: HttpCtx): string =
  var userid, password: string
  try:
    let jsonnode = parseJson(ctx.getBody())["q"]
    userid = jsonnode["userid"].getStr
    password = jsonnode["password"].getStr
  except: userid = ""
  if userid == "" or password == "" #[ or invalid credentials... ]#: return ""
  return userid

proc handleLogin(ctx: HttpCtx) {.raises: [].} =
  let userid = validateLogin(ctx)
  if userid == "":
    sleep(FailurePause)
    ctx.reply(Http403)
    return
  let sessionkey = circus.startSession(ctx, userid, SessionData())
  ctx.replyLogin(":5051/ws", sessionkey)

proc queryValues(parameters: JsonNode): string {.gcsafe, raises: [].} =
  return $(%*{"values": getValues()})

proc handleHttp(ctx: HttpCtx) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    when defined(fulldebug):
      echo "--http--"
      echo ctx.getBody()
      echo "--------"
    if ctx.isUri("/login"): handleLogin(ctx)
    elif ctx.isUri("/refresh"): circus.replyToRefresh(ctx)
    elif ctx.startsUri("/q/"):
      let query = circus.getQuery(ctx)
      if query.path == "values": circus.replyToQuery(ctx, query, queryValues)
      else: ctx.reply(Http400)
    else: serveFile(ctx)

proc grantSubscriptions[T](session: Session[T], topics: IntSet): bool {.gcsafe, raises: [].} =
  {.gcsafe.}: circus.subscribe(session.sessionkey, BroadcastTopic)
  true

proc handleUpgradeRequest(ctx: WsCtx): (bool , proc()) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    var session = circus.connectWebsocket(ctx)
    result[0] = session.sessionkey != NoSessionKey
    if result[0]:
      result[1] = (proc() = ctx.sendWs(session.initMessage(%*{"firsttopic": BroadcastTopic.int})))

proc handleWebsocket(ctx: WsCtx) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    handlePingAndOverload()
    let (session , event , msg) = circus.receiveMessage(ctx)
    if session.sessionkey == NoSessionKey: return

    if event == "insertvalue":
      let value =
        try: msg["value"].getStr()
        except:
          when defined(fulldebug): echo "could not parse value: ", ctx.getRequest()
          return
      withLock(dblock):
        insertValue(value)
        circus.pushActions([BroadcastTopic], %*[%*{"action": "valueinserted", "value": value}])

proc deliver(envelopes: openArray[ptr SuberMessage[Payload]]) {.gcsafe, raises: [].} = {.gcsafe.}: circus.onDelivery(envelopes)
circus.bus.setDelivercallback(deliver)

proc pull(subscriber: Subscriber, expiredtopics: openArray[Topic], messages: openArray[ptr SuberMessage[Payload]]) {.gcsafe, raises: [].} =
  {.gcsafe.}: circus.onPull(subscriber, expiredtopics, messages)
circus.bus.setPullcallback(pull)

proc close(ctx: Ctx, socket: SocketHandle, cause: SocketCloseCause, msg: string) = {.gcsafe.}: discard circus.onClose(ctx, socket, cause)
circus.server.registerConnectionclosedhandler(close)

echo "Exampleapp running at localhost:5050"

circus.grantSubscriptions = grantSubscriptions[SessionData]

circus.server.initBodyCtx(handleHttp, 5050)
circus.server.initWsCtx(handleUpgradeRequest, handleWebsocket, 5051)
when defined(threadsafe): circus.server.serve()
else: circus.server.serve(1)