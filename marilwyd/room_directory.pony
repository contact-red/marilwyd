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

  new create(homeserver: Homeserver) =>
    _homeserver = homeserver

  be create_room(
    user_id: String,
    user: User tag,
    name: (String | None),
    receiver: RoomCreationReceiver tag)
  =>
    match MakeRoomId(_homeserver.server_name)
    | let id: RoomId =>
      let room = Room(id)
      let key: String = id.string()
      _rooms(key) = room
      // The room answers, not this actor: only the room knows whether the
      // events that make it a room were written.
      room.created_by(user_id.clone(), user, name, receiver)
    else
      // Fail closed. A room id is the only thing gating access to a room,
      // so there is no weaker one worth handing out.
      receiver.room_refused()
    end

  be with_room(room_id: String, receiver: RoomLookupReceiver tag) =>
    """
    Hand back the room a client named, or say there is none.
    """
    try
      receiver.room_found(_rooms(room_id)?)
    else
      receiver.room_missing()
    end
