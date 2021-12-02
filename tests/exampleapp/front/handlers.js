function initStateCircus(circus) {
  addEventListener("beforeunload", function (e) {
    if (window.closingmyself) return
    if (circus.state && circus.state.sessionstate == circus.SessionStates.OPEN && circus.state.task && circus.state.pages && circus.state.pages.size == 1) return "Really exit?"
    circus.broadcastchannel.close()
    circus.sharedworker.postMessage({"type": "__pageclosing", "msg": window.location.pathname})
  })

  circus.uriprefix = ""

  circus.handleConnectsuccess = function(state, topics) {
    circus.reconnectiontrials = 0
    if (state) {
      circus.handleStatemerge(initialstate)
      //circus.queryState("path to query request", "query parameters", circus.state.initialtopic(s))
      //or updateInternalState
      circus.queryState("values", "", circus.state.firsttopic)
    }
    else circus.handleRefresh()
  }

  circus.setStateHandler = function(statehandlerfuction) {
    circus.statehandler = statehandlerfuction
  }

  circus.handleStatechange = function() {
    document.body.style.cursor = 'default'
    if (document.hasFocus()) {
      if (circus.state.debug) {
        console.log("---statecircus state change:")
        console.log(circus.state)
        console.log("---")
      }
      if (circus.state.alertmessage) alert(circus.state.alertmessage)
    }
    circus.statehandler()
    circus.state.alertmessage = null
    circus.state.once = {}
  }

  circus.handleQuery = function(topics) {
    if (document) document.body.style.cursor = 'wait'
    circus.queryState("values", "", ...topics)
  }

  circus.handleActions = function(actions) {
    for (let a of actions) {
      if (a.action == "valueinserted") {
        circus.state.values.push(a.value)
      }
      else debug("unknown action: " + a.action)
    }
  }

  circus.handleRefresh = function(path = "/refresh", aftertimestamp = circus.state.at) {
    circus.refreshState(path, aftertimestamp)
  }

  circus.handleStatemerge = function(mutations) {
    if (mutations) circus.state = circus.apply(circus.state, mutations)
  }

  circus.handleConnectfailure = function() {
    circus.reconnectiontrials++
    if (circus.reconnectiontrials > 3) logOut("Could not connect to server")
    else connectUntilTimeout()
  }

  circus.handleServeroverload = function() {
    circus.state.alertmessage = "Server overloaded. Try again later."
  }
}