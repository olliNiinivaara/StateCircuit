import {circus} from '/sc_page.js'

const loginform = `
  <form id="formlogin" autocomplete="on" style="text-align: center;">
  <p><strong>Application - Login</strong></p>
  <div>
    <label for="inputemail">email</label>
    <input id="inputemail" name="inputemail"
           type="email" autocomplete="email" autofocus required maxlength=300">
  </div>
  <div id="divpassword">
    <label for="inputpassword">password</label>
    <input id="inputpassword" name="inputpassword"
           type="password" autocomplete="current-password" required maxlength=300">
  </div>
  <button id="buttonlogin" type="submit" disabled>Login</button>
  </form>
`

function enableButtons() {
  eid("buttonlogin").disabled = !eid("inputemail").checkValidity() || eid("inputpassword").value.length == 0
}

function pressEnter(e) {
  if (e.keyCode == 13) {
    eid("inputpassword").focus()
    e.preventDefault()
  }
}

async function submit(e) {
  let password = eid("inputpassword").value
  eid("inputpassword").value = ""
  e.preventDefault()
  let result = await circus.queryServer("/login",{
    "userid": eid("inputemail").value,
    "password": password
  })
  if (!result) alert("Wrong email or password"); else {
    circus.acceptLogin(result)
  }
}

export function renderLogin(element) {
  element.innerHTML = loginform
  eid("inputemail").addEventListener("keydown", pressEnter)
  eid("inputemail").addEventListener("input", enableButtons)
  eid("inputpassword").addEventListener("input", enableButtons)
  eid("formlogin").addEventListener("submit", submit)
}