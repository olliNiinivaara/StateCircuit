import random, times, locks, json, std/monotimes
from math import `^`
from strmisc import rpartition
from parseutils import parseBiggestInt
from os import sleep
from httpcore import HttpCode, Http400, Http403, Http404, Http500, Http503

import pkg/[guildenstern/ctxws, stashtable]
import pkg/statecircus/[replies, subber]

export ctxws, subber, replies, sleep, Http400, Http403, Http404, Http500, Http503

#[
  x:
  i: initialization (at first websocket upgrade)
  u: update
  l: logout
  o: server overload (should never happen)
]#
const
  MaxSessions* {.intdefine.} = 1000
  MaxTopics* {.intdefine.} = 1000
  PoolSizes* {.intdefine.} = 200

type
  SessionKey* = Subscriber

  Session*[T] = object
    sessionkey*: SessionKey
    userid*: string
    ip*: string
    websocket*: SocketHandle
    starttime*: DateTime
    data*: T
    
  StateCircus*[T] = object
    stash*: StashTable[int64, Session[T], MaxSessions]
    NoSession*: Session[T]
    ipheader*: string
    lock: Lock
    server*: GuildenServer
    sub*: Subber

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

proc startSession*[T](circus: var StateCircus[T], ctx: HttpCtx, userid: string, data: T): SessionKey {.raises: [].} =
  withLock(circus.lock):
    if circus.stash.len == MaxSessions: return NoSessionKey
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

proc replyLogin*(ctx: HttpCtx, websocketpath: string, sessionkey: SessionKey) =
  if sessionkey == NoSessionKey: 
    ctx.reply(Http403)
    return
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
    except:
      ctx.reply(Http400)
      return
  let session = circus.getSession(result)
  if (unlikely)session.sessionkey == NoSessionKey:
    ctx.reply(Http400)
    return
  if unlikely(not circus.validateIp(ctx, session)):
    result = NoSessionKey
    ctx.reply(Http400)

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

# TODO: use'em websockets?
proc tryToLock*[T](circus: StateCircus[T], ctx: HttpCtx) =
  let success = "true"
  let body = 
    try: parseJson(ctx.getBody())
    except:
      ctx.reply(Http400)
      return
  let sessionkey = circus.getSessionkey(ctx, body)
  if sessionkey == NoSessionKey: return
  # TODO: lock may require that userid is subscribed to a topic
  # TODO: if now - lockedsince > maxlockduration, release lock
  # TODO: if lock owner == userid, only refresh lockedsince
  ctx.reply(success)

proc releaseLock*[T](circus: StateCircus[T], sessionkey: SessionKey, lock: string) =
  # TODO ...
  discard

proc receiveMessage*[T](circus: StateCircus[T], ctx: WsCtx): (Session[T] , string, JsonNode, int) {.raises: [].} =
  {.gcsafe.}:
    try:
      result[0].sessionKey = NoSessionKey
      if circus.server.loglevel == TRACE: echo ctx.getRequest()
      let msg = parseJson(ctx.getRequest())
      let sessionKey = msg["k"].getInt().SessionKey
      result[0] = circus.getSession(sessionKey, ctx)
      if result[0].sessionKey == NoSessionKey: return
      result[1] = msg["e"].getStr()
      result[2] = msg["m"]
      result[3] = msg["rr"].getInt()
    except: circus.server.log(ERROR, "receiveMessage failed")

proc logOut*[T](circus: StateCircus[T], sessionKey: SessionKey, closesocket = true): Session[T] =
  circus.sub.removeSubscriber(sessionKey.Subscriber)   # TODO: if last subscriber for a topic, compact parasuber
  result = circus.getSession(sessionKey)
  if result.sessionKey == NoSessionKey: return
  circus.endSession(result.sessionKey)
  # TODO: release all locks held by this userid
  if closesocket and result.websocket != INVALID_SOCKET:
    circus.server.closeOtherSocket(result.websocket, CloseCalled)

proc close*[T](circus: var StateCircus[T], ctx: Ctx, socket: SocketHandle, cause: SocketCloseCause): Session[T] =
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
  result.sub = newSubber()  
  result.server = new GuildenServer
  result.ipheader = ipheader

include pkg/statecircus/sender