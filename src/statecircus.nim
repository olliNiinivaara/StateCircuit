import random, times, locks, json, std/monotimes
from math import `^`
from strmisc import rpartition
from parseutils import parseBiggestInt
from os import sleep
from httpcore import HttpCode, Http400, Http403, Http404, Http409, Http500, Http503

import pkg/[guildenstern/websocketserver, stashtable]
import pkg/statecircus/[replies, subber]

export websocketserver, subber, replies, sleep, Http400, Http403, Http404, Http409, Http500, Http503

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

  Connection* = object
    clientkey*: ClientKey
    ip*: string
    websocket*: SocketHandle
    starttime*: DateTime
    
  StateCircus* = object
    stash*: StashTable[int64, Connection, MaxSessions]
    ipheader*: string
    lock: Lock
    htmlserver*: GuildenServer
    server*: GuildenServer
    sub*: Subber

const
  NoClientKey* = 0.ClientKey
  RegistrationTimeWindow* {.intdefine.} = 3
  FailurePause* {.intdefine.} = 4000

let
  NoConnection* = Connection()
  NoTimestamp* = toMonoTime(0)
  NullNode* = newJNull()
  LogoutMessage* = """{"x":"l"}"""
  OverloadMessage* = """{"x":"o"}"""

var
  websocketregistrationtimewindow* = initDuration(seconds = RegistrationTimeWindow)
  # TODO: use new OS random source
  randomer = initRand(getMonoTime().ticks())

proc initConnection*(circus: var StateCircus): ClientKey {.raises: [].} =
  withLock(circus.lock):
    if circus.stash.len == MaxSessions: return NoClientKey
    let clientkey = ClientKey(1 + 2^20 * randomer.rand(2^20).int64 + randomer.rand(int32.high).int64)
    var oldsessionkey = NoClientKey
    var oldsocket = INVALID_SOCKET
    for (key, index) in circus.stash.keys():
      circus.stash.withFound(key, index):
        if ClientKey(key) == clientkey: return NoClientKey # key already in use, improbable
        if value.clientkey == clientkey:
          oldsessionkey = ClientKey(key)
          oldsocket = value.websocket
    if not (oldsessionkey == NoClientKey):
      circus.stash.del(int64(oldsessionkey))
      wsserver.send(oldsocket, LogoutMessage)
      wsserver.closeOtherSocket(oldsocket, SecurityThreatened, "user started new session from different socket")

    var headervalue: array[1, string]
    if circus.ipheader != "": parseHeaders([circus.ipheader], headervalue)
    let session = Connection(clientkey: clientkey, ip: headervalue[0], websocket: InvalidSocket, starttime: now())
    circus.stash.insert(int64(clientkey), session)
    return clientkey

proc registerWebSocket*(circus: StateCircus, clientkey: ClientKey, websocket: SocketHandle, usetimeout = true): bool =
  circus.stash.withValue(int64(clientkey)):
    if value.websocket != INVALID_SOCKET: return false
    if usetimeout and websocketregistrationtimewindow <= now() - value.starttime: return false
    value.websocket = websocket
    return true
  do:
    return false

proc unregisterWebSocket*(circus: StateCircus, clientkey: ClientKey) =
  circus.stash.withValue(int64(clientkey)): value.websocket = INVALID_SOCKET

proc findClientKey*(circus: StateCircus, websocket: SocketHandle): ClientKey =
  for (k , index) in circus.stash.keys:
    circus.stash.withFound(k, index):
      if value.websocket == websocket: return value.clientkey
  return NoClientKey

proc removeConnection*(circus: StateCircus, clientkey: ClientKey) =
  circus.stash.del(int64(clientkey))

proc getConnection*(circus: StateCircus, clientkey: ClientKey | Subscriber | int): Connection {.inline.} =
  circus.stash.withValue(int64(clientkey)):
    return value[]
  do:
    return NoConnection

proc getSecureConnection*(circus: StateCircus, clientkey: ClientKey): Connection =
  let session = circus.getConnection(clientkey)
  if session.clientkey == NoClientKey or session.websocket != http.socketdata.socket:
    server.closeSocket(http.socketdata, SecurityThreatened, "")
  return session

proc getConnectionPtr*(circus: StateCircus, clientkey: ClientKey | Subscriber | int): ptr Connection {.inline.} =
  circus.stash.withValue(int64(clientkey)):
    return value
  do:
    return nil

