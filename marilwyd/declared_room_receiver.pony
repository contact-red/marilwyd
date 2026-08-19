interface tag DeclaredRoomReceiver
  """
  Something waiting to be told about a room declared in the configuration.
  """
  be room_declared(channel: BridgedChannel, room: RoomId)
    """
    The room exists, is published, and answers to its alias.
    """

  be declaration_refused(channel: String)
    """
    The room could not be made — a room id could not be minted, or the id
    or alias the file declared is already in use.
    """
