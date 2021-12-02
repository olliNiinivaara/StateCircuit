import std/json
from ../parasuber import Topic

func initMessage*(state: string, topics: openArray[Topic]): string =
  # if session.initialized: return ""
  # session.initialized = true
  result = """{"x":"i""""
  if state != "":
    result.add(""", "state": """)
    result.add(state)
  if topics.len > 0:
    result.add(""", "topics": [""")
    for topic in topics:
      result.add($int(topic))
      result.add(',')
    result[result.high] = ']'  
  result.add('}')

func toReply*(state: JsonNode, action: string, actionvalue: string = ""): string =
  result = """"st": """
  result.add($state)
  result.add(""","a": [{"action":"""")
  result.add(action)
  result.add('"')
  if actionvalue != "":
    result.add(""", "value":""")
    result.add($actionvalue)
  result.add("}]")

func replyAction*(action: string, value: JsonNode): string {.inline.} = 
  result = """"a": [{"action":""""
  result.add(action)
  result.add("""", "value":""")
  result.add($value)
  result.add("}]")

func replyAction*(action: string, value: string): string {.inline.} =
  result = """"a": [{"action":""""
  result.add(action)
  result.add("""", "value":""")
  result.add(value)
  result.add("}]")

func replyActionstring*(action: string, value: string): string {.inline.} =
  result = """"a": [{"action":""""
  result.add(action)
  result.add("""", "value":"""")
  result.add(value)
  result.add(""""}]""")

#proc replyStatestring*(state: var string) {.inline.} =
#  state = """"st": """".add(state).add('"')

func replyState*(state: JsonNode) : string {.inline.} = 
  result = """"st": """
  result.add($state)

func replyState*(state: string) : string {.inline.} = 
  result = """"st": """
  result.add(state)