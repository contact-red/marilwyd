class val CreateRoomRequest
  """
  What marilwyd will honour from a `createRoom` body.

  A validated value rather than the parsed body, so nothing a client asked
  for that this server does not enforce can travel any further than the
  handler that read it. `README.md` lists what is dropped and why; the rule
  is that marilwyd writes the state it actually serves and nothing else.

  `published` is Matrix's `visibility`, named for what it does here: the
  room appears in the directory every account can read. It is not an access
  control — a room id is the whole of that — which is why publishing one is
  the same act as handing its id out, and why an alias implies it.
  """
  let name: (String | None)
  let alias: (RoomAlias | None)
  let published: Bool

  new val create(
    name': (String | None),
    alias': (RoomAlias | None),
    published': Bool)
  =>
    name = name'
    alias = alias'
    published = published'
