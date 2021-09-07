from strutils import startsWith, endsWith, count
from os import getCurrentDir
from osproc import execCmdEx
from httpcore import Http200, Http403, Http404
from guildenstern import HttpCtx, getUri, reply

const js = ["Content-Type: text/javascript"]
const css = ["Content-Type: text/css"]

let Directory = getCurrentDir()
let PackageDirectory = execCmdEx("nimble path statecircus")[0][0 .. ^2] & "/statecircus/client"

template read(name: string): string =
  try: readFile(name)
  except:
    echo "not found: " & name
    ""

proc serveFile*(ctx: HttpCtx) {.gcsafe, raises: [].} =
  var uri = ctx.getUri()
  # echo uri
  if uri == "/": uri = "/index.html"
  if uri.count('.') > 1 or not uri.startsWith('/'): (ctx.reply(Http403); return)

  {.gcsafe.}:
    let f =
      if uri in ["/sc_worker.js", "/sc_tab.js"]: read(PackageDirectory & uri)
      else: read(Directory & uri)
  if f == "": (ctx.reply(Http404); return)

  if uri.endsWith(".js"): ctx.reply(Http200, f, js)
  elif uri.endsWith(".css"): ctx.reply(Http200, f, css)
  else: ctx.reply(Http200, f)