export let circus

let handshaking = true
let closingmyself = false

export function setStateCircus(statecircus) {
  circus = statecircus

  circus.sharedworker = new SharedWorker('/sc_worker.js').port
  circus.broadcastchannel = new BroadcastChannel('statecircus_channel')

  circus.acceptLogin = function(sessioninfo) {
    document.body.style.cursor = 'wait'
    circus.sharedworker.postMessage({"type": "__acceptlogin", "msg": {"websocketpath": sessioninfo.websocketpath, "sessionkey": sessioninfo.sessionkey}})
  }

  circus.sendToServer = function(event, message) {
    if (circus.state.sessionstate !== "OPEN") {
      if (circus.state.debug) console.log("websocket is not open")
      return
    }
    if (typeof (message) != "object") throw("message is not an object")
    circus.sharedworker.postMessage({"type": event, "msg": message})
  }

  circus.queryServer =  async function(path, query) {
    let response
    try {
      response = await fetch(path, {
        body: JSON.stringify({
          k: circus.state.sessionkey,
          q: query
        }), method: "POST"
      })
    } catch (er) {return false}
    if (response.status !== 200) {
      if (circus.state.debug) console.log("queryServer " + path + ": " + response.status)
      return false
    }
    let text, json
    try {
      text = await response.text()
      json = JSON.parse(text)
    } catch (er) {
      if (circus.state.debug) console.log(er, text)
      return false
    }
    return json
  }

  circus.updateState = function(mutations) {
    if (mutations) handleStatemerge(mutations)
    circus.sharedworker.postMessage({"type": "__statecircus_state", "msg": circus.state})
  }

  circus.logOut = function(reason) {
    circus.sharedworker.postMessage({"type": "__logout", "msg": reason})
  }

  circus.broadcastchannel.onmessage = function(msg) {
    if (!msg.data) {
      if (circus.state.debug) console.log("dataless msg from sharedworker")
      return
    }

    if (msg.data.workerconfirmedconnection) {
      if (!handshaking) return 
      if (msg.data.workerconfirmedconnection.has(window.location.pathname)) {
        circus.sharedworker.postMessage({"type": "__closepage", "msg": window.location.pathname})
        return
      }  
      if (circus.statehandler) {
        circus.sharedworker.postMessage({"type": "__pageconfirmedconnection", "msg": window.location.pathname})
        handshaking = false
      }
      return
    }

    if (handshaking) return
    
    if (msg.data.focuspage) {
      if (window.location.pathname == msg.data.focuspage && !closingmyself) {
        window.focus()
      }
      return
    }
    if (msg.data.closepage) {
      if (window.location.pathname == msg.data.closepage) {
        closingmyself = true
        window.close()
        if (!window.closed) {
          circus.broadcastchannel.close()
          body.innerHTML = "Page open elsewhere"
          circus.sharedworker.postMessage({"type": "__focuspage", "msg": window.location.pathname})
          circus.sharedworker.close()
        }
      }
      return
    }
    circus.state = msg.data
    circus.handleStatechange()
  }
}  

addEventListener("beforeunload", function (e) {
  if (closingmyself) return
  if (circus.state && circus.state.sessionstate == circus.SessionStates.OPEN && circus.state.pages.size == 1) {
    if (!window.confirm("Really exit?")) {
      e.preventDefault()
      return
    }
  }
  circus.broadcastchannel.close()
  circus.sharedworker.postMessage({"type": "__pageclosing", "msg": window.location.pathname})
})