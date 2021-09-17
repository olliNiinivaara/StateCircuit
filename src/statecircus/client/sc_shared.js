function createStateCircus(workerscoped = false) {
  let result = {}

  result.SessionStates = Object.freeze({
    "LOGGEDOUT": "LOGGEDOUT",
    "CONNECTING": "CONNECTING",
    "OPEN": "OPEN",
    "SIMULATEDOUTAGE": "SIMULATEDOUTAGE"
  })

  result.defaultState = function() {  
    result.state = {
      "sessionkey": null,
      "uriprefix": "",
      "sessionstate": result.SessionStates.LOGGEDOUT,
      "debug": false,
      "alertmessage": null,
      "at": 0,
      "pages": new Map(),
      "queryingsince": 0
    }
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

  result.queryState = async function(path, query, ...topics) {
    if (!path || typeof query != "string" || !topics) {
      if (result.state.debug) console.log("query parameters missing")
      return
    }
    if (!waitForturn()) return
    let json = null
    try {
      if (!(path.startsWith("/") || path.startsWith("."))) path = "/q/" + path
      let response
      path = result.state.uriprefix + path
      console.log(path)
      try {
        response = await fetch(path, {
          body: JSON.stringify({
            k: result.state.sessionkey,
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
        if (result.state.debug) console.log("queryState " + path + ": " + response.status)
        return
      }
      let text
      try {
        text = await response.text()
        json = JSON.parse(text)
      } catch (er) {
        if (result.state.debug) console.log(er, text)
        json = null
        return
      }
      if (json.x != "q") {
        if (result.state.debug) console.log("query reply not q", json)
        json = null
        return
      }
    } finally {
      if (workerscoped) finishQuery(json)
      else {
        result.state.queryingsince = 0
        result.sharedworker.postMessage({"type": "__queryFinished", "msg": json})
      }
    }
  }

  result.refreshState = async function(path, afterstamp) {
    if (!waitForturn()) return
    let json = null
    try {
      let response
      path = result.state.uriprefix + path
      try {
        response = await fetch(path, {
          body: JSON.stringify({
            k: result.state.sessionkey,
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
        if (result.state.debug) console.log("refreshState " + path + ": " + response.status)
        return
      }
      let text
      try {
        text = await response.text()
        json = JSON.parse(text)
        if (json.x != "r") {
          if (result.state.debug) console.log("refresh reply not r", json)
          json = null
          return
        }
      } catch (er) {
        if (result.state.debug) console.log(er, text)
        json = null
        return
      }
    } finally {
      if (workerscoped) finishQuery(json)
      else {
        result.state.queryingsince = 0
        result.sharedworker.postMessage({"type": "__queryFinished", "msg": json})
      }
    }
  }

  // ----------------------

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