proc replyLogin*(websocketpath: string, clientkey: ClientKey) =
  if clientkey == NoClientKey: 
    reply(Http403)
    return
  else:
    var s = $(%*{"websocketpath": websocketpath, "clientkey": clientkey.int64})
    reply(Http200, s)

proc validateIp(circus: StateCircus, session: Connection): bool =
  var headervalue: array[1, string]
  if circus.ipheader != "": parseHeaders([circus.ipheader], headervalue)
  return headervalue[0] == session.ip

proc getClientkey*(circus: StateCircus, bodyjson: JsonNode): ClientKey =
  result =
    try: bodyjson["k"].getInt().ClientKey
    except:
      reply(Http400)
      return
  let session = circus.getConnection(result)
  if (unlikely)session.clientkey == NoClientKey:
    reply(Http400)
    return
  if unlikely(not circus.validateIp(session)):
    result = NoClientKey
    reply(Http400)

proc connectWebsocket*(circus: StateCircus, usetimetimeout = true): Connection {.raises: [].} =
  var clientkey = NoClientKey
  try:
    var i: BiggestInt
    discard parseBiggestInt(getUri().rpartition("/S")[2], i)
    clientkey = i.ClientKey
  except:
    circus.server.log(WARN, "could not parse session key from: " & getUri())
    return
  {.gcsafe.}:
    if circus.registerWebSocket(clientkey, ws.socketdata.socket, usetimetimeout):
      return circus.getConnection(clientkey)

# TODO: use'em websockets?
proc tryToLock*(circus: StateCircus) =
  let success = "true"
  let body = 
    try: parseJson(getBody())
    except:
      reply(Http400)
      return
  let clientkey = circus.getClientkey(body)
  if clientkey == NoClientKey: return
  # TODO: lock may require that userid is subscribed to a topic
  # TODO: if now - lockedsince > maxlockduration, release lock
  # TODO: if lock owner == userid, only refresh lockedsince
  reply(success)

proc releaseLock*(circus: StateCircus, clientkey: ClientKey, lock: string) =
  # TODO ...
  discard

proc receiveMessage*(circus: StateCircus): (Connection , string, JsonNode, int) {.raises: [].} =
  {.gcsafe.}:
    try:
      result[0].clientkey = NoClientKey
      if circus.server.loglevel == TRACE: echo getRequest()
      let msg = parseJson(getRequest())
      let clientkey = msg["k"].getInt().ClientKey
      result[0] = circus.getConnection(clientkey)
      if result[0].clientkey == NoClientKey: return
      result[1] = msg["e"].getStr()
      result[2] = msg["m"]
      result[3] = msg["rr"].getInt()
    except: circus.server.log(ERROR, "receiveMessage failed")

proc logOut*(circus: StateCircus, clientkey: ClientKey, socketneedsclosing = true): Connection =
  circus.sub.removeSubscriber(clientkey.Subscriber)   # TODO: if last subscriber for a topic, compact parasuber
  result = circus.getConnection(clientkey)
  if result.clientkey == NoClientKey: return
  circus.removeConnection(result.clientkey)
  # TODO: release all locks held by this userid
  if socketneedsclosing and result.websocket != INVALID_SOCKET:
    circus.server.closeOtherSocket(result.websocket)

proc close*(circus: var StateCircus, socket: SocketHandle, cause: SocketCloseCause, logout = true): Connection =
  {.gcsafe.}:
    let clientkey = circus.findClientKey(socket)
    if clientkey == NoClientKey: return NoConnection  
    circus.unregisterWebSocket(clientkey)
    if cause == ConnectionLost or not logout: return NoConnection
    circus.logOut(clientkey, false)

proc closeAll*(circus: var StateCircus) =
  var sockets = newSeq[SocketHandle]()
  for (key, index) in circus.stash.keys():
     circus.stash.withFound(key, index):
      if value.websocket != INVALID_SOCKET: sockets.add(value.websocket)
  for socket in sockets: circus.server.closeOtherSocket(socket)
  circus.stash.clear()
  circus.sub.clear()

proc newStateCircus*(ipheader = ""): StateCircus =
  result = StateCircus()
  result.stash = newStashTable[int64, Connection, MaxSessions]()
  result.lock.initLock()
  result.sub = newSubber()  
  result.server = new GuildenServer
  result.ipheader = ipheader

include pkg/statecircus/sender