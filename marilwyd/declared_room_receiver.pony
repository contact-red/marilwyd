interface tag DeclaredRoomReceiver
  """
  Something waiting to be told about a room declared in the configuration.
  """
  be channel_declared(channel: BridgedChannel, network: BridgedNetwork)
    """
    A channel was declared. No room exists for it yet — one is made for
    each person who enters it.
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
