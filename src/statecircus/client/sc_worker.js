// chrome //inspect/#workers
// firefox about:debugging#/runtime/this-firefox

importScripts("sc_shared.js")
importScripts("handlers.js")

const wsOPEN = 1
const channel = new BroadcastChannel('statecircus_channel')
const circus = createStateCircus(true)
initStateCircus(circus)

let initialized = false
let webSocket
let websocketurl
let postponedmessages = []
let topictimestamps = new Map()

function log(text, object) {
  console.log("---statecircus sharedworker log:")
  if (text) console.log(text)
  if (object) console.log({object})
  console.log("---")
}

function debug(text, object) {
  if (circus.state && !circus.state.debug) return
  console.trace()
  if (text) console.log("  ", text)
  if (object) console.log({object})
  console.log(" ")
}

function getTopics() {
  let result = []
  topictimestamps.forEach(function(_, key) {
    log("key", key)
    result.push(key)
  })
  return result 
}

function update(msg) {
  if (msg.now < circus.state.at) {
    debug("stale update msg < " + circus.state, msg)
    return false
  }

  if (circus.state.queryingsince > 0) {
    postponedmessages.push(msg)
    return false
  }

  let expiredtopics = []

  for (let msgtopicstamp of msg.tos) {
    const locallyat = topictimestamps.get(msgtopicstamp.to)
    if (locallyat && locallyat < msgtopicstamp.at) expiredtopics.push(msgtopicstamp.to)
  }
  if (expiredtopics.length > 0) {
    circus.syncState(expiredtopics)
    return false
  }
  circus.state.at = msg.now
  for (let msgtopicstamp of msg.tos) {
    topictimestamps.set(msgtopicstamp.to, msg.now)
  }
  if (msg.st) circus.handleStatemerge(msg.st)
  if (msg.a) circus.handleActions(msg.a)
  if (msg.st || msg.a) return true
}

function processMsg(msg) {
  debug("processing",msg)
  try {
    if (msg.logout) {
      logOut("logout from server")
      return false
    }
    return update(msg)
  } catch (err) {
    debug(err.message, msg)
    return false
  }
}

function processPendingmessages() {
  let statechange = false
  for (let msg of postponedmessages) {
    statechange = processMsg(msg) || statechange
    if (circus.state.sessionstate != circus.SessionStates.OPEN) return
  }
  postponedmessages = []
  return statechange
}

function logOut(reason) {
  debug("logout: " + reason)
  if (webSocket != null) webSocket.close(4000)
  initialized = false
  webSocket = null
  circus.defaultState()
  websocketurl = null
  queryingsince = 0
  postponedmessages = []
  circus.state.alertmessage = reason
  channel.postMessage(circus.state)
  circus.state.alertmessage = null
}

function connectUntilTimeout() {
  if (!circus.state.sessionkey) {
    logOut("no session")
    return
  }
  if (webSocket && webSocket.readyState == wsOPEN) {
    circus.state.sessionstate = circus.SessionStates.OPEN
    channel.postMessage(circus.state)
    return
  }
  if (circus.state.sessionstate == circus.SessionStates.CONNECTING) return
  let informpages = circus.state.sessionstate == circus.SessionStates.OPEN
  circus.state.sessionstate = circus.SessionStates.CONNECTING
  if (informpages) channel.postMessage(circus.state)
  connectWs()
  setTimeout( () => {
    if (!webSocket || webSocket.readyState != wsOPEN) circus.handleConnectfailure()
  }, 10000)
}

function connectWs() {
  debug("connectWs")
  if (!circus.state.sessionkey || !websocketurl) {
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
      circus.state.sessionstate = circus.SessionStates.OPEN
      circus.handleConnectsuccess()
    }
    webSocket.onclose = function(event) {
      debug("ws closed: " + event.code)
      if (event.code in [1005, 1006]) connectUntilTimeout()  
      else logOut()
    }
    webSocket.onmessage = function(event) {
      debug("ws message", event.data)
      if (circus.state.sessionstate == circus.SessionStates.SIMULATEDOUTAGE) {
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
      if (message.x == "l") {
        logOut("logout received")
        return
      }
      if (message.x == "o") {
        circus.handleServeroverload()
        channel.postMessage(circus.state)
        circus.state.alertmessage = null
        return
      }
      if (message.x == "i") {
        circus.state.sessionstate = circus.SessionStates.OPEN
        circus.handleConnectsuccess(message.state, message.topics)
        initialized = true
        circus.state.alertmessage = null
        return
      }
      if (message.x == "u") {
        let statechange = processMsg(message.d)
        if (circus.state.sessionstate == circus.SessionStates.LOGGEDOUT) return
        if (statechange) {
          circus.inspectReceivedState()
          channel.postMessage(circus.state)
          circus.state.alertmessage = null
          circus.state.once = {}
        }
        return
      }
      debug("unrecognized message type", message)
    }
  }
}

