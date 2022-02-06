# nim c -r -p:. --gc:arc --d:release --threads:on --d:threadsafe ./back/exampleapp.nim

import json, guildenstern/ctxbody, simplefileserver, simpledb
import statecircus

type SessionData* = object

const BroadCastTopic = 1.Topic

var circus* = newStateCircus[SessionData]()

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

proc handleHttp(ctx: HttpCtx) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    when defined(fulldebug):
      echo "--http--"
      echo ctx.getBody()
      echo "--------"
    if ctx.isUri("/login"): handleLogin(ctx)
    else: serveFile(ctx)

proc onUpgradeRequest(ctx: WsCtx): (bool , proc()) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    var session = circus.connectWebsocket(ctx)
    result[0] = session.sessionkey != NoSessionKey
    result[1] = proc() =
      var state = ""
      if circus.server.loglevel <= DEBUG: state = "{\"debug\": true}"
      circus.sub.subscribe(session.sessionkey, BroadCastTopic)
      ctx.sendWs(initMessage(state, [BroadCastTopic]))

proc syncState(client: SessionKey, replyid: int, expiredtopics: openArray[JsonNode]) =
  withLock(dblock):
    circus.send(client, [circus.sub.getOldTimestamp(BroadCastTopic)], replyOne(replyid, "syncstate", $(%*{"values": getValues()})))

proc handleWebsocket(ctx: WsCtx) {.gcsafe, raises: [].} =
  {.gcsafe.}:
    if ctx.isRequest("PING"): (circus.server.sendPong(ctx.socketdata.socket); return)
    let (session, event, msg, replyid) = circus.receiveMessage(ctx)
    if session.sessionkey == NoSessionKey: return

    if event == "syncstate": syncState(session.sessionkey, replyid, msg.getElems())

    if event == "insertvalue":
      var timestamp: TopicStamp
      let value =
        try: msg["value"].getStr()
        except:
          when defined(fulldebug): echo "could not parse value: ", ctx.getRequest()
          return
      withLock(dblock):
        insertValue(value)
        timestamp = circus.sub.getNewTimestamp(BroadCastTopic)
      circus.send([timestamp], replyActionstring("valueinserted", value))

proc close(ctx: Ctx, socket: SocketHandle, cause: SocketCloseCause, msg: string) = {.gcsafe.}:
  let session = circus.close(ctx, socket, cause)
  if session.sessionKey != NoSessionKey: circus.sub.unsubscribe(session.sessionKey, BroadCastTopic)

proc main(port: int) =
  circus.server.registerConnectionclosedhandler(close)
  circus.server.initBodyCtx(handleHttp, port)
  circus.server.initWsCtx(onUpgradeRequest, handleWebsocket, port + 1)
  when not defined(release): circus.server.serve(loglevel = TRACE)
  else: circus.server.serve()

echoDirs()
main(5050)