use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"

primitive ReadReceipt
  """
  `POST /rooms/{roomId}/receipt/m.read/{eventId}` — how far somebody has
  read, from the event id in the path.
  """
  fun read(params: Map[String, String] val, body: Array[U8] val)
    : (String | None)
  =>
    _PathParam(params, "eventId")

primitive FullyRead
  """
  `POST /rooms/{roomId}/read_markers` — the same thing from a body, which
  is the other spelling Element uses.

  It carries two positions: `m.read`, which is the read receipt, and
  `m.fully_read`, which is a private marker only its owner sees. marilwyd
  keeps the first and drops the second, because a private per-room marker
  is account data scoped to a room and marilwyd has no room-scoped account
  data to put it in. Dropping it loses the line Element draws for unread
  messages; keeping the receipt is what stops the retry loop.
  """
  fun read(params: Map[String, String] val, body: Array[U8] val)
    : (String | None)
  =>
    match _KeysBody(body)
    | let sent: JSONObject =>
      try
        match sent("m.read")?
        | let event_id: String => return event_id.clone()
        end
      end
    end
    None

type _ReceiptSource is (ReadReceipt | FullyRead)
  """
  Where a read position came from — a path segment, or a body.

  Two endpoints that differ in one line and share a handler, rather than
  two handlers alike in fifty.
  """

class val _Receipt
  """
  Both ways a client reports how far it has read.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag
  let _source: _ReceiptSource

  new val create(
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    source: _ReceiptSource)
  =>
    _sessions = sessions
    _rooms = rooms
    _source = source

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _ReceiptHandler(consume ctx, _sessions, _rooms, _source)

actor _ReceiptHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _params: Map[String, String] val
  let _body: Array[U8] val
  let _source: _ReceiptSource
  var _session: (Session | None) = None

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    source: _ReceiptSource)
  =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _body = ctx.body
    _rooms = rooms
    _source = source
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
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room identifier"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_found(room: Room tag) =>
    let named =
      match \exhaustive\ _source
      | ReadReceipt => ReadReceipt.read(_params, _body)
      | FullyRead => FullyRead.read(_params, _body)
      end

    match (_session, named)
    | (let s: Session, let event_id: String) =>
      room.read_up_to(s.user_id, event_id)
      _respond(stallion.StatusOK, LogoutSuccess())
    else
      // A body or path naming no event. Answered rather than refused: a
      // read marker for nothing is a client saying nothing, and there is
      // no state to correct.
      _respond(stallion.StatusOK, LogoutSuccess())
    end

  be room_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", NoSuchRoom.message()))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _Typing
  """
  `PUT /_matrix/client/v3/rooms/{roomId}/typing/{userId}`.

  The `typing` field says whether they are, and `timeout` says for how
  long. marilwyd reads the first and ignores the second: honouring it needs
  a timer per typist, and a client that stops sends `typing: false` — the
  case the timeout covers is a client that vanishes mid-sentence, which
  leaves a name showing until it returns. Stated rather than solved.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _TypingHandler(consume ctx, _sessions, _rooms)

actor _TypingHandler is
  (hobby.HandlerReceiver & UserReceiver & RoomLookupReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _params: Map[String, String] val
  let _body: Array[U8] val
  var _session: (Session | None) = None

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
    match \exhaustive\ _PathParam(_params, "roomId")
    | let id: String => _rooms.with_room(id, this)
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room identifier"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be room_found(room: Room tag) =>
    // The `:userId` in the path is the client repeating who it is, the
    // same as account data's. The session decides who is typing, so a
    // client cannot say somebody else is.
    match _session
    | let s: Session => room.typing(s.user_id, _wants())
    end
    _respond(stallion.StatusOK, LogoutSuccess())

  fun _wants(): Bool =>
    match _KeysBody(_body)
    | let sent: JSONObject =>
      try
        match sent("typing")?
        | let active: Bool => return active
        end
      end
    end
    false

  be room_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", NoSuchRoom.message()))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
