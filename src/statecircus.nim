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
  ClientKey* = Subscriber

  Session*[T] = object
    clientkey*: ClientKey
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
  NoClientKey* = 0.ClientKey
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

proc startSession*[T](circus: var StateCircus[T], ctx: HttpCtx, userid: string, data: T): ClientKey {.raises: [].} =
  withLock(circus.lock):
    if circus.stash.len == MaxSessions: return NoClientKey
    let clientkey = ClientKey(1 + 2^20 * randomer.rand(2^20).int64 + randomer.rand(int32.high).int64)
    let userid =
      if userid == "": $clientkey
      else: userid
    var oldsessionkey = NoClientKey
    var oldsocket = INVALID_SOCKET
    for (key, index) in circus.stash.keys():
      circus.stash.withFound(key, index):
        if ClientKey(key) == clientkey: return NoClientKey # key already in use, improbable
        if value.userid == userid:
          oldsessionkey = ClientKey(key)
          oldsocket = value.websocket
    if not (oldsessionkey == NoClientKey):
      circus.stash.del(int64(oldsessionkey))
      ctx.gs[].sendWs(oldsocket, LogoutMessage)
      ctx.gs[].closeOtherSocket(oldsocket, SecurityThreatened, "user started new session from different socket")

    var headervalue: array[1, string]
    if circus.ipheader != "": ctx.parseHeaders([circus.ipheader], headervalue)
    let session = Session[T](clientkey: clientkey, userid: userid, ip: headervalue[0], websocket: InvalidSocket, starttime: now(), data: data)
    circus.stash.insert(int64(clientkey), session)
    return clientkey

proc registerWebSocket*[T](circus: StateCircus[T], clientkey: ClientKey, websocket: SocketHandle, usetimeout = true): bool =
  circus.stash.withValue(int64(clientkey)):
    if value.websocket != INVALID_SOCKET: return false
    if usetimeout and websocketregistrationtimewindow <= now() - value.starttime: return false
    value.websocket = websocket
    return true
  do:
    return false

proc unregisterWebSocket*[T](circus: StateCircus[T], clientkey: ClientKey) =
  circus.stash.withValue(int64(clientkey)): value.websocket = INVALID_SOCKET

proc findSessionKey*[T](circus: StateCircus[T], websocket: SocketHandle): ClientKey =
  for (k , index) in circus.stash.keys:
    circus.stash.withFound(k, index):
      if value.websocket == websocket: return value.clientkey
  return NoClientKey

proc endSession*[T](circus: StateCircus[T], clientkey: ClientKey) =
  circus.stash.del(int64(clientkey))

proc getSession*[T](circus: StateCircus[T], clientkey: ClientKey | Subscriber | int): Session[T] {.inline.} =
  circus.stash.withValue(int64(clientkey)):
    return value[]
  do:
    return circus.NoSession

proc getSession*[T](circus: StateCircus[T], clientkey: ClientKey, ctx: Ctx): Session[T] =
  let session = circus.getSession(clientkey)
  if session.clientkey == NoClientKey or session.websocket != ctx.socketdata.socket:
    ctx.closeSocket(SecurityThreatened)
  return session

proc getSessionPtr*[T](circus: StateCircus[T], clientkey: ClientKey | Subscriber | int): ptr Session[T] {.inline.} =
  circus.stash.withValue(int64(clientkey)):
    return value
  do:
    return nil

proc replyLogin*(ctx: HttpCtx, websocketpath: string, clientkey: ClientKey) =
  if clientkey == NoClientKey: 
    ctx.reply(Http403)
    return
  else:
    var s = $(%*{"websocketpath": websocketpath, "clientkey": clientkey.int64})
    ctx.reply(Http200, s)

proc validateIp[T](circus: StateCircus[T], ctx: HttpCtx, session: Session): bool =
  var headervalue: array[1, string]
  if circus.ipheader != "": ctx.parseHeaders([circus.ipheader], headervalue)
  return headervalue[0] == session.ip

