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

  new create(homeserver: Homeserver) =>
    _homeserver = homeserver

  be create_room(
    user_id: String,
    user: User tag,
    wanted: CreateRoomRequest,
    receiver: RoomCreationReceiver tag)
  =>
    match wanted.alias
    | let alias: RoomAlias =>
      let taken: String = alias.string()
      if _aliases.contains(taken) then
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
      room.created_by(user_id.clone(), user, wanted, receiver)
    else
      // Fail closed. A room id is the only thing gating access to a room,
      // so there is no weaker one worth handing out.
      receiver.room_refused()
    end

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
    """
    try
      receiver.alias_resolved(_aliases(alias)?)
    else
      receiver.alias_unknown()
    end

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
