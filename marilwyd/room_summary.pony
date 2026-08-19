use "json"

class val RoomSummary
  """
  What a stranger may learn about a room without joining it.

  Everything here is already public by the act of publishing the room: its
  id is what a directory exists to hand out, and its name and alias are how
  a person recognises it. The member count is the one number that is not
  obviously public, and it is what every client renders beside a room in a
  directory listing.

  No topic and no avatar: marilwyd stores neither, and a field that is
  always absent is better absent than always empty.
  """
  let id: String
  let name: (String | None)
  let alias: (String | None)
  let members: USize

  new val create(
    id': String,
    name': (String | None),
    alias': (String | None),
    members': USize)
  =>
    id = id'
    name = name'
    alias = alias'
    members = members'

  fun val render(): String =>
    recover val
      let out = String(256)
      out.append("{\"room_id\":")
      out.append(JsonPrinter.print(id))
      match name
      | let n: String =>
        out.append(",\"name\":")
        out.append(JsonPrinter.print(n))
      end
      match alias
      | let a: String =>
        out.append(",\"canonical_alias\":")
        out.append(JsonPrinter.print(a))
      end
      out.append(",\"num_joined_members\":")
      out.append(members.string())
      // Both are false and both are said. A client hides a room from a
      // guest on the first, and marilwyd has no guests; the second would
      // promise history to someone who has not joined, and a room keeps
      // none.
      out.append(",\"world_readable\":false,\"guest_can_join\":false}")
      out
    end

primitive _NameIn
  """
  Pull one string field out of a state event's stored content.

  The content is text that was printed by `JsonPrinter`, so this parses
  what marilwyd itself wrote rather than anything a client sent directly.
  """
  fun apply(content: (String | None), field: String = "name")
    : (String | None)
  =>
    match content
    | let text: String =>
      match JsonParser.parse(text)
      | let o: JsonObject =>
        try
          match o(field)?
          | let found: String => return found.clone()
          end
        end
      end
    end
    None
