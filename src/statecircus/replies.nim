import std/json
from pkg/statecircus/subber import Topic, Subscriber, `$`

func initMessage*(state: string, topics: openArray[Topic]): string =
  result = """{"x":"i", """
  if state != "":
    result.add(""""state": """)
    result.add(state)
    result.add(',')
  if topics.len > 0:
    result.add(""""topics": [""")
    for topic in topics:
      result.add($int(topic))
      result.add(',')
    result[result.high] = ']'  
  result.add('}')

func replyStateAndAction*(state: JsonNode, action: string, actionvalue: string = ""): string =
  result = """"st": """
  result.add($state)
  result.add(""","a": {"action":"""")
  result.add(action)
  result.add('"')
  if actionvalue != "":
    result.add(""", "value":""")
    result.add($actionvalue)
  result.add("}")

func replyAction*(action: string, value: JsonNode): string {.inline.} = 
  result = """"a": {"action":""""
  result.add(action)
  result.add("""", "value":""")
  result.add($value)
  result.add("}")

func replyAction*(action: string, value: string): string {.inline.} =
  result = """"a": {"action":""""
  result.add(action)
  result.add("""", "value":""")
  result.add(value)
  result.add("}")

func replyActionstring*(action: string, value: string): string {.inline.} =
  result = """"a": {"action":""""
  result.add(action)
  result.add("""", "value":"""")
  result.add(value)
  result.add(""""}""")

func replyState*(state: JsonNode): string {.inline.} = 
  result = """"st": """
  result.add($state)

func replyState*(state: string): string {.inline.} = 
  result = """"st": """
  result.add(state)

func replyOne*(replyid: int, subject: string, value: string): string {.inline.} = 
  result = """"reply": {"replyid":"""
  result.add($replyid)
  result.add(""", "subject":"""")
  result.add(subject)
  result.add("""", "value":""")
  result.add(value)
  result.add'}'

func replyOne*(replyid: int, subject: string, value: JsonNode): string {.inline.} = 
  result = """"reply": {"replyid":"""
  result.add($replyid)
  result.add(""", "subject":"""")
  result.add(subject)
  result.add("""", "value":""")
  result.add($value)
  result.add'}'

func sendOne*(subject: string, value: string): string {.inline.} = 
  result = """"one": {"subject":""""
  result.add(subject)
  result.add("""", "value":""")
  result.add(value)
  result.add'}'

func sendOne*(subject: string, value: JsonNode): string {.inline.} = 
  result = """"one": {"subject":""""
  result.add(subject)
  result.add("""", "value":""")
  result.add($value)
  result.add'}'

#[func replyOne*(replyid: int, reply: string, value: string): string {.inline.} = 
  result = """"one": {"replyid":"""
  result.add($replyid)
  result.add(""", "reply":"""")
  result.add(reply)
  result.add("""", "value":""")
  result.add(value)
  result.add'}'

func replyOne*(replyid: int, reply: string, value: JsonNode): string {.inline.} = 
  result = """"one": {"replyid":"""
  result.add($replyid)
  result.add(""", "reply":"""")
  result.add(reply)
  result.add("""", "value":""")
  result.add($value)
  result.add'}'

func replyOnestring*(replyid: int, reply: string, value: string): string {.inline.} = 
  result = """"one": {"replyid":"""
  result.add($replyid)
  result.add(""", "reply":"""")
  result.add(reply)
  result.add("""", "value":"""")
  result.add(value)
  result.add""""}"""

func replyOneAndState*(replyid: int, reply: string, value: string, state: string): string {.inline.} = 
  result = """"one": {"replyid":"""
  result.add($replyid)
  result.add(""", "reply":"""")
  result.add(reply)
  result.add("""", "value":""")
  result.add(value)
  result.add'}'
  result.add(""","st": """)
  result.add(state)

func replyOneAndState*(replyid: int, reply: string, value: string, state: JsonNode): string {.inline.} = 
  result = """"one": {"replyid":"""
  result.add($replyid)
  result.add(""", "reply":"""")
  result.add(reply)
  result.add("""", "value":""")
  result.add(value)
  result.add'}'
  result.add(""","st": """)
  result.add($state)]#