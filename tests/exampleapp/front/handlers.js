function initStateCircus(circus) {
  addEventListener("beforeunload", function (e) {
    if (window.closingmyself) return
    if (circus.state && circus.state.sessionstate == circus.SessionStates.OPEN && circus.state.task && circus.state.pages && circus.state.pages.size == 1) return "Really exit?"
    circus.broadcastchannel.close()
    circus.sharedworker.postMessage({"type": "__pageclosing", "msg": window.location.pathname})
  })

  // circus.uriprefix = "/exampleapi"

  circus.handleConnectsuccess = function(state, topics) {
    circus.reconnectiontrials = 0
    circus.handleStatemerge(state)
    /*let thetopics = getTopics()
    if (thetopics.length == 0) thetopics = topics
    circus.syncState(thetopics)*/
  }

  circus.setStateHandler = function(statehandlerfuction) {
    circus.statehandler = statehandlerfuction
  }

  circus.handleStatechange = function() {
    if (document.hasFocus()) {
      if (circus.state.alertmessage) alert(circus.state.alertmessage)
    }
    circus.statehandler()
    circus.state.alertmessage = null
    circus.state.once = {}
  }

  circus.handleAction = function(action, value) {
    if (action == "valueinserted") circus.state.values.push(value)
    else debug("unknown action: " + action)
  }

  circus.handleReply = function(reply, value) {
    debug("unknown reply: " + reply)
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