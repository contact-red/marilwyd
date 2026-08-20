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
  // Invited, which is not a member: an invitation is permission to join
  // and nothing else. Someone holding one may not send, may not read what
  // is said, and is not fanned out to — they are told the room exists and
  // enough about it to decide.
  embed _invited: Set[String] = _invited.create()

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
    // An invitation is spent by being accepted. Left set, the room would
    // go on offering a room its holder is already in.
    try
      _invited.extract(user_id)?
    end

  fun ref invite(user_id: String) =>
    """
    Record that somebody may join, without admitting them.
    """
    _invited.set(user_id)

  fun is_invited(user_id: String): Bool =>
    _invited.contains(user_id)

  fun ref withdraw(user_id: String) =>
    """
    Drop an invitation that was refused, or that its holder left behind.
    """
    try
      _invited.extract(user_id)?
    end

  fun open(): Bool =>
    """
    Whether anyone who can name this room may enter it.

    Read from the room's own state rather than held beside it, so there is
    one answer and a client reading `m.room.join_rules` is reading what is
    enforced. A room with no rule written is closed: the rooms that have
    none are the ones from before the rule existed, and refusing is the
    answer that cannot leak one.
    """
    match content_of("m.room.join_rules")
    | let content: String => content.contains("\"public\"")
    else
      false
    end

  fun ref leave(user_id: String) =>
    """
    Remove a member or an invitation, and the event that named them.

    Both, in one call, because membership is recorded twice here — as the
    member set and as an `m.room.member` slot — and a caller that updated
    one would leave the room disagreeing with itself. It did: `leave` took
    the set and `apply_state` took the slot, so a departure removed
    somebody from the room while `/members` and every fresh sync went on
    listing them. On a bridged channel, where the people arriving are
    strangers naming themselves, that grew by one permanent entry per
    nickname ever seen and never shrank.

    Removing the slot rather than leaving it set to `"leave"` is also what
    this server already says it does — it keeps no history, so a
    membership it retains is a claim about the present, and a leave is the
    absence of one.
    """
    try
      _members.extract(user_id)?
    end
    try
      _invited.extract(user_id)?
    end
    try
      (_, _) = _state("m.room.member")?.remove(user_id)?
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

  fun member_events(): Array[RoomEvent] val =>
    """
    The current membership of the room, one event per member.

    A keyed read rather than a filter over everything: `_state` is already
    grouped by kind, so this is the slot for `m.room.member` and nothing
    else is visited. On a bridged channel that is the difference between
    touching one map and walking every state event in the room.
    """
    let found = recover iso Array[RoomEvent] end
    try
      for event in _state("m.room.member")?.values() do
        found.push(event)
      end
    end
    consume found

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
