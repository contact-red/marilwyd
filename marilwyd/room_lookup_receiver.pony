interface tag RoomLookupReceiver
  """
  Something waiting to be handed the room it named.
  """
  be room_found(room: Room tag)
    """
    The room the caller named.
    """

  be room_missing()
    """
    No room by that id exists in this process.
    """
