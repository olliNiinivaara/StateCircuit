from strutils import startsWith, endsWith, count
from os import getCurrentDir
from osproc import execCmdEx
from httpcore import Http200, Http403, Http404
from guildenstern import HttpCtx, getUri, reply

const js = ["Content-Type: text/javascript"]
const css = ["Content-Type: text/css"]

let Directory = getCurrentDir() & "/front"
let PackageDirectory = execCmdEx("nimble path statecircus")[0][0 .. ^2] & "/statecircus/client"

proc echoDirs*() =
  echo "dir: ", getCurrentDir()
  echo "frontdir: ", Directory
  echo "packagedir: ", PackageDirectory

template read(name: string): string =
  try: readFile(name)
  except:
    echo "not found: " & name
    ""

proc serveFile*(ctx: HttpCtx, filename = "") {.gcsafe, raises: [].} =
  var name = if filename == "": ctx.getUri() else: "/" & filename
  if name == "/": name = "/index.html"
  if name.count('.') > 1 or not name.startsWith('/'): (ctx.reply(Http403); return)
  if name.find('?') > 0: name = name.substr(0, name.find('?') - 1)
  if name.find('.') == -1: name &= ".html"

  {.gcsafe.}:
    let f =
      if name in ["/sc_shared.js", "/sc_worker.js", "/sc_page.js"]: read(PackageDirectory & name)
      else: read(Directory & name)
  if f == "": (ctx.reply(Http404); return)

  if name.endsWith(".js"): ctx.reply(Http200, f, js)
  elif name.endsWith(".css"): ctx.reply(Http200, f, css)
  else: ctx.reply(Http200, f)