function handleActions(actions) {
  for (let a of actions) {
    if (a.action == "valueinserted") {
      sc_state.values.push(a.value)
    }
    else debug("unknown action: " + a.action)
  }
}

function handleQuery(topics) {
  queryState("values", "", ...topics)
}

function handleRefresh(path = "/refresh", aftertimesptamp = sc_state.at) {
  refreshState(path, aftertimesptamp)
}


function handleStatemerge(mutations) {
  if (mutations) sc_state = statecircus_apply(sc_state, mutations)
}

//------------------------

let reconnectiontrials = 0

function handleConnectfailure() {
  reconnectiontrials++
  if (reconnectiontrials > 3) logOut("Could not connect to server")
  else connectUntilTimeout()
}


function handleConnectsuccess(initialstate) {
  reconnectiontrials = 0
  if (initialstate) {
    handleStatemerge(initialstate)
    queryState("values", "", sc_state.firsttopic)
  }
  else handleRefresh()
}

const ServerOverloaded = "Server overloaded. Try again later."

function handleServeroverload() {
  sc_state.alertmessage = ServerOverloaded
}

//------------------------

const WsState = Object.freeze({
  "LOGGEDOUT": "LOGGEDOUT",
  "CONNECTING": "CONNECTING",
  "OPEN": "OPEN",
  "SIMULATEDOUTAGE": "SIMULATEDOUTAGE"
})

// ----------------------

async function waitForturn() {
  if (typeof(queryingsince) == "undefined") window.queryingsince = 0
  while (queryingsince > 0) {
    await new Promise(r => setTimeout(r, 200))
    if (Date.now() - queryingsince > 10000) {
      if (queryingsince > 0) {
        alert("Unstable network connection. Have you tried logging out and in again?")
        return false
      }
    }
  }
  queryingsince = Date.now()
  if (typeof(WORKER) == "undefined") statecircus_worker.postMessage({"type": "__queryStarted"})
}

async function queryState(path, query, ...topics) {
  if (!path || typeof query != "string" || !topics) {
    if (sc_state.debug) console.log("query parameters missing")
    return
  }
  if (!waitForturn()) return
  let json = null
  try {
    if (!path.startsWith("/")) path = "/q/" + path
    let response
    try {
      response = await fetch(path, {
        body: JSON.stringify({
          k: sc_state.sessionkey,
          t: topics,
          q: query
        }), method: "POST"
      })
    } catch (er) {return}
    if (response.status == 204) return
    if (response.status == 503) {
      alert(ServerOverloaded)
      return
    }
    if (response.status !== 200) {
      if (sc_state.debug) console.log("queryState " + path + ": " + response.status)
      return
    }
    let text
    try {
      text = await response.text()
      json = JSON.parse(text)
    } catch (er) {
      if (sc_state.debug) console.log(er, text)
      json = null
      return
    }
    if (json.x != "q") {
      if (sc_state.debug) console.log("query reply not q", json)
      json = null
      return
    }
  } finally {
    if (typeof(WORKER) != "undefined") finishQuery(json)
    else {
      queryingsince = 0
      statecircus_worker.postMessage({"type": "__queryFinished", "msg": json})
    }
  }
}

async function refreshState(path = "/refresh", afterstamp = sc_state.at) {
  if (!waitForturn()) return
  let json = null
  try {
    let response
    try {
      response = await fetch(path, {
        body: JSON.stringify({
          k: sc_state.sessionkey,
         at: afterstamp
        }), method: "POST"
      })
    } catch (er) {return}
    if (response.status == 204) return
    if (response.status == 503) {
      alert(ServerOverloaded)
      return
    }
    if (response.status !== 200) {
      if (sc_state.debug) console.log("refreshState " + path + ": " + response.status)
      return
    }
    let text
    try {
      text = await response.text()
      json = JSON.parse(text)
      if (json.x != "r") {
        if (sc_state.debug) console.log("refresh reply not r", json)
        json = null
        return
      }
    } catch (er) {
      if (sc_state.debug) console.log(er, text)
      json = null
      return
    }
  } finally {
    if (typeof(WORKER) != "undefined") finishQuery(json)
    else {
      queryingsince = 0
      statecircus_worker.postMessage({"type": "__queryFinished", "msg": json})
    }
  }
}

// ----------------------

function statecircus_serialize(value) {
  return (value && typeof value.toJSON === 'function') ? value.toJSON() : value;
}

function statecircus_apply(target, patch) {
  patch = statecircus_serialize(patch);
  if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) {
    return patch;
  }

  target = statecircus_serialize(target);
  if (target === null || typeof target !== 'object' || Array.isArray(target)) {
    target = {};
  }
  var keys = Object.keys(patch);
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i];
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') {
      return target;
    }
    if (patch[key] === null) {
      if (target.hasOwnProperty(key)) {
        delete target[key];
      }
    } else {
      target[key] = statecircus_apply(target[key], patch[key]);
    }
  }
  return target;
};