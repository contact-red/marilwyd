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
