use "collections"

actor RoomDirectory
  """
  Which room actor is which.

  One map lookup on the paths that name a room — creating, joining,
  leaving, sending, reading state. Deliberately **not** on the fan-out
  path: once a `User` has joined a room it holds that room's tag directly,
  so delivering an event never comes back here. That is what keeps the one
  shared actor in this design off the path that runs per message.
  """
  let _homeserver: Homeserver
  embed _rooms: Map[String, Room tag] = _rooms.create()
  // An alias resolves to a room id, and a published room is one the
  // directory will name to anyone who asks. They are separate maps because
  // they answer separate questions: a room may be published without an
  // alias, and — though nothing does it today — aliased without being
  // published.
  embed _aliases: Map[String, String] = _aliases.create()
  embed _published: Map[String, Room tag] = _published.create()
  // A bridged channel is not a room. Every Matrix user who enters one gets
  // their own, because a room is what one IRC session heard — and a
  // session's view of a channel is inherently its own. Sharing one room
  // between several sessions meant every message crossed the boundary once
  // per member and everyone saw it that many times.
  //
  // Keyed by alias: what the directory advertises and what a person types.
  embed _channels: Map[String, (BridgedChannel, BridgedNetwork)] =
    _channels.create()
  // The room one user has for one channel, keyed by alias and user id.
  embed _theirs: Map[String, Room tag] = _theirs.create()

  new create(homeserver: Homeserver) =>
    _homeserver = homeserver

  be create_room(
    user_id: String,
    user: RoomMember tag,
    wanted: CreateRoomRequest,
    receiver: RoomCreationReceiver tag,
    watching: (User tag | None) = None)
  =>
    match wanted.alias
    | let alias: RoomAlias =>
      // Both maps, because there is one alias namespace and it is spread
      // across two. Checking only `_aliases` let an account take a
      // declared channel's name, after which that alias resolved to the
      // channel on the paths that ask `for_user` and to the squatter's
      // room on the paths that ask `_resolve` — and the public directory
      // listed both.
      let taken: String = alias.string()
      if _aliases.contains(taken) or _channels.contains(taken) then
        receiver.alias_taken()
        return
      end
    end

    match MakeRoomId(_homeserver.server_name)
    | let id: RoomId =>
      let room = Room(id)
      let key: String = id.string()
      _rooms(key) = room
      match wanted.alias
      | let alias: RoomAlias =>
        let text: String = alias.string()
        _aliases(text) = key
      end
      // An alias implies publication. An alias is a short name anyone may
      // resolve, so a room with one is reachable by anyone who guesses it
      // whether or not it is listed — listing it as well is honest rather
      // than a further disclosure.
      if wanted.published or (wanted.alias isnt None) then
        _published(key) = room
      end
      // The room answers, not this actor: only the room knows whether the
      // events that make it a room were written.
      room.created_by(user_id.clone(), user, wanted, receiver, watching)
    else
      // Fail closed. A room id is the only thing gating access to a room,
      // so there is no weaker one worth handing out.
      receiver.room_refused()
    end

  be declare(
    channel: BridgedChannel,
    network: BridgedNetwork,
    receiver: DeclaredChannelReceiver tag)
  =>
    """
    Record a channel an operator declared, so its alias can be entered.

    No room is made. A bridged channel is not a room — it is something a
    person can get a room for, and each gets their own, because a room is
    what one IRC session heard.

    Nothing is connected either. A channel with nobody in it has no
    connection, exactly as an IRC user who is not connected hears nothing,
    and the first Matrix user to enter is what opens one.
    """
    let alias: String = channel.alias.string()
    if _channels.contains(alias) or _aliases.contains(alias) then
      receiver.declaration_refused(channel.channel)
      return
    end

    _channels(alias) = (channel, network)
    receiver.channel_declared(channel, network)

  be with_room(room_id: String, receiver: RoomLookupReceiver tag) =>
    """
    Hand back the room a client named, or say there is none.

    An alias is accepted wherever an id is, because `/join` takes a
    `roomIdOrAlias` and has since it was written — until now that name was
    half true, and a client joining by the name it had been shown got a
    404.
    """
    try
      receiver.room_found(_rooms(_resolve(room_id))?)
    else
      receiver.room_missing()
    end

  be resolve_alias(alias: String, receiver: AliasReceiver tag) =>
    """
    Answer which room an alias names.

    A plain alias names one room and always the same one. A bridged
    channel's alias names a different room for every person who asks,
    which is why this takes no user: it answers only for the first kind,
    and `for_user` answers the second.
    """
    try
      receiver.alias_resolved(_aliases(alias)?)
    else
      receiver.alias_unknown()
    end

  be for_user(
    alias: String,
    user_id: String,
    receiver: BridgedRoomReceiver tag)
  =>
    """
    Hand back this person's own room for a bridged channel, making it if
    they have none.

    One room per person per channel. Two people who enter the same channel
    hold two rooms and see each other through IRC — as their far-side
    nicknames, over the round trip — which is what two people on IRC from
    different clients see of one another anyway.
    """
    (let channel: BridgedChannel, let network: BridgedNetwork) =
      try
        _channels(alias)?
      else
        receiver.no_such_channel()
        return
      end

    // The room they already hold, if they hold one. Looked up on its own
    // rather than inside the same `try` as the channel: a single `try`
    // around both meant any failure fell through to minting, and a second
    // room for the same person is a room their connection is not in.
    let key: String = alias + " " + user_id
    try
      receiver.bridged_room(_theirs(key)?, network)
      return
    end

    let id =
      match MakeRoomId(_homeserver.server_name)
      | let minted: RoomId => minted
      else
        // Not `no_such_channel`: the channel is declared and the alias is
        // good. What failed is this server.
        receiver.no_room_made()
        return
      end

    let room = Room(id)
    let room_key: String = id.string()
    _rooms(room_key) = room
    _theirs(key) = room
    // Not published: a room only its owner may enter has no place in a
    // directory everyone reads. The channel is what the directory
    // advertises, and it is advertised by its alias rather than by a room.
    //
    // Created by the person it belongs to. Only they and the channel's
    // participants are ever in it, and every other identity available
    // here names an account nobody can sign in to.
    //
    // The asker is answered by the declaration rather than here, so a
    // room that could not be written is not handed over as though it had.
    room.declared(
      user_id,
      CreateRoomRequest(channel.room_name, channel.alias, false),
      channel,
      network,
      _DeclaredThen(receiver, room))

  be channels(receiver: ChannelListReceiver tag) =>
    """
    Every declared channel, for the directory to advertise.
    """
    let found = recover iso Array[BridgedChannel] end
    for (channel, _) in _channels.values() do
      found.push(channel)
    end
    receiver.channels_listed(consume found)

  be published(receiver: PublishedRoomsReceiver tag) =>
    """
    Every room in the public directory.

    Handed out as tags for the caller to ask each in turn, rather than
    summarised here: this actor is the one shared thing on the paths that
    name a room, and holding a copy of every room's name would be a second
    account of it that could disagree with the room's own.
    """
    let found = recover iso Array[Room tag] end
    for room in _published.values() do
      found.push(room)
    end
    receiver.rooms_published(consume found)

  fun _resolve(named: String): String =>
    """
    The room id a client named, whether it gave an id or an alias.
    """
    try
      _aliases(named)?
    else
      named
    end
