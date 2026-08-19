interface tag RoomIdReceiver
  """
  Something waiting to be told which room it is holding.
  """
  be room_identified(id: RoomId)
    """
    The room's own id.
    """
