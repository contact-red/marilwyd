use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"
use uri = "uri"

primitive MaxEventBody
  """
  The largest event body marilwyd will read.

  Below `ServerLimits`' transport cap on purpose. If the two were equal,
  stallion would refuse an oversized body first — with a bodiless `413`
  carrying no `errcode` — and this limit's refusal could never fire.
  `MaxLoginBody` sits a sixteenth below the transport cap for the same
  reason.
  """
  fun apply(): USize => 32_768

primitive MaxEventDepth
  """
  How deeply an event's content may nest.

  Lower than a login's, because event content is a flat map of a handful of
  fields in every event Matrix defines. The size limit bounds one body's
  cost; this bounds its shape, so the parser's frame count stops following
  the byte count.
  """
  fun apply(): USize => 8

primitive _CreateRoomWanted
  """
  Read a `createRoom` body for the three things marilwyd honours.

  `name` is text a client shows. `room_alias_name` becomes the room's
  alias, and an alias is a name anyone may resolve into a room id — so it
  is validated here rather than stored as sent. `visibility` decides
  whether the room is listed in the public directory.

  Everything else a client sends is dropped, and `README.md` says which.
  `preset`, in particular, is read for nothing: no preset implies
  encryption, and the access controls the others describe are ones this
  server does not enforce.
  """
  fun apply(body: Array[U8] val, server_name: String)
    : (CreateRoomRequest | InvalidAlias)
  =>
    let sent =
      match JsonParser.parse(String.from_array(body))
      | let o: JsonObject => o
      else
        return CreateRoomRequest(None, None, false)
      end

    let name: (String | None) =
      match sent.get_or_else("name", None)
      | let n: String => n.clone()
      end

    let alias: (RoomAlias | None) =
      match sent.get_or_else("room_alias_name", None)
      | let wanted: String =>
        match \exhaustive\ RoomAliases.make(wanted, server_name)
        | let a: RoomAlias => a
        | let why: InvalidAlias => return why
        end
      end

    let published =
      match sent.get_or_else("visibility", None)
      | let asked: String => asked == "public"
      else
        false
      end

    CreateRoomRequest(name, alias, published)

primitive MaxCreateBody
  """
  The largest `createRoom` request marilwyd will read.

  This endpoint had no bound at all — it was the one body-reading path
  without one, parsing up to the transport cap. A create request is a
  handful of short fields plus whatever initial state a client asks for,
  and Element's is under a kilobyte.
  """
  fun apply(): USize => 8192

primitive MaxCreateDepth
  """
  How deeply a `createRoom` request may nest.

  A create request's deepest legitimate shape is its `initial_state`
  array, the event in it, that event's content, and that content's
  values — four. This is generous against that while keeping the parser's
  frame count independent of how the bytes are spent.
  """
  fun apply(): USize => 8

primitive _PathParam
  """
  Pull a decoded path parameter out of a matched route.

  hobby hands back the raw segment — verified: it builds params with
  `trim`, which also aliases the request path's memory — so a room id
  arrives percent-encoded, as every client sends it.
  """
  fun apply(params: Map[String, String] val, name: String)
    : (String | None)
  =>
    let raw = params.get_or_else(name, "")
    if raw.size() == 0 then
      return None
    end
    match \exhaustive\ uri.PercentDecode(raw)
    | let decoded: String val => decoded
    | let _: uri.InvalidPercentEncoding val => None
    end

primitive _EventContent
  """
  Validate a client's event body and print it back.

  Printing rather than passing the parsed object: a `JsonObject` has no
  deep copy, so one built here would pin this handler, its connection and
  its request body for as long as any device held the event. Text is
  copyable, and `JsonPrinter` does the escaping so nothing downstream
  assembles a document out of client text.
  """
  fun apply(body: Array[U8] val)
    : (String | MalformedEvent | EventTooDeep)
  =>
    if body.size() > MaxEventBody() then
      return MalformedEvent
    end
    // `MaxEventDepth` was declared with this reasoning and then never
    // applied to anything, so the shape half of the bound did not exist
    // until now — only the byte half did.
    if _JSONDeeperThan(body, MaxEventDepth()) then
      return EventTooDeep
    end
    match JsonParser.parse(String.from_array(body))
    | let o: JsonObject => JsonPrinter.print(o)
    else
      MalformedEvent
    end

