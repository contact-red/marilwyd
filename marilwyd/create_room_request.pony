class val CreateRoomRequest
  """
  What marilwyd will honour from a `createRoom` body.

  A validated value rather than the parsed body, so nothing a client asked
  for that this server does not enforce can travel any further than the
  handler that read it. `README.md` lists what is dropped and why; the rule
  is that marilwyd writes the state it actually serves and nothing else.

  `published` is Matrix's `visibility`, named for what it does here: the
  room appears in the directory every account can read. Publishing one is
  the same act as handing its id out, which is why an alias implies it —
  and why both make a room public rather than invite-only. See `open`.
  """
  let name: (String | None)
  let alias: (RoomAlias | None)
  let published: Bool
  // The algorithm the room is encrypted with, when a client asked for
  // one. Creation-time and nowhere else: marilwyd has no endpoint that
  // sets state after a room exists, so a room that was not asked to be
  // encrypted cannot become so, and one that was cannot stop being.
  let encryption: (String | None)

  new val create(
    name': (String | None),
    alias': (RoomAlias | None),
    published': Bool,
    encryption': (String | None) = None)
  =>
    name = name'
    alias = alias'
    published = published'
    encryption = encryption'

  fun open(): Bool =>
    """
    Whether this room may be entered by anyone who can name it.

    True when the room was asked to be findable — published, or given an
    alias, which publishes it. Somebody who asked for a room to be found
    is asking for people to arrive at it without being invited, and a room
    that is listed and then refuses everyone who reads the listing is a
    worse answer than not listing it.

    False otherwise, which is the default: a room nobody was told about is
    a room for the people its creator names.
    """
    published or (alias isnt None)

  fun encrypted(): Bool =>
    """
    Whether this room was asked to be one its server cannot read.
    """
    encryption isnt None
