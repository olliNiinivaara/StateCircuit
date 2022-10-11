function createStateCircus(workerscoped = false) {
  let protostate = {
    "clientkey": null,
    "sessionstate": "LOGGEDOUT",
    "debug": false,
    "alertmessage": null,
    "logtext": null,
    "logobject": null,
    "once": {},
    "pages": new Set(),
    "replyrequests": new Set()
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

  result.syncState = function(topics) {
    if (!workerscoped) result.sharedworker.postMessage({"type": "__syncstate", "msg": topics})
    else syncState(topics)
  }

  result.post = async function(path, query) {
    if (!path) {
      console.log("path missing")
      return {status: 0, json: null}
    }
    if (!workerscoped) document.body.style.cursor = 'wait'
    let json
    try {
      let response
      try {
        path = result.uriprefix + path
        if (result.state.debug) console.log(path)
        response = await fetch(path, {
          body: JSON.stringify({
            k: result.state.clientkey,
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
        if (circus.state.debug) console.log(path + ": " + response.status)
        return {status: response.status, json: null}
      }
      let text
      try {
        text = await response.text()
        if (!text) return {status: 200, json: null}
        json = JSON.parse(text)
      } catch (er) {
        if (circus.state.debug) console.log(er, text)
        return {status: 0, json: null}
      }
      return {status: 200, json: json}
    } finally {
      if (workerscoped) finishQuery(json)
      else document.body.style.cursor = 'default'
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