primitive MalformedEvent
  """
  An event body that is not a JSON object, or is larger than one may be.
  """
  fun message(): String => "Event content must be a JSON object"

primitive EventTooDeep
  """
  An event body nested deeper than `MaxEventDepth()`, whatever its length.

  Its own refusal rather than sharing `MalformedEvent`'s: a client whose
  content is not an object and a client whose content nests too far have
  different things to fix, and one message for two causes is the fault
  `MalformedSyncTimeout` was split to remove.
  """
  fun message(): String =>
    "Event content is nested more deeply than an event may be"

class val _CreateRoom
  """
  `POST /_matrix/client/v3/createRoom`.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag
  let _homeserver: Homeserver

  new val create(
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    homeserver: Homeserver)
  =>
    _sessions = sessions
    _rooms = rooms
    _homeserver = homeserver

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _CreateRoomHandler(consume ctx, _sessions, _rooms, _homeserver)

actor _CreateRoomHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomCreationReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _server_name: String
  let _body: Array[U8] val

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    homeserver: Homeserver)
  =>
    let supplied = _BearerToken(ctx.request)
    _body = ctx.body
    _rooms = rooms
    _server_name = homeserver.server_name
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    // Only `name` is read. Element also sends `preset`, `join_rules` and
    // `m.room.encryption`, none of which marilwyd implements — a room is
    // always unencrypted and always joinable by anyone holding its id, and
    // `README.md` says so rather than letting a client's padlock lie.
    if _body.size() > MaxCreateBody() then
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_TOO_LARGE", "That is larger than a create request"))
    elseif _JSONDeeperThan(_body, MaxCreateDepth()) then
      _respond(
        stallion.StatusBadRequest,
        MatrixError(
          "M_BAD_JSON",
          "That is nested more deeply than a create request may be"))
    else
      match \exhaustive\ _CreateRoomWanted(_body, _server_name)
      | let wanted: CreateRoomRequest =>
        _rooms.create_room(
          session.user_id, session.user, wanted, this, session.user)
      | let why: InvalidAlias =>
        _respond(
          stallion.StatusBadRequest,
          MatrixError("M_INVALID_PARAM", why.string()))
      end
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_created(room: RoomId) =>
    _respond(stallion.StatusOK, RoomCreated(room))

  be alias_taken() =>
    _respond(
      stallion.StatusConflict,
      MatrixError("M_ROOM_IN_USE", "That alias is already in use"))

  be room_refused() =>
    _respond(
      stallion.StatusInternalServerError,
      MatrixError("M_UNKNOWN", NoSecureRandom.string()))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _JoinRoom
  """
  `POST /_matrix/client/v3/join/{roomIdOrAlias}`.

  This spelling and not `/rooms/{roomId}/join`: matrix-js-sdk builds the
  former and has no call site for the latter, which is the same trap that
  once put `DELETE /devices/{deviceId}` in this server for no client.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag
  let _links: LinkDirectory tag
  let _homeserver: Homeserver

  new val create(
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    links: LinkDirectory tag,
    homeserver: Homeserver)
  =>
    _sessions = sessions
    _rooms = rooms
    _links = links
    _homeserver = homeserver

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _MembershipHandler(
      consume ctx, _sessions, _rooms, _links, _homeserver, true)

