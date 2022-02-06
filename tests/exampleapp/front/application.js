const application = `
  <input id="input">
  <button id="button">send</button>
  <br>
  <button id="outage"></button>
  <button id="refresh">Refresh</button>
  <ul id="ul"></ul>
`

function pressEnter(e) {
  if (e.keyCode == 13) {
    onClick()
    e.preventDefault()
  }
}

function onClick() {
  circus.sendToServer("insertvalue", {"value": eid("input").value})
}

function onOutage() {
  circus.sharedworker.postMessage({"type": "__simulatedoutage", "msg": {"simulatedoutage": circus.state.sessionstate != circus.SessionStates.SIMULATEDOUTAGE}})
}

function onRefresh() {
  circus.syncState()
}

export function renderApplication(element) {
  element.innerHTML = application
  eid("input").addEventListener("keydown", pressEnter)
  eid("button").addEventListener("click", onClick)
  eid("outage").addEventListener("click", onOutage)
  eid("refresh").addEventListener("click", onRefresh)
  if (circus.state.sessionstate == circus.SessionStates.SIMULATEDOUTAGE) eid("outage").innerHTML = "recover network operation"
  else eid("outage").innerHTML = "simulate network outage"
  for (const value of circus.state.values) {
    let li = document.createElement("li")
    li.appendChild(document.createTextNode(value))
    eid("ul").appendChild(li)
  }
}