use "json"

class val AccountDatum
  """
  One piece of a user's account data: a type, and the content stored under
  it.

  `content` is already-printed JSON, for `RoomEvent`'s reason — a
  `JsonObject` has no deep copy, so one built by a handler and stored by an
  actor would pin that handler, its connection and its request body for as
  long as the data lived.
  """
  let kind: String
  let content: String

  new val create(kind': String, content': String) =>
    kind = kind'
    content = content'

  fun val render(): String =>
    """
    The datum as a client sees it in a sync.
    """
    recover val
      String(content.size() + 64)
        .> append("{\"type\":")
        .> append(JsonPrinter.print(kind))
        .> append(",\"content\":")
        .> append(content)
        .> append("}")
    end
