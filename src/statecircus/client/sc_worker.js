// chrome //inspect/#workers
// firefox about:debugging#/runtime/this-firefox

importScripts("sc_shared.js")

class State {
  sessionkey = null
  wsstate = WsState.LOGGEDOUT
  debug = false
  alertmessage = null
  at = 0
  tabs = new Map()
}

const WORKER = true
const wsOPEN = 1
const channel = new BroadcastChannel('statecircus_channel')

let initialized = false
let webSocket
let sc_state = new State()
let websocketurl
let queryingsince = 0
let postponedmessages = []
let topictimestamps = new Map()

function log(text, object) {
  console.log("---statecircus sharedworker log:")
  if (text) console.log(text)
  if (object) console.log(object)
  console.log("---")
}

function debug(text, object) {
  if (sc_state &&  !sc_state.debug) return
  console.trace()
  if (text) console.log("  ", text)
  if (object) console.log("  ", object)
  console.log(" ")
}

function update(msg) {
  if (msg.now < sc_state.at) {
    debug("stale update msg < " + sc_state, msg)
    return false
  }

  if (queryingsince > 0) {
    postponedmessages.push(msg)
    return false
  }

  for (let msgtopicstamp of msg.tos) {
    const locallyat = topictimestamps.get(msgtopicstamp.to)
    if (locallyat && locallyat < msgtopicstamp.at) {
      handleRefresh()
      return false
    }
  }
  sc_state.at = msg.now
  for (let msgtopicstamp of msg.tos) {
    topictimestamps.set(msgtopicstamp.to, msg.now)
  }
  if (msg.st) handleStatemerge(msg.st)
  if (msg.a) handleActions(msg.a)
  if (msg.st || msg.a) return true
}

function refresh(msg) {
  let statechange = false
  for (let topic of msg.to) {
    const locallyat = topictimestamps.get(topic)
    if (!locallyat || locallyat < msg.then) {
      topictimestamps.set(topic, msg.then)
      if (sc_state.at < msg.then) sc_state.at = msg.then
      statechange = true
    }
  }
  if (statechange) {
    if (msg.st) handleStatemerge(msg.st)
    if (msg.a) handleActions(msg.a)
    if (msg.st || msg.a) return true
  }
  return false
}

function requery(topics) {
  handleQuery(topics)
  return false
}

function query(msg) {
  for (let msgtopicstamp of msg.tos) {
    topictimestamps.set(msgtopicstamp.to, msgtopicstamp.at)
    if (msgtopicstamp.at > sc_state.at) sc_state.at = msgtopicstamp.at
  }
  if (msg.st) handleStatemerge(msg.st)
  if (msg.a) handleActions(msg.a)
  return (msg.st || msg.a)
}

function processMsg(msg) {
  debug("processing",msg)
  try {
    if (msg.logout) {
      logOut("logout from server")
      return false
    }
    if (msg.now) return update(msg)
    if (msg.then) return refresh(msg)
    if (msg.expiredtopics) return requery(msg.expiredtopics)
    return query(msg)
  } catch (err) {
    debug(err.message, msg)
    return false
  }
}

function processPendingmessages() {
  let statechange = false
  for (let msg of postponedmessages) {
    statechange = processMsg(msg) || statechange
    if (sc_state.wsstate != WsState.OPEN) return
  }
  postponedmessages = []
  return statechange
}

function logOut(reason) {
  debug("logout: " + reason)
  if (webSocket != null) webSocket.close(4000)
  initialized = false
  webSocket = null
  sc_state = new State()
  websocketurl = null
  queryingsince = 0
  postponedmessages = []
  sc_state.alertmessage = reason
  channel.postMessage(sc_state)
  sc_state.alertmessage = null
}

function connectUntilTimeout() {
  if (!sc_state.sessionkey) {
    logOut("no session")
    return
  }
  if (webSocket && webSocket.readyState == wsOPEN) {
    sc_state.wsstate = WsState.OPEN
    channel.postMessage(sc_state)
    return
  }
  if (sc_state.wsstate == WsState.CONNECTING) return
  let informtabs = sc_state.wsstate == WsState.OPEN
  sc_state.wsstate = WsState.CONNECTING
  if (informtabs) channel.postMessage(sc_state)
  connectWs()
  setTimeout( () => {
    if (!webSocket || webSocket.readyState != wsOPEN) handleConnectfailure()
  }, 10000)
}

