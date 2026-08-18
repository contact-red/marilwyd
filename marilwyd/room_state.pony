use "collections"

class ref RoomState
  """
  What a room is: who is in it, and what its current state says.

  **No messages.** A room fans an event out to its members and keeps
  nothing — a client that was not a member when an event was sent will
  never see it, and one that leaves and rejoins is told nothing about the
  gap. Anything held for a disconnected member is held by that member, not
  here.

  If replaying history to a rejoiner is ever wanted, it belongs to a
  different actor that subscribes to rooms like any other member. Adding a
  log here would make every room pay for a feature only some rooms want.

  State is separate from that rule and is kept: a member joining needs the
  room's name and membership to render it at all, and current state is not
  history.

  No actor and no clock, so every rule here is reachable from a test.
  """
  let id: RoomId
  embed _state: Map[String, Map[String, RoomEvent]] = _state.create()
  embed _members: Set[String] = _members.create()

  new ref create(id': RoomId) =>
    id = id'

  fun ref apply_state(event: RoomEvent) =>
    """
    Record a state event, if it is one. Last write wins.
    """
    match event.state_key
    | let key: String =>
      let slots =
        try
          _state(event.kind)?
        else
          let fresh = Map[String, RoomEvent]
          _state(event.kind) = fresh
          fresh
        end
      slots(key) = event
    end

  fun ref join(user_id: String) =>
    _members.set(user_id)

  fun ref leave(user_id: String) =>
    try
      _members.extract(user_id)?
    end

  fun is_member(user_id: String): Bool =>
    _members.contains(user_id)

  fun members(): Array[String] val =>
    let found = recover iso Array[String] end
    for who in _members.values() do
      found.push(who)
    end
    consume found

  fun content_of(kind: String, key: String = ""): (String | None) =>
    """
    The content of one current state event, looked up rather than scanned.

    A keyed read because the callers that want one — the room's name for a
    directory listing, its alias, whether it is encrypted — ask about a
    single event and would otherwise walk every membership in the room to
    find it.
    """
    try
      return _state(kind)?(key)?.content
    end
    None

  fun size(): USize =>
    """
    How many members the room has. What a public directory listing shows,
    and the one number about a room a stranger may read before joining.
    """
    _members.size()

  fun state_events(): Array[RoomEvent] val =>
    """
    Every current state event. What a joining member is sent so the room is
    renderable, and the only thing a room can answer about its past.
    """
    let found = recover iso Array[RoomEvent] end
    for slots in _state.values() do
      for event in slots.values() do
        found.push(event)
      end
    end
    consume found
