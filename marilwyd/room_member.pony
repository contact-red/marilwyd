interface tag RoomMember
  """
  Anything a room fans events out to.

  A person's account is one; a bridged user's own IRC connection is
  another. A room never learns which it is holding, which is what keeps
  bridging out of `Room` — the three behaviours below are the whole of what
  a room asks of a member, and they were `User`'s signatures before this
  interface existed to name them.
  """
  be deliver(event: RoomEvent)
    """
    An event the member is entitled to.
    """

  be joined(room_id: String, room: Room tag)
    """
    The member is now in this room.
    """

  be departed(room_id: String)
    """
    The member has left it.
    """