function connectWs() {
  debug("connectWs")
  if (!sc_state.sessionkey || !websocketurl) {
    logOut("connectWs called without session or url")
    return
  }
  try {
    debug("ws connecting to ", websocketurl)
    webSocket = new WebSocket(websocketurl)
  }
  catch(ex) {
    logOut(ex)
    return
  }
  webSocket.onopen = function() {
    if (initialized) {
      sc_state.wsstate = WsState.OPEN
      handleConnectsuccess()
    }
    webSocket.onclose = function(event) {
      debug("ws closed: " + event.code)
      if (event.code in [1005, 1006]) connectUntilTimeout()  
      else logOut()
    }
    webSocket.onmessage = function(event) {
      debug("ws message", event.data)
      if (sc_state.wsstate == WsState.SIMULATEDOUTAGE) {
        log("ws message ignored because network outage is being simulated")
        return
      }
      let message
      try {
        message = JSON.parse(event.data)
      } catch (err) {
        debug("ws syntax error", err.message)
        debug("msg", event.data)
        logOut("ws syntax error")
        return
      }
      if (message.x == "o") {
        handleServeroverload()
        channel.postMessage(sc_state)
        sc_state.alertmessage = null
        return
      }
      if (message.x == "i") {
        sc_state.wsstate = WsState.OPEN
        handleConnectsuccess(message.st)
        initialized = true
        channel.postMessage(sc_state)
        sc_state.alertmessage = null
        return
      }
      if (message.x == "u") {
        let statechange = processMsg(message.d)
        if (sc_state.wsstate == WsState.LOGGEDOUT) return
        if (statechange) {
          channel.postMessage(sc_state)
          sc_state.alertmessage = null
        }
        return
      }
      debug("unrecognized message type", message)
    }
  }
}

function finishQuery(msg) {
  queryingsince = 0
  let statechange = false
  if (msg) {
    if (msg.x == "q") statechange = processMsg(msg.d)
    else if (msg.x == "r") {
      for (let m of msg.d) {
        statechange = processMsg(m) || statechange
        if (sc_state.wsstate == WsState.LOGGEDOUT) return
      }
    } else {
      debug("unrecognized message type", msg)
      return
    }
  }
  if (sc_state.wsstate == WsState.OPEN) {
    statechange = processPendingmessages || statechange
    if (statechange) channel.postMessage(sc_state)
    sc_state.alertmessage = null
  }
}

function sendTowebsocket(message) {
  if (sc_state.wsstate == WsState.LOGGEDOUT) return
  if (!webSocket || webSocket.readyState != wsOPEN) {
    sc_state.wsstate = WsState.CLOSED
    connectUntilTimeout()
  }
  try {
    message.k = sc_state.sessionkey
    message = JSON.stringify(message)
  } catch (ex) {
    debug("cannot send, syntax error: " + ex)
    return
  }
  webSocket.send(message)
}

onconnect = async function(e) {
  debug("new tab connected to worker")
  let port = e.ports[0]
  let connectionconfirmed = false

  port.onmessage = function(e) {
    debug(null, e.data)
    if (!e.data) return

    if (e.data.type == "__tabconfirmedconnection") {
      connectionconfirmed = true
      if (e.data.msg) sc_state.tabs.set(e.data.msg, null)
    }
    else if (e.data.type == "__focustab") {
      channel.postMessage({"focustab": e.data.msg})
    }
    else if (e.data.type == "__closetab") {
      sc_state.tabs.delete(e.data.msg)
      channel.postMessage({"closetab": e.data.msg})
    }
    else if (e.data.type == "__acceptlogin") {
      try {
        sc_state.sessionkey = e.data.msg.sessionkey
        let wsproto = "wss://"
        if (location.protocol == "http:") wsproto = "ws://"
        let path = location.host + e.data.msg.websocketpath
        if (e.data.msg.websocketpath.startsWith(":")) path = location.hostname + e.data.msg.websocketpath
        websocketurl = wsproto + path + "/S" + sc_state.sessionkey
        connectUntilTimeout()
      } catch (ex) {
        console.log(ex)
        console.log(JSON.stringify(e))
      }
    }
    else if (e.data.type == "__statecircus_state") {
      sc_state = e.data.msg
      channel.postMessage(sc_state)
      sc_state.alertmessage = null
    }
    else if (e.data.type == "__queryStarted") queryingsince = Date.now()
    else if (e.data.type == "__queryFinished") finishQuery(e.data.msg)
    else if (e.data.type == "__logout") logOut(e.data.msg)
    else if (e.data.type == "__tabclosing") {
      sc_state.tabs.delete(e.data.msg)
      if (sc_state.tabs.size == 0) logOut("last tab closed")
    }
    else if (e.data.type == "__simulatedoutage") {
      if (e.data.msg.simulatedoutage) {
        if (sc_state.wsstate == WsState.OPEN) sc_state.wsstate = WsState.SIMULATEDOUTAGE
      }
      else {
        if (!webSocket || webSocket.readyState != wsOPEN) sc_state.wsstate = WsState.CLOSED
        else sc_state.wsstate = WsState.OPEN
      }
      channel.postMessage(sc_state)
    }
    else sendTowebsocket({"e": e.data.type, "m": e.data.msg})
  }
  
  let time = 10
  while (!connectionconfirmed) {
    channel.postMessage({"workerconfirmedconnection": sc_state.tabs})
    await new Promise(r => setTimeout(r, time))
    time += 10
    if (time > 10000) logOut("connection with tab not confirmed")
  }
  channel.postMessage(sc_state)
}