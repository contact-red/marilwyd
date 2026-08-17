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
  fun apply(body: Array[U8] val): (String | MalformedEvent) =>
    if body.size() > MaxEventBody() then
      return MalformedEvent
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

class val _CreateRoom
  """
  `POST /_matrix/client/v3/createRoom`.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _CreateRoomHandler(consume ctx, _sessions, _rooms)

actor _CreateRoomHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomCreationReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _body: Array[U8] val

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag)
  =>
    let supplied = _BearerToken(ctx.request)
    _body = ctx.body
    _rooms = rooms
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
    let name =
      match JsonParser.parse(String.from_array(_body))
      | let o: JsonObject =>
        match o.get_or_else("name", None)
        | let n: String => n
        end
      end
    _rooms.create_room(session.user_id, session.user, name, this)

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_created(room: RoomId) =>
    _respond(stallion.StatusOK, RoomCreated(room))

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

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _MembershipHandler(consume ctx, _sessions, _rooms, true)

class val _LeaveRoom
  """
  `POST /_matrix/client/v3/rooms/{roomId}/leave`.

  Leaving matters more here than in most homeservers: a room fans out to
  its members, so a member who never leaves is woken for every message in
  a room they have stopped caring about, forever.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _MembershipHandler(consume ctx, _sessions, _rooms, false)

actor _MembershipHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver
    & MembershipReceiver)
  """
  Joining and leaving, which differ only in which behaviour they call.
  """
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _params: Map[String, String] val
  let _joining: Bool
  var _session: (Session | None) = None

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    joining: Bool)
  =>
    let supplied = _BearerToken(ctx.request)
    // Captured raw. Decoding before the token is checked would let an
    // unauthenticated caller drive a percent-decode, which is the rule
    // `_SyncHandler` states and two tests pin.
    _params = ctx.params
    _joining = joining
    _rooms = rooms
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
      if _joining then
        room.join(s.user_id, s.user, this)
      else
        room.leave(s.user_id, this)
      end
    end

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

  be event_refused(why: (NotInRoom | NoEventId)) =>
    match \exhaustive\ why
    | NotInRoom =>
      _respond(
        stallion.StatusForbidden,
        MatrixError("M_FORBIDDEN", NotInRoom.message()))
    | NoEventId =>
      _respond(
        stallion.StatusInternalServerError,
        MatrixError("M_UNKNOWN", NoEventId.message()))
    end

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _RoomState
  """
  `GET /_matrix/client/v3/rooms/{roomId}/state`.

  The only thing a room can answer about its past, because it keeps no
  messages — current state is not history.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _RoomStateHandler(consume ctx, _sessions, _rooms)

actor _RoomStateHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver & StateReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _params: Map[String, String] val
  var _session: (Session | None) = None

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag)
  =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _rooms = rooms
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
    | let s: Session => room.state(s.user_id, this)
    end

  be room_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", NoSuchRoom.message()))

  be state_listed(events: Array[RoomEvent] val) =>
    _respond(stallion.StatusOK, StateEvents(events))

  be state_refused(why: NotInRoom) =>
    _respond(
      stallion.StatusForbidden,
      MatrixError("M_FORBIDDEN", NotInRoom.message()))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
