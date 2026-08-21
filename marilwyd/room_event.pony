use "json"

class val RoomEvent
  """
  One event in one room.

  `state_key` present is what makes an event a state event — Matrix's own
  distinction rather than a flag invented here — so a message and a state
  change are one type with one optional field rather than two types that
  render identically into the same timeline.

  `content` is **already-printed JSON**, not a `JSONObject`. The handler
  parses the client's bytes, validates them, and prints them back through
  `JSONPrinter`; the registry stores the text. Three reasons, in order of
  weight: a `JSONObject` has no deep copy, so one built by a handler would
  pin that handler, its connection and its request body under ORCA for as
  long as the event is retained; measured, the object form costs 901 bytes
  for a minimal message against 82 bytes of text, and 533 kB at the body
  limit; and rendering a document by concatenation measured ~1 µs against
  ~15 µs through the object tree. Escaping is still `JSONPrinter`'s — the
  registry concatenates text that was printed, never text it assembled.
  """
  let id: EventId
  let room: RoomId
  let kind: String
  let sender: String
  let timestamp: I64
  let content: String
  let state_key: (String | None)
  let position: USize

  new val create(
    id': EventId,
    room': RoomId,
    kind': String,
    sender': String,
    timestamp': I64,
    content': String,
    state_key': (String | None),
    position': USize)
  =>
    id = id'
    room = room'
    kind = kind'
    sender = sender'
    timestamp = timestamp'
    content = content'
    state_key = state_key'
    position = position'

  fun val render(): String =>
    """
    The event as a client sees it.

    Built by concatenation over values that are either minted here or
    already printed, so nothing unescaped reaches the output.
    """
    recover val
      let out = String(content.size() + 256)
      out.append("{\"event_id\":")
      out.append(JSONPrinter.print(id.string()))
      out.append(",\"type\":")
      out.append(JSONPrinter.print(kind))
      out.append(",\"sender\":")
      out.append(JSONPrinter.print(sender))
      out.append(",\"origin_server_ts\":")
      out.append(timestamp.string())
      out.append(",\"content\":")
      out.append(content)
      match state_key
      | let k: String =>
      out.append(",\"state_key\":")
      out.append(JSONPrinter.print(k))
    end
      out.append("}")
      out
    end
