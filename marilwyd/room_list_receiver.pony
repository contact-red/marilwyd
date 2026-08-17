interface tag RoomListReceiver
  """
  Something waiting for the rooms an account is in.
  """
  be rooms_listed(rooms: Array[String] val)
    """
    Every room this account is currently in.
    """
