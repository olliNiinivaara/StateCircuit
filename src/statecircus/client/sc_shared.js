function createStateCircus(workerscoped = false) {
  let protostate = {
    "sessionkey": null,
    "sessionstate": "LOGGEDOUT",
    "debug": false,
    "alertmessage": null,
    "once": {},
    "at": 0,
    "pages": new Map(),
    "queryingsince": 0
  } 
  
  let result = {"state": {}}

  result.SessionStates = Object.freeze({
    "LOGGEDOUT": "LOGGEDOUT",
    "CONNECTING": "CONNECTING",
    "OPEN": "OPEN",
    "SIMULATEDOUTAGE": "SIMULATEDOUTAGE"
  })

  result.inspectReceivedState = function() {}

  result.uriprefix = ""

  result.emptyState = function() {
    result.state.alertmessage = null
    result.state.once = {}
    for (const prop in result.state) {
      if (!protostate.hasOwnProperty(prop)) {
        delete result.state[prop]
      }
    }
  }

  result.defaultState = function() {
    Object.assign(result.state, protostate)
    result.emptyState()
  }

  result.defaultState()

  async function waitForturn() {
    while (result.state.queryingsince > 0) {
      await new Promise(r => setTimeout(r, 200))
      if (Date.now() - result.state.queryingsince > 10000) {
        if (result.state.queryingsince > 0) {
          alert("Unstable network connection. Have you tried logging out and in again?")
          result.state.queryingsince = 0
          return false
        }
      }
    }
    result.state.queryingsince = Date.now()
    if (!workerscoped) result.sharedworker.postMessage({"type": "__queryStarted"})
  }

  result.sendToServerAndReceive = async function(path, query, ...topics) {
    if (!path) {
      console.log("path missing")
      return {status: 0, json: null}
    }
    if (!waitForturn()) return {status: 0, json: null}
    if (!workerscoped) document.body.style.cursor = 'wait'
    let json
    if (topics.length == 1 && Array.isArray(topics[0])) topics = topics[0]
    try {
      let response
      try {
        path = result.uriprefix + path
        if (result.state.debug) console.log(path)
        response = await fetch(path, {
          body: JSON.stringify({
            k: result.state.sessionkey,
            t: topics,
            q: query
          }), method: "POST"
        })
      } catch (er) {return {status: 0, json: null}}
      if (response.status == 204) {return {status: 204, json: null}}
      if (response.status == 503) {
        alert(ServerOverloaded)
        return {status: 503, json: null}
      }
      if (response.status !== 200) {
        if (circus.state.debug) console.log("sendToServerAndReceive " + path + ": " + response.status)
        return {status: response.status, json: null}
      }
      let text
      try {
        text = await response.text()
        json = JSON.parse(text)
      } catch (er) {
        if (circus.state.debug) console.log(er, text)
        return {status: 0, json: null}
      }
      return {status: 200, json: json}
    } finally {
      if (workerscoped) finishQuery(json)
      else {
        document.body.style.cursor = 'default'
        result.state.queryingsince = 0
        result.sharedworker.postMessage({"type": "__queryFinished", "msg": json})
      }
    }
  }

  result.syncState = async function(topics) {
    let response = await result.sendToServerAndReceive("/syncstate", null, topics)
    if (response.status == 200) {
      
    }
  }
 
  function serialize(value) {
    return (value && typeof value.toJSON === 'function') ? value.toJSON() : value;
  }

  result.apply = function(target, patch) {
    patch = serialize(patch);
    if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) {
      return patch;
    }

    target = serialize(target);
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
        target[key] = result.apply(target[key], patch[key]);
      }
    }
    return target;
  };

  return result
}