// export let circus

let handshaking = true
window["closingmyself"] = false

export function setStateCircus(circus) {

  circus.sharedworker = new SharedWorker('/sc_worker.js').port
  circus.broadcastchannel = new BroadcastChannel('statecircus_channel')

  circus.editingfield = null
  circus.fieldchanged = false

  circus.eid = function(id) {return document.getElementById(id)}

  circus.acceptLogin = function(sessioninfo) {
    document.body.style.cursor = 'wait'
    circus.sharedworker.postMessage({"type": "__acceptlogin", "msg": {"websocketpath": sessioninfo.websocketpath, "sessionkey": sessioninfo.sessionkey}})
  }

  circus.sendToServer = function(event, message) {
    if (circus.state.sessionstate !== "OPEN") {
      if (circus.state.debug) console.log("websocket is not open")
      return
    }
    if (!message) message = {}
    if (typeof (message) != "object") throw("message is not an object")
    circus.sharedworker.postMessage({"type": event, "msg": message})
  }

  circus.queryServer = async function(path, query) {
    document.body.style.cursor = 'wait'
    try {
      let response
      try {
        path = circus.uriprefix + path
      response = await fetch(path, {
        body: JSON.stringify({
          k: circus.state.sessionkey,
          q: query
        }), method: "POST"
      })
    } catch (er) {return {status: 0, json: null}}
    if (response.status !== 200) {
      if (circus.state.debug) console.log("queryServer " + path + ": " + response.status)
      return {status: response.status, json: null}
    }
    let text, json
    try {
      text = await response.text()
      json = JSON.parse(text)
    } catch (er) {
      if (circus.state.debug) console.log(er, text)
      return false
    }
    return {status: 200, json: json}
    } finally {
      document.body.style.cursor = 'default'
    }
  }

  circus.operateServer = async function(path, operation) {
    document.body.classList.add("waitcursor")
    try {
      if (!path.startsWith("/")) path = "/o/" + path
      path = circus.uriprefix + path
      let response
      try {
        response = await fetch(path, {
          body: JSON.stringify({
            k: circus.state.sessionkey,
            o: operation
          }), method: "POST"
        })
      } catch (er) {return {status: 0, json: null}}
      if (response.status !== 200) {
        if (circus.state.debug) console.log("operateServer " + path + ": " + response.status)
        return {status: response.status, json: null}
      }
      let text, json
      try {
        text = await response.text()
        if (text.length == 0) return {status: 200, json: null}
        json = JSON.parse(text)
      } catch (er) {
        if (circus.state.debug) console.log(er, text)
        return {status: 0, json: null}
      }
      return {status: 200, json: json}
    } finally {
      document.body.classList.remove("waitcursor")
    }
  }

  circus.sendPrivateAction = async function(path, action) {
    path = circus.uriprefix + path
    let json = await circus.operateServer(path, action)
    if (!json) return false
    circus.handleActions(json.d.a)
    circus.updateInternalState()
    return true
  }

  circus.updatePrivate = async function(field, id, value) {
    document.body.style.cursor = "wait"
    try {
      return await circus.sendPrivateAction(field, {"action": "u", "field": field, "id": parseInt(id), "value": value})
    } finally {
      document.body.style.cursor = "default"
    }
  }

  circus.updateInternalState = function(mutations) {
    if (mutations) circus.handleStatemerge(mutations)
    circus.sharedworker.postMessage({"type": "__statecircus_state", "msg": circus.state})
  }

  circus.logOut = function(reason) {
    circus.sharedworker.postMessage({"type": "__logout", "msg": reason})
  }

  circus.tryToLock = async function(lock) {
    let response
    try {
      let path = "/trytolock"
      path = circus.uriprefix + path
      response = await fetch(path, {
        body: JSON.stringify({
          k: circus.state.sessionkey,
          l: lock
        }), method: "POST"
      })
    } catch (er) {return false}
    if (response.status !== 200) {
      if (circus.state.debug) console.log("trytolock: " + response.status)
      return false
    }
    try {
      let text = await response.text()
      return text == "true"
    } catch (er) {
      if (circus.state.debug) console.log(er)
      return false
    }
  }

  circus.update = function(field, id, value, lock = true) {
    if (typeof(id) != "number") id = parseInt(id)
    if (!lock) lock = ""
    else if (lock == true) lock = field+"/"+id
    circus.sendToServer("u", {"field": field, "id": id, "value": value, "lock": lock})
  }

  circus.releaseLock = function(lock) {
    circus.sendToServer("r", {"l": lock})
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
      if (window.location.pathname == msg.data.focuspage && !window["closingmyself"]) {
      window.focus()
      }
      return
    }
    if (msg.data.closepage) {
      if (window.location.pathname == msg.data.closepage) {
        window["closingmyself"] = true
        window.close()
        if (!window.closed) {
          circus.broadcastchannel.close()
          document.body.innerHTML = "Page open elsewhere"
          circus.sharedworker.postMessage({"type": "__focuspage", "msg": window.location.pathname})
          circus.sharedworker.close()
        }
      }
      return
    }

    if (msg.data.sessionkey == null && window.name != "index") {
      window.open("", "index")
      window.close()
      return
    }

    circus.state = msg.data
    circus.handleStatechange()
  }

  circus.keydown = function(e) {
    if (e.target.readOnly) {
      if (e.key == "Control") return
      if ((e.key == "a" || e.key == "c") && e.ctrlKey) return
      if (circus.tryToLock(e.target.id+"/"+e.target.dataset.idvalue)) {
        circus.editingfield = e.target.id
        circus.render()
        e.target.focus()
      }
      else alert("Someone else is currently editing this field")
    } else {
      if (e.key === "Escape") {
        circus.editingfield = "Escape"
        e.target.blur()
      }
      if (e.key === "Enter") e.target.blur()
    }
  }

  circus.change = function(e) {
    circus.fieldchanged = true
  }

  circus.blur = function(e) {
    if (![e.target.id, "Escape"].includes(circus.editingfield)) return
    if (circus.editingfield == "Escape" || !circus.fieldchanged) {
      circus.editingfield = null
      circus.render()
      return
    }
    if (e.target.checkValidity()) {
      circus.update(e.target.id, e.target.dataset.idvalue, e.target.value)
      circus.editingfield = null
      circus.fieldchanged = false
    } else {
      e.target.classList.add('error')
      e.target.addEventListener("animationend", function errored() {
        e.target.removeEventListener("animationend", errored)
        e.target.classList.remove('error')
      })
      setTimeout(function () { 
        e.target.focus()
        e.target.select()
       }, 20)
    }
  }

  circus.privateKeydown = function(e) {
    if (e.key === "Escape") {
      circus.fieldchanged = false
      circus.render()
      e.target.blur()
    }
    if (e.key === "Enter") e.target.blur()
  }

 circus.privateChange = function(e) {
    e.target.focus()
    circus.fieldchanged = true
    if (e.target.type == "checkbox") e.target.blur()
  }

 circus.privateBlur = function(e) {
    if (!circus.fieldchanged) return
    circus.fieldchanged = false
    if (e.target.checkValidity()) {
      if (e.target.type == "checkbox") circus.updatePrivate(e.target.id, e.target.dataset.idvalue, e.target.checked)
      else circus.updatePrivate(e.target.id, e.target.dataset.idvalue, e.target.value)
    } else {
      e.target.classList.add('error')
      e.target.addEventListener("animationend", function errored() {
        e.target.removeEventListener("animationend", errored)
        e.target.classList.remove('error')
      }) 
      circus.render()
      setTimeout(function () { 
        e.target.focus()
        e.target.select()
       }, 20)
    }
  }
}