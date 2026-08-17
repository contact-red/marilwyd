interface tag RoomCreationReceiver
  """
  Something waiting to be told a room was made.
  """
  be room_created(room: RoomId)
    """
    The room exists and its creator is in it.
    """

  be room_refused()
    """
    No room was made. The CSPRNG could not mint an id, and a room id is
    the only thing gating access to a room, so there is no weaker one
    worth handing out.
    """
