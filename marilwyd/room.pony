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
  // The channel this room is, when it is bridged. A room holds it because
  // joining one has to open a connection before it can answer, and the
  // handler that answers has no other way to learn there is one.
  var _bridge: (BridgedChannel | None) = None
  var _network: (BridgedNetwork | None) = None
  // `RoomMember`, not `User`: a bridged user's own IRC connection is a
  // member of the room the same way their account is, and the room does
  // not distinguish them.
  embed _members: Map[String, RoomMember tag] = _members.create()
  // A member's own connection outward, when they have one. Keyed by the
  // member it belongs to rather than held as a member, because it is not
  // another participant — it is the same person, reachable from the other
  // side.
  embed _carrying: Map[String, RoomMember tag] = _carrying.create()
  // Whose carrier is not currently carrying. A member is in `_carrying`
  // from the moment their connection is made and in here whenever that
  // connection cannot reach the network, which are different questions:
  // the first says who to fan out to, the second says whether doing so
  // would accomplish anything.
  embed _stalled: Set[String] = _stalled.create()
  var _position: USize = 0
  // Read positions and who is typing. Not in `RoomState`, which is what a
  // room *is* — these are what it is doing at one moment, they are never
  // events in its timeline, and nothing about them is kept when the
  // process ends.
  // Only Matrix accounts, not every member. Ephemeral state is Matrix's
  // own bookkeeping — an IRC connection has no reading for a read receipt
  // and no way to show one — so a bridged member is a member for events
  // and absent from this.
  embed _watching: Map[String, User tag] = _watching.create()
  embed _receipts: Map[String, Receipt] = _receipts.create()
  embed _typing: Map[String, Bool] = _typing.create()

  new create(id': RoomId) =>
    _state = RoomState(id')

  be created_by(
    user_id: String,
    user: RoomMember tag,
    wanted: CreateRoomRequest,
    receiver: RoomCreationReceiver tag,
    watching: (User tag | None) = None)
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
    // The creator hears this room's ephemeral state for the same reason a
    // joiner does. Without it the one person certain to be in a room was
    // the one person never told who was typing in it.
    match watching
    | let account: User tag => _watching(user_id.clone()) = account
    end
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
    network: BridgedNetwork,
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
    _bridge = channel
    _network = network
    receiver.channel_declared(channel, network)

  be join(
    user_id: String,
    user: RoomMember tag,
    receiver: MembershipReceiver tag,
    watching: (User tag | None) = None)
  =>
    """
    Admit a member. Joining a room you are already in changes nothing and
    succeeds, as the specification requires — appending a second identical
    membership would wake every member to say nothing.
    """
    if not _state.is_member(user_id) then
      _admit(user_id, user)
    end
    // Only a Matrix account hears a room's ephemeral state — a bridged
    // user's IRC connection is a member and has no reading for a receipt.
    // Taken here rather than by a second call, so a caller cannot join
    // somebody and forget to.
    match watching
    | let account: User tag => _watching(user_id.clone()) = account
    end
    receiver.membership_changed(_state.id)

  be leave(user_id: String, receiver: MembershipReceiver tag) =>
    if _state.is_member(user_id) then
      _append(user_id, "m.room.member", "{\"membership\":\"leave\"}", user_id)
      _state.leave(user_id)
      try
        (_, let member: RoomMember tag) = _members.remove(user_id)?
        member.departed(_state.id.string())
      end
      try
        (_, _) = _watching.remove(user_id)?
      end
      try
        (_, let link: RoomMember tag) = _carrying.remove(user_id)?
        link.departed(_state.id.string())
      end
      _stalled.unset(user_id)
    end
    receiver.membership_changed(_state.id)

  be admit_ghost(user_id: String, display: String) =>
    """
    Record a far-side participant as a member, with nothing to deliver to.

    Membership without a delivery target, which is the distinction that lets
    a bridge exist at all: an IRC user has to be a member for `send` to
    accept anything from them and for a client to render their name, but
    there is no device anywhere to hand their own words back to.

    Idempotent, because a participant is admitted from more than one place:
    from the channel's own member list on entering it, from a later join,
    and from anything they say. The last is not redundancy — a name list
    can be missed and a netsplit can heal without one — and it is what
    keeps the room agreeing with the channel rather than with a single
    message that may not have arrived.
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

  be carrier_stalled(user_id: String) =>
    """
    This member's connection cannot reach the network at the moment.

    Their membership is untouched: a connection that drops and comes back
    is what a bouncer does, and parting somebody from a room over a
    netsplit would make a Matrix room noisier than the channel it mirrors.
    What changes is that `send` stops accepting from them, so nothing is
    recorded that the channel will never see.
    """
    if _carrying.contains(user_id) then
      _stalled.set(user_id)
    end

  be carrier_carrying(user_id: String) =>
    """
    This member's connection is on the channel again, so `send` accepts
    from them once more.
    """
    _stalled.unset(user_id)

  be part_ghost(user_id: String) =>
    """
    A far-side participant left the channel.

    The membership event is written and the member removed, so a client's
    list matches who is actually there. Only ghosts leave this way: a
    Matrix member leaves through `leave`, which also closes their
    connection.
    """
    if _state.is_member(user_id) then
      _append(user_id, "m.room.member", "{\"membership\":\"leave\"}", user_id)
      _state.leave(user_id)
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
    // Nothing is recorded while the sender's own connection is down. A
    // bridged room's content is that connection, so an event accepted
    // here would be answered with an id, shown to its author, and never
    // reach the channel they wrote it to.
    if _stalled.contains(user_id) then
      receiver.event_refused(BridgeDown)
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
        _state.id.string(),
        _NameIn(_state.content_of("m.room.name")),
        _NameIn(_state.content_of("m.room.canonical_alias"), "alias"),
        _state.size()))

  be read_up_to(user_id: String, event_id: String) =>
    """
    Record how far somebody has read, and tell the room.

    Last write wins per person: a read position is where they are now, not
    a history of where they have been. A receipt for an event this room
    never sent is stored anyway — marilwyd keeps no messages, so it cannot
    tell one from an event it has forgotten, and refusing would break a
    client that read something before a restart.
    """
    if not _state.is_member(user_id) then
      return
    end
    (let sec: I64, let nsec: I64) = Time.now()
    _receipts(user_id.clone()) =
      Receipt(
        user_id.clone(),
        event_id.clone(),
        (sec * 1000) + (nsec / 1_000_000))
    _publish()

  be typing(user_id: String, active: Bool) =>
    """
    Record whether somebody is typing, and tell the room.

    Bounded, and dropped rather than refused past the bound: a notice
    naming more people than anyone reads is worth less than the room
    continuing to deliver. Nothing here expires — a client says when it
    stops, and one that vanishes mid-sentence leaves its name until it
    comes back or the process ends.
    """
    if not _state.is_member(user_id) then
      return
    end
    if active then
      if (_typing.size() < MaxTypists()) or _typing.contains(user_id) then
        _typing(user_id.clone()) = true
      end
    else
      try
        (_, _) = _typing.remove(user_id)?
      end
    end
    _publish()

  fun ref _publish() =>
    """
    Hand every member's devices the room's current ephemeral state.

    The whole of it each time rather than what changed: it is small,
    last-write-wins, and a client that missed one has missed nothing the
    next does not carry. Sending a delta would need a per-device position
    for something that has no history.
    """
    let receipts = recover iso Array[Receipt] end
    for receipt in _receipts.values() do
      receipts.push(receipt)
    end
    let active = recover iso Array[String] end
    for who in _typing.keys() do
      active.push(who)
    end

    let current = Ephemeral(consume receipts, consume active)
    let id: String = _state.id.string()
    for user in _watching.values() do
      user.ephemeral(id, current)
    end

  be carry(user_id: String, link: RoomMember tag) =>
    """
    Take one member's outward connection.

    Not a member itself: it is the same person as the account that joined,
    seen from the other side, so it appears in no membership and in no
    listing. It receives what the room fans out and nothing else — which
    is what makes a Matrix user's words reach IRC without inventing a
    second participant to carry them.
    """
    if _state.is_member(user_id) then
      _carrying(user_id.clone()) = link
    end

  be identify(receiver: RoomIdReceiver tag) =>
    """
    Say which room this is.

    Needed because a bridged channel's alias resolves to a room actor
    before anyone knows its id — the directory hands back the room, and
    the id is the room's to give.
    """
    receiver.room_identified(_state.id)

  be bridged(receiver: BridgeReceiver tag) =>
    """
    Say which channel this room is, if it is one.

    Asked before a join, because a bridged room's membership means a live
    IRC connection and the handler cannot know to open one otherwise.
    """
    match (_bridge, _network)
    | (let channel: BridgedChannel, let network: BridgedNetwork) =>
      receiver.room_is_bridged(channel, network)
    else
      receiver.room_is_local()
    end

  be members(user_id: String, receiver: StateReceiver tag) =>
    """
    Answer who is in this room, to a member of it.

    Members only, like `state`: a room id is the whole of the access
    control, so anyone holding one may join and then read this — but
    reading it without joining would let somebody enumerate a room's
    membership from the id alone, which is a smaller thing to hold than a
    membership.
    """
    if _state.is_member(user_id) then
      receiver.state_listed(_state.member_events())
    else
      receiver.state_refused(NotInRoom)
    end

  be state(user_id: String, receiver: StateReceiver tag) =>
    if _state.is_member(user_id) then
      receiver.state_listed(_state.state_events())
    else
      receiver.state_refused(NotInRoom)
    end

  fun ref _admit(user_id: String, user: RoomMember tag) =>
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
    // And outward. A member's own connection never receives what that
    // member said — `UserLink` compares the sender — so nothing loops.
    for link in _carrying.values() do
      link.deliver(event)
    end

    id

  fun _quoted(text: String): String =>
    """
    A JSON string. Built here rather than by concatenation elsewhere so
    nothing assembles a document out of unescaped client text.
    """
    JsonPrinter.print(text)
