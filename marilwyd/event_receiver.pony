interface tag EventReceiver
  """
  Something waiting to be told whether an event was accepted.
  """
  be event_sent(id: EventId)
    """
    The event was recorded and fanned out to the room's members.
    """

  be event_refused(why: (NotInRoom | NoEventId | BridgeDown | TooManyLines))
    """
    Nothing was recorded, and this is why.
    """
