primitive NotInRoom
  """
  The caller is not a member of the room they named.
  """
  fun message(): String => "You are not a member of that room"

primitive NoSuchRoom
  """
  No room by that id exists in this process. Rooms do not survive a
  restart, so this is also what a client sees for a room it was in before
  one.
  """
  fun message(): String => "No such room"

primitive NoEventId
  """
  The CSPRNG could not mint an event id, so nothing was recorded.
  """
  fun message(): String =>
    "The CSPRNG is unavailable, so no event could be recorded"

primitive BridgeDown
  """
  The room is bridged and its connection to the network is not carrying.

  Refused rather than accepted, because a bridged room's whole content is
  that connection: an event accepted while it is down would be recorded,
  answered with an id, fanned out to the sender's own client — and never
  reach the channel the sender was writing to. A client that is told the
  message failed can send it again; one that is told it succeeded cannot.
  """
  fun message(): String =>
    "The connection to the network is down, so nothing was sent"

primitive NotInvited
  """
  The room may be entered by invitation only, and the caller holds none.

  A room id is the first half of the access control on a room, and this is
  the second — for every room that did not ask to be found, which is every
  room without an alias and without a place in the public directory. A
  room that did ask has no second half, by its own request.
  """
  fun message(): String =>
    "You are not invited to that room"
