let sc_state
const statecircus_worker = new SharedWorker('/sc_worker.js').port
const statecircus_recvchannel = new BroadcastChannel('statecircus_channel')
let statecircus_handleStatechange
let handshaking = true
let closingmyself = false

function acceptLogin(sessioninfo) {
  document.body.style.cursor = 'wait'
  statecircus_worker.postMessage({"type": "__acceptlogin", "msg": {"websocketpath": sessioninfo.websocketpath, "sessionkey": sessioninfo.sessionkey}})
}

function sendToServer(event, message) {
  if (sc_state.wsstate !== "OPEN") {
    if (sc_state.debug) console.log("websocket is not open")
    return
  }
  if (typeof (message) != "object") throw("message is not an object")
  statecircus_worker.postMessage({"type": event, "msg": message})
}

async function queryServer(path, query) {
  let response
  try {
    response = await fetch(path, {
      body: JSON.stringify({
        k: sc_state.sessionkey,
        q: query
      }), method: "POST"
    })
  } catch (er) {return false}
  if (response.status !== 200) {
    if (sc_state.debug) console.log("queryServer " + path + ": " + response.status)
    return false
  }
  let text, json
  try {
    text = await response.text()
    json = JSON.parse(text)
  } catch (er) {
    if (sc_state.debug) console.log(er, text)
    return false
  }
  return json
}

function updateState(mutations) {
  if (mutations) handleStatemerge(mutations)
  statecircus_worker.postMessage({"type": "__statecircus_state", "msg": sc_state})
}

function logOut(reason) {
  statecircus_worker.postMessage({"type": "__logout", "msg": reason})
}

statecircus_recvchannel.onmessage = function (msg) {
  if (!msg.data) {
    if (sc_state.debug) console.log("dataless msg from worker")
    return
  }

  if (msg.data.workerconfirmedconnection) {
    if (!handshaking) return 
    if (msg.data.workerconfirmedconnection.has(window.location.pathname)) {
      statecircus_worker.postMessage({"type": "__closetab", "msg": window.location.pathname})
      return
    }  
    if (statecircus_handleStatechange) {
      statecircus_worker.postMessage({"type": "__tabconfirmedconnection", "msg": window.location.pathname})
      handshaking = false
    }
    return
  }

  if (handshaking) return
  
  if (msg.data.focustab) {
    if (window.location.pathname == msg.data.focustab && !closingmyself) {
      window.focus()
    }
    return
  }
  if (msg.data.closetab) {
    if (window.location.pathname == msg.data.closetab) {
      closingmyself = true
      window.close()
      if (!window.closed) {
        statecircus_recvchannel.close()
        body.innerHTML = "Page open elsewhere"
        statecircus_worker.postMessage({"type": "__focustab", "msg": window.location.pathname})
        statecircus_worker.close()
      }
    }
    return
  }
  sc_state = msg.data
  statecircus_handleStatechange()
}

addEventListener("beforeunload", function (e) {
  if (closingmyself) return
  if (sc_state && sc_state.wsstate == WsState.OPEN && sc_state.tabs.size == 1) {
    if (!window.confirm("Really exit?")) {
      e.preventDefault()
      return
    }
  }
  statecircus_recvchannel.close()
  statecircus_worker.postMessage({"type": "__tabclosing", "msg": window.location.pathname})
})