proc getSessionkey*[T](circus: StateCircus[T], ctx: HttpCtx, bodyjson: JsonNode): ClientKey =
  result =
    try: bodyjson["k"].getInt().ClientKey
    except:
      ctx.reply(Http400)
      return
  let session = circus.getSession(result)
  if (unlikely)session.clientkey == NoClientKey:
    ctx.reply(Http400)
    return
  if unlikely(not circus.validateIp(ctx, session)):
    result = NoClientKey
    ctx.reply(Http400)

proc connectWebsocket*[T](circus: StateCircus[T], ctx: WsCtx, usetimetimeout = true): Session[T] {.raises: [].} =
  var clientkey = NoClientKey
  try:
    var i: BiggestInt
    discard parseBiggestInt(ctx.getUri().rpartition("/S")[2], i)
    clientkey = i.ClientKey
  except:
    circus.server.log(WARN, "could not parse session key from: " & ctx.getUri())
    return
  {.gcsafe.}:
    if circus.registerWebSocket(clientkey, ctx.socketdata.socket, usetimetimeout): return circus.getSession(clientkey)

# TODO: use'em websockets?
proc tryToLock*[T](circus: StateCircus[T], ctx: HttpCtx) =
  let success = "true"
  let body = 
    try: parseJson(ctx.getBody())
    except:
      ctx.reply(Http400)
      return
  let clientkey = circus.getSessionkey(ctx, body)
  if clientkey == NoClientKey: return
  # TODO: lock may require that userid is subscribed to a topic
  # TODO: if now - lockedsince > maxlockduration, release lock
  # TODO: if lock owner == userid, only refresh lockedsince
  ctx.reply(success)

proc releaseLock*[T](circus: StateCircus[T], clientkey: ClientKey, lock: string) =
  # TODO ...
  discard

proc receiveMessage*[T](circus: StateCircus[T], ctx: WsCtx): (Session[T] , string, JsonNode, int) {.raises: [].} =
  {.gcsafe.}:
    try:
      result[0].clientkey = NoClientKey
      if circus.server.loglevel == TRACE: echo ctx.getRequest()
      let msg = parseJson(ctx.getRequest())
      let clientkey = msg["k"].getInt().ClientKey
      result[0] = circus.getSession(clientkey, ctx)
      if result[0].clientkey == NoClientKey: return
      result[1] = msg["e"].getStr()
      result[2] = msg["m"]
      result[3] = msg["rr"].getInt()
    except: circus.server.log(ERROR, "receiveMessage failed")

proc logOut*[T](circus: StateCircus[T], clientkey: ClientKey, closesocket = true): Session[T] =
  circus.sub.removeSubscriber(clientkey.Subscriber)   # TODO: if last subscriber for a topic, compact parasuber
  result = circus.getSession(clientkey)
  if result.clientkey == NoClientKey: return
  circus.endSession(result.clientkey)
  # TODO: release all locks held by this userid
  if closesocket and result.websocket != INVALID_SOCKET:
    circus.server.closeOtherSocket(result.websocket, CloseCalled)

proc close*[T](circus: var StateCircus[T], socket: SocketHandle, cause: SocketCloseCause): Session[T] =
  {.gcsafe.}:
    let clientkey = circus.findSessionKey(socket)
    if clientkey == NoClientKey: circus.NoSession
    else:
      circus.unregisterWebSocket(clientkey)
      if cause == ConnectionLost: circus.NoSession
      else: circus.logOut(clientkey, false)

proc closeAll*[T](circus: var StateCircus[T]) =
  var sockets = newSeq[SocketHandle]()
  for (key, index) in circus.stash.keys():
     circus.stash.withFound(key, index):
      if value.websocket != INVALID_SOCKET: sockets.add(value.websocket)
  for socket in sockets: circus.server.closeOtherSocket(socket, CloseCalled)
  circus.stash.clear()
  circus.sub.clear()

proc newStateCircus*[T](ipheader = ""): StateCircus[T] =
  result = StateCircus[T]()
  result.stash = newStashTable[int64, Session[T], MaxSessions]()
  result.NoSession = Session[T]()
  result.lock.initLock()
  result.sub = newSubber()  
  result.server = new GuildenServer
  result.ipheader = ipheader

include pkg/statecircus/sender