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
  let _server_name: String
  embed _members: Map[String, User tag] = _members.create()
  var _position: USize = 0

  new create(id': RoomId, server_name: String) =>
    _state = RoomState(id')
    _server_name = server_name

  be created_by(user_id: String, user: User tag, name: (String | None)) =>
    """
    Write the events that make a room a room, then admit its creator.
    """
    _append(
      user_id,
      "m.room.create",
      "{\"creator\":" + _quoted(user_id) + "}",
      "")
    match name
    | let n: String =>
      _append(
        user_id, "m.room.name", "{\"name\":" + _quoted(n) + "}", "")
    end
    _admit(user_id, user)

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
    device.room_state(_state.state_events())

  be state(user_id: String, receiver: StateReceiver tag) =>
    if _state.is_member(user_id) then
      receiver.state_listed(_state.state_events())
    else
      receiver.state_refused(NotInRoom)
    end

  fun ref _admit(user_id: String, user: User tag) =>
    _append(user_id, "m.room.member", "{\"membership\":\"join\"}", user_id)
    _state.join(user_id, _position)
    _members(user_id) = user
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