class val _LeaveRoom
  """
  `POST /_matrix/client/v3/rooms/{roomId}/leave`.

  Leaving matters more here than in most homeservers: a room fans out to
  its members, so a member who never leaves is woken for every message in
  a room they have stopped caring about, forever.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag
  let _links: LinkDirectory tag
  let _homeserver: Homeserver

  new val create(
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    links: LinkDirectory tag,
    homeserver: Homeserver)
  =>
    _sessions = sessions
    _rooms = rooms
    _links = links
    _homeserver = homeserver

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _MembershipHandler(
      consume ctx, _sessions, _rooms, _links, _homeserver, false)

actor _MembershipHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver
    & MembershipReceiver & BridgeReceiver & JoinReceiver
    & BridgedRoomReceiver)
  """
  Joining and leaving, which differ only in which behaviour they call —
  except that joining a bridged room is not marilwyd's business alone.

  Entering one means holding an IRC connection under that person's own
  nickname, so the join opens one and answers only once the channel has
  been entered. A network that refuses is a Matrix room the client does
  not enter: membership means connected on both sides, which is what makes
  a half-joined state unrepresentable rather than merely unlikely.
  """
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _links: LinkDirectory tag
  let _homeserver: Homeserver
  let _params: Map[String, String] val
  let _joining: Bool
  var _session: (Session | None) = None
  var _room: (Room tag | None) = None

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    links: LinkDirectory tag,
    homeserver: Homeserver,
    joining: Bool)
  =>
    let supplied = _BearerToken(ctx.request)
    // Captured raw. Decoding before the token is checked would let an
    // unauthenticated caller drive a percent-decode, which is the rule
    // `_SyncHandler` states and two tests pin.
    _params = ctx.params
    _joining = joining
    _rooms = rooms
    _links = links
    _homeserver = homeserver
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    _session = session
    let named = if _joining then "roomIdOrAlias" else "roomId" end
    match \exhaustive\ _PathParam(_params, named)
    | let id: String =>
      // A bridged channel's alias names a different room for every person
      // who enters it, so it is asked about before the room table: a room
      // id names one room, and this may name a channel instead.
      if _joining then
        _rooms.for_user(id, session.user_id, this)
      else
        _rooms.with_room(id, this)
      end
    else
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room identifier"))
    end

  be bridged_room(room: Room tag, network: BridgedNetwork) =>
    """
    This person's own room for the channel they named. Entering it means
    a connection, which is what `room_is_bridged` goes on to open.
    """
    _room = room
    room.bridged(this)

  be no_room_made() =>
    """
    The channel exists and its room could not be written, which is this
    server's failure and not the client's.
    """
    _respond(
      stallion.StatusInternalServerError,
      MatrixError(
        "M_UNKNOWN",
        "The room for that channel could not be created"))

  be no_such_channel() =>
    // Not a channel, so it may still be an ordinary room id or alias.
    match \exhaustive\ _PathParam(_params, "roomIdOrAlias")
    | let id: String => _rooms.with_room(id, this)
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room identifier"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_found(room: Room tag) =>
    _room = room
    match _session
    | let s: Session =>
      // Asked either way: a join needs a connection opened before it can
      // succeed, and a leave needs one closed after it does.
      room.bridged(this)
    end

  be room_is_local() =>
    match (_session, _room)
    | (let s: Session, let room: Room tag) =>
      if _joining then
        room.join(s.user_id, s.user, this, s.user)
      else
        room.leave(s.user_id, this)
      end
    end

  be room_is_bridged(channel: BridgedChannel, network: BridgedNetwork) =>
    match (_session, _room)
    | (let s: Session, let room: Room tag) =>
      if _joining then
        _links.open(s.user_id, channel, network, room, this)
      else
        // Leaving closes the connection, which is what makes membership
        // and being on the channel the same fact rather than two that can
        // disagree.
        _links.close(s.user_id, channel.channel, network.name)
        room.leave(s.user_id, this)
      end
    end

  be joined_with(channel: String, link: UserLink tag) =>
    """
    The channel was entered, and this is the connection that entered it.

    The room takes the connection as what carries this member's words
    outward, and then the member joins — in that order, so a message sent
    the instant after the join has somewhere to go.
    """
    match (_session, _room)
    | (let s: Session, let room: Room tag) =>
      room.join(s.user_id, s.user, this, s.user)
      room.carry(s.user_id, link)
    end

  be join_refused(channel: String) =>
    // The far side would not have them, so neither will the room. A client
    // that cannot reach the channel is not a member of a room whose whole
    // content comes from it.
    _respond(
      stallion.StatusForbidden,
      MatrixError(
        "M_FORBIDDEN",
        "marilwyd could not join " + channel + " for you"))

  be room_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", NoSuchRoom.message()))

  be membership_changed(room: RoomId) =>
    _respond(stallion.StatusOK, RoomCreated(room))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _SendEvent
  """
  `PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`.

  `txnId` is routed and not read. Matrix defines it as an idempotency key,
  so a client that retries after a timeout sends the message twice. That is
  a deviation worth recording rather than hiding: deduplicating needs a
  per-device map with an eviction policy, and the first observed duplicate
  is the trigger for building one.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _SendEventHandler(consume ctx, _sessions, _rooms)

