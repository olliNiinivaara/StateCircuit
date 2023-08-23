// chrome //inspect/#workers
// firefox about:debugging#/runtime/this-firefox

importScripts("./sc_shared.js")
importScripts("./handlers.js")

const wsOPEN = 1
const channel = new BroadcastChannel('statecircus_channel')
const circus = createStateCircus(true)
initStateCircus(circus)

let initialized = false
let webSocket
let websocketurl
let topictimestamps = new Map()
let expiredtopics = []

function triggerStateChange() {
  channel.postMessage(circus.state)
  circus.state.once = {}
  circus.state.alertmessage = null
}

function log(text, object) {
  console.log("---statecircus log:")
  if (text) console.log(text)
  if (object) console.log({object})
  console.log("---")
}

function debug(text, object) {
  if (circus.state && circus.state.sessionstate == circus.SessionStates.OPEN && !circus.state.debug) return
  console.log("---statecircus debug:")
  if (text) console.log(text)
  if (object) console.log({object})
  console.log("---")
}

function getTopics() {
  let result = []
  topictimestamps.forEach(function(_, key) {
    log("key", key)
    result.push(key)
  })
  return result 
}

function syncState(topics) {
  sendTowebsocket({"e": "syncstate", "m": topics, "rr": true})
}

function update(msg) {
  if (msg.tos) {
    for (let msgtopicstamp of msg.tos) {
      const locallyat = topictimestamps.get(msgtopicstamp.to)
      if (locallyat && locallyat < msgtopicstamp.old) {
        expiredtopics.push(msgtopicstamp.to)
        topictimestamps.delete(msgtopicstamp.to)
      }
    }
    if (expiredtopics.length > 0) {
      sendTowebsocket({"e": "syncstate", "m": expiredtopics, "rr": true})
      return false
    }
    for (let msgtopicstamp of msg.tos) {
      topictimestamps.set(msgtopicstamp.to, msgtopicstamp.now)
    }
  }
  if (msg.st) circus.handleStatemerge(msg.st)
  if (msg.a) circus.handleAction(msg.a.action, msg.a.value)
  if (msg.one) circus.handleOne(msg.one.subject, msg.one.value)
  if (msg.reply) {
    if (circus.state.replyrequests.has(msg.reply.replyid)) {
      circus.state.replyrequests.delete(msg.reply.replyid)
      if (msg.reply.subject == "syncstate") {
        for (let topic of expiredtopics) {
          topictimestamps.delete(topic)
        }
        expiredtopics = []
        circus.handleStatemerge(msg.reply.value)
      }
    }
    else circus.handleReply(msg.reply.subject, msg.reply.value)
  }
  if (msg.st || msg.a || msg.one || msg.reply) return true
}

function logOut(reason) {
  debug("logout: " + reason)
  if (webSocket != null) webSocket.close(4000)
  initialized = false
  webSocket = null
  circus.defaultState()
  websocketurl = null
  circus.state.alertmessage = reason
  triggerStateChange()
}

function connectUntilTimeout() {
  if (!circus.state.clientkey) {
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
  if (!circus.state.clientkey || !websocketurl) {
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
      // circus.handleConnectsuccess() only after init message...
    }
    webSocket.onclose = function(event) {
      debug("ws closed: " + event.code)
      if (event.code in [1005, 1006]) connectUntilTimeout()  
      else logOut()
    }
    webSocket.onmessage = function(event) {
      if (circus.state.sessionstate == circus.SessionStates.SIMULATEDOUTAGE) {
        log("ws message ignored because network outage is being simulated")
        return
      }
      let message
      try {
        message = JSON.parse(event.data)
      } catch (err) {
        debug("ws syntax error", err.message)
        debug(event.data)
        logOut("ws syntax error")
        return
      }
      debug("ws message", message)
      if (message.x == "l") {
        logOut("logout received")
        return
      }
      if (message.x == "o") {
        circus.handleServeroverload()
        triggerStateChange()
        return
      }
      if (message.x == "i") {
        circus.state.sessionstate = circus.SessionStates.OPEN
        circus.handleConnectsuccess(message.state, message.topics) // topics ingored...
        initialized = true
        // channel.postMessage(circus.state)
        circus.inspectReceivedState()
        triggerStateChange()
        return
      }
      if (message.x == "u") {
        let statechange = update(message)
        if (circus.state.sessionstate == circus.SessionStates.LOGGEDOUT) return
        if (statechange) {
          circus.inspectReceivedState()
          triggerStateChange()
        }
        return
      }
      debug("unrecognized message type", message)
    }
  }
}

function sendTowebsocket(message) {
  if (circus.state.sessionstate == circus.SessionStates.LOGGEDOUT) return
  if (!webSocket || webSocket.readyState != wsOPEN) {
    circus.state.sessionstate = circus.SessionStates.CLOSED
    connectUntilTimeout()
  }
  message.k = circus.state.clientkey
  if (message.rr) {
    let replyid = Math.floor(Math.random() * Number.MAX_SAFE_INTEGER)  
    circus.state.replyrequests.add(replyid)
    message.rr = replyid
  } else message.rr = -1
  try {
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
      if (e.data.msg) circus.state.pages.add(e.data.msg)
    }
    else if (e.data.type == "__focuspage") {
      channel.postMessage({"focuspage": e.data.msg})
    }
    else if (e.data.type == "__closepage") {
      circus.state.pages.delete(e.data.msg)
      channel.postMessage({"closepage": e.data.msg})
    }
    else if (e.data.type == "__closepages") {
      for (let page of circus.state.pages.values()) {
        if (page != "/") channel.postMessage({"closepage": page})
      }
      circus.state.pages.clear()
    }
    else if (e.data.type == "__acceptlogin") {
      try {
        circus.state.clientkey = e.data.msg.clientkey
        let wsproto = "wss://"
        if (location.protocol == "http:") wsproto = "ws://"
        let path = location.host + e.data.msg.websocketpath
        if (e.data.msg.websocketpath.startsWith(":")) path = location.hostname + e.data.msg.websocketpath
        websocketurl = wsproto + path + "/S" + circus.state.clientkey
        connectUntilTimeout()
      } catch (ex) {
        console.log(ex)
        console.log(JSON.stringify(e))
      }
    }
    else if (e.data.type == "__statecircus_state") {
      circus.state = e.data.msg
      triggerStateChange()
    }
    else if (e.data.type == "__syncstate") syncState(e.data.msg)
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
    else sendTowebsocket({"e": e.data.type, "m": e.data.msg, "rr": e.data.requestreply})
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