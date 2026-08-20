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

  be no_room_made()
    """
    The channel is there, but the room for it could not be written.

    Its own answer rather than `no_such_channel`, which would tell a
    client the channel does not exist and invite it to stop asking. This
    is a server failure and the next attempt may work.
    """

actor _DeclaredThen is DeclaredChannelReceiver
  """
  Hands a freshly made bridged room to its asker once it is a room.

  The answer used to be sent the moment the room actor existed, with the
  declaration's own outcome dropped on the floor — justified by the claim
  that a refusal could only be a CSPRNG failure `for_user` had already
  ruled out. It had not: `for_user` mints a *room* id, and writing the
  room mints *event* ids from a separate draw. So a room with no
  `m.room.create` was handed over as though it were good.
  """
  let _receiver: BridgedRoomReceiver tag
  let _room: Room tag

  new create(receiver: BridgedRoomReceiver tag, room: Room tag) =>
    _receiver = receiver
    _room = room

  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    _receiver.bridged_room(_room, network)

  be declaration_refused(channel: String) =>
    _receiver.no_room_made()