actor _SendEventHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver & EventReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _params: Map[String, String] val
  let _body: Array[U8] val
  var _session: (Session | None) = None
  var _kind: String = ""
  var _content: String = ""

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag)
  =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _body = ctx.body
    _rooms = rooms
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    _session = session

    match \exhaustive\ _EventContent(_body)
    | let printed: String => _content = printed
    | MalformedEvent =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedEvent.message()))
      return
    | EventTooDeep =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", EventTooDeep.message()))
      return
    end

    match \exhaustive\ (_PathParam(_params, "roomId"),
      _PathParam(_params, "eventType"))
    | (let id: String, let kind: String) =>
      _kind = kind
      _rooms.with_room(id, this)
    else
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room or event type"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_found(room: Room tag) =>
    match _session
    | let s: Session => room.send(s.user_id, _kind, _content, this)
    end

  be room_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", NoSuchRoom.message()))

  be event_sent(id: EventId) =>
    _respond(stallion.StatusOK, EventSent(id))

  be event_refused(why: (NotInRoom | NoEventId | BridgeDown)) =>
    match \exhaustive\ why
    | NotInRoom =>
      _respond(
        stallion.StatusForbidden,
        MatrixError("M_FORBIDDEN", NotInRoom.message()))
    | NoEventId =>
      _respond(
        stallion.StatusInternalServerError,
        MatrixError("M_UNKNOWN", NoEventId.message()))
    | BridgeDown =>
      // 502, because the failure is a server marilwyd depends on rather
      // than anything the client did. `M_UNKNOWN` for the errcode: the
      // specification has no code for this, and inventing one a client
      // cannot look up would say less than the message does.
      _respond(
        stallion.StatusBadGateway,
        MatrixError("M_UNKNOWN", BridgeDown.message()))
    end

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive AllState
  """
  Ask a room for every current state event.
  """
  fun apply(room: Room tag, user_id: String, receiver: StateReceiver tag) =>
    room.state(user_id, receiver)

  fun render(events: Array[RoomEvent] val): String =>
    StateEvents(events)

primitive MembersOnly
  """
  Ask a room for its membership alone.

  Its own reading rather than a filter over `AllState`: a client asking who
  is in a room should not be answered by sending it every state event and
  hoping it discards the rest, and on a bridged channel the difference is
  one map lookup against walking everything the room has ever recorded.
  """
  fun apply(room: Room tag, user_id: String, receiver: StateReceiver tag) =>
    room.members(user_id, receiver)

  fun render(events: Array[RoomEvent] val): String =>
    RoomMembers(events)

type _StateReading is (AllState | MembersOnly)
  """
  Which of a room's two readings a handler is serving.

  Two endpoints that differ in one call and one rendering, so this is what
  they differ by rather than two handlers alike in fifty lines.
  """

class val _RoomState
  """
  `GET /_matrix/client/v3/rooms/{roomId}/state`, and `/members`.

  The only things a room can answer about its past, because it keeps no
  messages — current state is not history.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag
  let _reading: _StateReading

  new val create(
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    reading: _StateReading = AllState)
  =>
    _sessions = sessions
    _rooms = rooms
    _reading = reading

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _RoomStateHandler(consume ctx, _sessions, _rooms, _reading)

actor _RoomStateHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver & StateReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _params: Map[String, String] val
  let _reading: _StateReading
  var _session: (Session | None) = None

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    reading: _StateReading)
  =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _rooms = rooms
    _reading = reading
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    _session = session
    match \exhaustive\ _PathParam(_params, "roomId")
    | let id: String => _rooms.with_room(id, this)
    else
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room identifier"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_found(room: Room tag) =>
    match _session
    | let s: Session =>
      match \exhaustive\ _reading
      | AllState => AllState(room, s.user_id, this)
      | MembersOnly => MembersOnly(room, s.user_id, this)
      end
    end

  be room_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", NoSuchRoom.message()))

  be state_listed(events: Array[RoomEvent] val) =>
    let body =
      match \exhaustive\ _reading
      | AllState => AllState.render(events)
      | MembersOnly => MembersOnly.render(events)
      end
    _respond(stallion.StatusOK, body)

  be state_refused(why: NotInRoom) =>
    _respond(
      stallion.StatusForbidden,
      MatrixError("M_FORBIDDEN", NotInRoom.message()))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
