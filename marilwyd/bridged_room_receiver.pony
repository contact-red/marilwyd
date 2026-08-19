interface tag BridgedRoomReceiver
  """
  Something waiting for one person's own room for a bridged channel.
  """
  be bridged_room(room: Room tag, network: BridgedNetwork)
    """
    The room they hold for that channel, made if they had none.
    """

  be no_such_channel()
    """
    No channel answers to that alias.
    """

actor _IgnoreDeclaration is DeclaredRoomReceiver
  """
  A per-user room's own declaration answer is nobody's business: the
  caller already holds the room, and a refusal can only be a CSPRNG
  failure that `for_user` has already ruled out by minting the id.
  """
  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    None

  be declaration_refused(channel: String) => None
