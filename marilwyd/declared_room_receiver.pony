interface tag DeclaredRoomReceiver
  """
  Something waiting to be told about a room declared in the configuration.
  """
  be room_declared(channel: BridgedChannel, id: RoomId, room: Room tag)
    """
    The room exists, is published, and answers to its alias.

    The actor travels with the id because the caller has something to hand
    it to — a bridge needs the room its channel is, and looking it back up
    through the directory would be asking a question already answered.
    """

  be declaration_refused(channel: String)
    """
    The room could not be made — a room id could not be minted, or the id
    or alias the file declared is already in use.
    """
