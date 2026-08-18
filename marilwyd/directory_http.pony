use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _ResolveAlias
  """
  `GET /_matrix/client/v3/directory/room/{roomAlias}`.

  How a client turns the name a person typed, or clicked in the directory,
  into the room id everything else takes. matrix-js-sdk calls it
  `getRoomIdForAlias`, and Element reaches it from the address bar, from
  the room directory, and when checking whether an alias it is about to
  set already belongs to this room.
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
    _ResolveAliasHandler(consume ctx, _sessions, _rooms, _homeserver)

actor _ResolveAliasHandler is
  (hobby.HandlerReceiver & UserReceiver & AliasReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  let _server_name: String
  let _params: Map[String, String] val

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    homeserver: Homeserver)
  =>
    let supplied = _BearerToken(ctx.request)
    _rooms = rooms
    _server_name = homeserver.server_name
    _params = ctx.params
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _PathParam(_params, "roomAlias")
    | let text: String =>
      // Parsed before it is looked up, so text that could never be an
      // alias is refused as such rather than reported as a room nobody
      // has — a client typing `#room` without a server gets told what is
      // wrong with it.
      match \exhaustive\ RoomAliases(text, _server_name)
      | let alias: RoomAlias =>
        let key: String = alias.string()
        _rooms.resolve_alias(key, this)
      | let why: InvalidAlias =>
        _respond(
          stallion.StatusBadRequest,
          MatrixError("M_INVALID_PARAM", why.string()))
      end
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a room alias"))
    end

  be alias_resolved(room_id: String) =>
    _respond(stallion.StatusOK, AliasResolved(room_id, _server_name))

  be alias_unknown() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", "No room on this server has that alias"))

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _PublicRooms
  """
  `GET` and `POST /_matrix/client/v3/publicRooms`.

  Both, because matrix-js-sdk chooses between them: an unfiltered listing
  is a `GET` with query parameters, and a search is a `POST` carrying the
  filter in its body. Element's Explore dialog does the first on open and
  the second as soon as anyone types, so answering only one leaves the
  directory working until it is used.

  Neither the filter nor `since` is read. Every published room is answered
  every time — with a personal server's handful of rooms, a client that
  asked for a filtered page and got the lot will show the lot, which is
  right, and paginating a list nobody has to scroll would be a mechanism
  with no reader.
  """
  let _sessions: SessionRegistry tag
  let _rooms: RoomDirectory tag

  new val create(sessions: SessionRegistry tag, rooms: RoomDirectory tag) =>
    _sessions = sessions
    _rooms = rooms

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _PublicRoomsHandler(consume ctx, _sessions, _rooms)

actor _PublicRoomsHandler is
  (hobby.HandlerReceiver & UserReceiver & PublishedRoomsReceiver
    & RoomSummaryReceiver)
  embed _handler: hobby.RequestHandler
  let _rooms: RoomDirectory tag
  embed _summaries: Array[RoomSummary] = _summaries.create()
  var _outstanding: USize = 0

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag)
  =>
    let supplied = _BearerToken(ctx.request)
    _rooms = rooms
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    _rooms.published(this)

  be rooms_published(rooms: Array[Room tag] val) =>
    """
    Ask every published room what it is. The answer goes out when the last
    one replies.
    """
    _outstanding = rooms.size()
    if _outstanding == 0 then
      _answer()
    else
      for room in rooms.values() do
        room.summarise(this)
      end
    end

  be room_summarised(summary: RoomSummary) =>
    _summaries.push(summary)
    _outstanding = _outstanding - 1
    if _outstanding == 0 then
      _answer()
    end

  fun ref _answer() =>
    let found = recover iso Array[RoomSummary] end
    for summary in _summaries.values() do
      found.push(summary)
    end
    _respond(stallion.StatusOK, PublicRooms(consume found))

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