function finishQuery(msg) {
  circus.state.queryingsince = 0
  let statechange = false
  if (msg) {
    if (msg.x == "q") statechange = processMsg(msg.d)
    else {
      debug("unrecognized message type", msg)
      return
    }
  }
  if (circus.state.sessionstate == circus.SessionStates.OPEN) {
    statechange = processPendingmessages() || statechange
    if (statechange) channel.postMessage(circus.state)
    circus.state.alertmessage = null
  }
}

function sendTowebsocket(message) {
  if (circus.state.sessionstate == circus.SessionStates.LOGGEDOUT) return
  if (!webSocket || webSocket.readyState != wsOPEN) {
    circus.state.sessionstate = circus.SessionStates.CLOSED
    connectUntilTimeout()
  }
  try {
    message.k = circus.state.sessionkey
    message = JSON.stringify(message)
  } catch (ex) {
    debug("cannot send, syntax error: " + ex)
    return
  }
  webSocket.send(message)
}

onconnect = async function(e) {
  debug("new page connected to worker")
  let port = e.ports[0]
  let connectionconfirmed = false

  port.onmessage = function(e) {
    debug(null, e.data)
    if (!e.data) return

    if (e.data.type == "__pageconfirmedconnection") {
      connectionconfirmed = true
      if (e.data.msg) circus.state.pages.set(e.data.msg, null)
    }
    else if (e.data.type == "__focuspage") {
      channel.postMessage({"focuspage": e.data.msg})
    }
    else if (e.data.type == "__closepage") {
      circus.state.pages.delete(e.data.msg)
      channel.postMessage({"closepage": e.data.msg})
    }
    else if (e.data.type == "__acceptlogin") {
      try {
        circus.state.sessionkey = e.data.msg.sessionkey
        let wsproto = "wss://"
        if (location.protocol == "http:") wsproto = "ws://"
        let path = location.host + e.data.msg.websocketpath
        if (e.data.msg.websocketpath.startsWith(":")) path = location.hostname + e.data.msg.websocketpath
        websocketurl = wsproto + path + "/S" + circus.state.sessionkey
        connectUntilTimeout()
      } catch (ex) {
        console.log(ex)
        console.log(JSON.stringify(e))
      }
    }
    else if (e.data.type == "__statecircus_state") {
      circus.state = e.data.msg
      channel.postMessage(circus.state)
      circus.state.alertmessage = null
      circus.state.once = {}
    }
    else if (e.data.type == "__queryStarted") circus.state.queryingsince = Date.now()
    else if (e.data.type == "__queryFinished") finishQuery(e.data.msg)
    else if (e.data.type == "__logout") logOut(e.data.msg)
    else if (e.data.type == "__pageclosing") {
      if (circus.state) {
        circus.state.pages.delete(e.data.msg)
        if (circus.state.pages.size == 0) logOut("last page closed")
      }
      else logOut("nopage")
    }
    else if (e.data.type == "__simulatedoutage") {
      if (e.data.msg.simulatedoutage) {
        if (circus.state.sessionstate == circus.SessionStates.OPEN) circus.state.sessionstate = circus.SessionStates.SIMULATEDOUTAGE
      }
      else {
        if (!webSocket || webSocket.readyState != wsOPEN) circus.state.sessionstate = circus.SessionStates.CLOSED
        else circus.state.sessionstate = circus.SessionStates.OPEN
      }
      channel.postMessage(circus.state)
    }
    else sendTowebsocket({"e": e.data.type, "m": e.data.msg})
  }
  
  let time = 10
  while (!connectionconfirmed) {
    channel.postMessage({"workerconfirmedconnection": circus.state.pages})
    await new Promise(r => setTimeout(r, time))
    time += 10
    if (time > 10000) logOut("connection with page not confirmed")
  }
  channel.postMessage(circus.state)
}