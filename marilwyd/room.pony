use "collections"
use "json"
use "time"

actor Room
  """
  One room: who is in it, what its state says, and nothing else.

  It stores no messages. An event is fanned out to the members' `User`
  actors as it arrives and is not kept, so a client that was not a member
  when it was sent will never see it, and one that leaves and rejoins is
  told nothing about the gap.

  If replaying history to a rejoiner is ever wanted, it belongs to a
  separate actor that subscribes to rooms as any member does. Putting a log
  here would make every room pay for something only some rooms want, and
  would put the memory back that the per-device queues exist to bound.
  """
  let _state: RoomState
  embed _members: Map[String, User tag] = _members.create()
  var _position: USize = 0

  new create(id': RoomId) =>
    _state = RoomState(id')

  be created_by(
    user_id: String,
    user: User tag,
    wanted: CreateRoomRequest,
    receiver: RoomCreationReceiver tag)
  =>
    """
    Write the events that make a room a room, admit its creator, and only
    then say the room exists.

    The room answers rather than the directory, because the directory
    cannot see whether this succeeded. `_append` mints an event id and
    answers `None` when the CSPRNG refuses; ignoring that produced a room
    with no `m.room.create` event and a `200` telling the client it had
    been made — success reported by silence, of exactly the kind a room id
    being the whole access control makes worth reporting.

    No test covers the refusal: it needs the CSPRNG to fail, and
    `MakeEventId` reaches `ssl/crypto` with no seam to fail it through.
    Mutation confirms as much — deleting this branch changes nothing any
    test can see. It is here because the failure is real, not because it
    is observed, and a seam would have to be cut once for all four `Make*`
    primitives rather than for this one.
    """
    match _write_room(user_id, wanted)
    | None =>
      receiver.room_refused()
      return
    end

    _admit(user_id, user)
    receiver.room_created(_state.id)

  fun ref _write_room(user_id: String, wanted: CreateRoomRequest)
    : (EventId | None)
  =>
    """
    The events that make a room a room, shared by the two ways one is made.

    Answers `None` when any of them could not be written, which is the
    CSPRNG refusing an event id. Every caller stops there: a room missing
    its `m.room.create` is not a room.
    """
    let created =
      match _append(
        user_id,
        "m.room.create",
        "{\"creator\":" + _quoted(user_id) + "}",
        "")
      | let id: EventId => id
      else
        return None
      end

    match wanted.name
    | let n: String =>
      match _append(
        user_id, "m.room.name", "{\"name\":" + _quoted(n) + "}", "")
      | None => return None
      end
    end

    // Written as state so a client renders `#pony:server` beside the room
    // rather than a room id. The directory's map is what resolves an
    // alias; this event is what makes the room say it has one, and the two
    // are written together or not at all.
    match wanted.alias
    | let a: RoomAlias =>
      let text: String = a.string()
      match _append(
        user_id,
        "m.room.canonical_alias",
        "{\"alias\":" + _quoted(text) + "}",
        "")
      | None => return None
      end
    end

    created

  be declared(
    creator: String,
    wanted: CreateRoomRequest,
    channel: BridgedChannel,
    receiver: DeclaredRoomReceiver tag)
  =>
    """
    Write the events that make a declared room a room, and admit nobody.

    `created_by` cannot serve here: it admits its creator, and a room
    declared at startup has no member to admit — the account it is created
    on behalf of is the bridge, which has no `User` actor until it
    connects.
    """
    match _write_room(creator, wanted)
    | None =>
      receiver.declaration_refused(channel.channel)
      return
    end
    receiver.room_declared(channel, _state.id, this)

  be join(user_id: String, user: User tag, receiver: MembershipReceiver tag) =>
    """
    Admit a member. Joining a room you are already in changes nothing and
    succeeds, as the specification requires — appending a second identical
    membership would wake every member to say nothing.
    """
    if not _state.is_member(user_id) then
      _admit(user_id, user)
    end
    receiver.membership_changed(_state.id)

  be leave(user_id: String, receiver: MembershipReceiver tag) =>
    if _state.is_member(user_id) then
      _append(user_id, "m.room.member", "{\"membership\":\"leave\"}", user_id)
      _state.leave(user_id)
      try
        (_, let user: User tag) = _members.remove(user_id)?
        user.departed(_state.id.string())
      end
    end
    receiver.membership_changed(_state.id)

  be admit_ghost(user_id: String, display: String) =>
    """
    Record a far-side participant as a member, with nothing to deliver to.

    Membership without a delivery target, which is the distinction that lets
    a bridge exist at all: an IRC user has to be a member for `send` to
    accept anything from them and for a client to render their name, but
    there is no device anywhere to hand their own words back to.

    Admitted on first speech and never parted. Mirroring joins and parts
    would fan a membership event to every device for every join, part and
    quit on a busy channel, and grow the room's permanently-kept state by
    one entry per nickname ever seen rather than per nickname ever heard.
    """
    if not _state.is_member(user_id) then
      _state.join(user_id)
      // The display name is the name as its owner spells it, while the user
      // id is the folded, escaped form. A client shows the first and
      // addresses the second, which is why both travel.
      _append(
        user_id,
        "m.room.member",
        "{\"membership\":\"join\",\"displayname\":"
          + _quoted(display) + "}",
        user_id)
    end

  be send(
    user_id: String,
    kind: String,
    content: String,
    receiver: EventReceiver tag)
  =>
    """
    Fan one event out to every member. Refused for anyone who is not one.
    """
    if not _state.is_member(user_id) then
      receiver.event_refused(NotInRoom)
      return
    end
    match _append(user_id, kind, content, None)
    | let id: EventId => receiver.event_sent(id)
    else
      receiver.event_refused(NoEventId)
    end

  be describe(device: Device tag) =>
    """
    Tell one device what this room currently is, so a fresh sync can render
    it without asking every room in turn.
    """
    let id: String = _state.id.string()
    device.room_state(id, _state.state_events())

  be summarise(receiver: RoomSummaryReceiver tag) =>
    """
    Describe this room for the public directory.

    Answered by the room rather than cached anywhere, so there is one
    account of what a room is called and how many people are in it. The
    cost is one message per published room per directory request, and a
    directory request is a person clicking Explore.
    """
    receiver.room_summarised(
      RoomSummary(
        _state.id,
        _NameIn(_state.content_of("m.room.name")),
        _NameIn(_state.content_of("m.room.canonical_alias"), "alias"),
        _state.size()))

  be state(user_id: String, receiver: StateReceiver tag) =>
    if _state.is_member(user_id) then
      receiver.state_listed(_state.state_events())
    else
      receiver.state_refused(NotInRoom)
    end

  fun ref _admit(user_id: String, user: User tag) =>
    """
    Add a member, and tell them so.

    The order matters and used to be wrong. `_append` fans out to the
    members as they stand, so appending the membership event before adding
    the joiner told everyone in the room that somebody had joined except
    the person joining — and a client that already held a sync position
    learned nothing about the room it had just been let into.
    """
    _state.join(user_id)
    _members(user_id) = user
    _append(user_id, "m.room.member", "{\"membership\":\"join\"}", user_id)
    user.joined(_state.id.string(), this)

  fun ref _append(
    user_id: String,
    kind: String,
    content: String,
    state_key: (String | None))
    : (EventId | None)
  =>
    let id =
      match MakeEventId()
      | let e: EventId => e
      else
        return None
      end

    // `Time.now()` and never `Time.millis()`: the latter is monotonic time
    // since boot, so it would date every message to 1970 plus the server's
    // uptime.
    (let sec: I64, let nsec: I64) = Time.now()
    let event =
      RoomEvent(
        id,
        _state.id,
        // Cloned because it came from a request and this actor outlives
        // the handler that read it. A stored foreign reference would keep
        // that handler, its connection and its request body alive.
        kind.clone(),
        user_id.clone(),
        (sec * 1000) + (nsec / 1_000_000),
        content.clone(),
        match state_key
        | let k: String => k.clone()
        end,
        _position)

    _position = _position + 1
    _state.apply_state(event)

    for user in _members.values() do
      user.deliver(event)
    end

    id

  fun _quoted(text: String): String =>
    """
    A JSON string. Built here rather than by concatenation elsewhere so
    nothing assembles a document out of unescaped client text.
    """
    JsonPrinter.print(text)
