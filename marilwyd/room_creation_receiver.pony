interface tag RoomCreationReceiver
  """
  Something waiting to be told a room was made.
  """
  be room_created(room: RoomId)
    """
    The room exists and its creator is in it.
    """

  be alias_taken()
    """
    No room was made: another room already answers to that alias. Reported
    rather than folded into `room_refused`, because a caller can act on it
    — a different name works, where a CSPRNG failure leaves nothing to try.
    """

  be room_refused()
    """
    No room was made. The CSPRNG could not mint an id, and a room id is
    the only thing gating access to a room, so there is no weaker one
    worth handing out.
    """
