interface tag StateReceiver
  """
  Something waiting for a room's current state.
  """
  be state_listed(events: Array[RoomEvent] val)
    """
    The room's current state, one event per type and state key.
    """

  be state_refused(why: NotInRoom)
    """
    The caller may not read that room's state.
    """
