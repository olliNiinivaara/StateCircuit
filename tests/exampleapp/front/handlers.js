function initStateCircus(circus) {

  circus.state.uriprefix = ""

  circus.handleConnectsuccess = function(initialstate) {
    circus.reconnectiontrials = 0
    if (initialstate) {
      circus.handleStatemerge(initialstate)
      //circus.queryState("path to query request", "query parameters", circus.state.initialtopic(s))
      //tai updateState?
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
  }

  circus.handleQuery = function(topics) {
    if (document) document.body.style.cursor = 'wait'
    circus.queryState("values", "", ...topics)
  }

  /*
  function handleQuery(topics) {
    if (1 in topics) queryState("path to query request", "query parameters", ...topics)
    // else if ...
  }*/

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