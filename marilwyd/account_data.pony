use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _SetAccountData
  """
  `PUT /_matrix/client/v3/user/{userId}/account_data/{type}`.

  Element writes here the moment a client signs in — twice in the same
  millisecond, in a real session — and then reads it back from its local
  store, which its sync populates. So this endpoint on its own would let a
  client save settings it could never see again; what makes it work is that
  a change reaches every device through `/sync`.

  Room-scoped account data is a separate path and is not implemented.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _SetAccountDataHandler(consume ctx, _sessions)

actor _SetAccountDataHandler is (hobby.HandlerReceiver & UserReceiver)
  embed _handler: hobby.RequestHandler
  let _params: Map[String, String] val
  let _body: Array[U8] val

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _body = ctx.body
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _PathParam(_params, "type")
    | let kind: String =>
      // Only this account's own data. The `:userId` in the path is the
      // client repeating who it is, not choosing whose data to write.
      match \exhaustive\ _EventContent(_body)
      | let printed: String =>
        session.user.set_account_data(kind, printed)
        _respond(stallion.StatusOK, LogoutSuccess())
      | MalformedEvent =>
        _respond(
          stallion.StatusBadRequest,
          MatrixError("M_BAD_JSON", MalformedEvent.message()))
      end
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not an account data type"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _GetAccountData
  """
  `GET /_matrix/client/v3/user/{userId}/account_data/{type}`.

  Reached only before a client's first sync completes; after that Element
  answers the same question from its own store.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _GetAccountDataHandler(consume ctx, _sessions)

actor _GetAccountDataHandler is
  (hobby.HandlerReceiver & UserReceiver & AccountDataReceiver)
  embed _handler: hobby.RequestHandler
  let _params: Map[String, String] val

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _PathParam(_params, "type")
    | let kind: String => session.user.account_datum(kind, this)
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not an account data type"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be account_datum_found(content: String) =>
    _respond(stallion.StatusOK, content)

  be account_datum_missing() =>
    _respond(
      stallion.StatusNotFound,
      MatrixError("M_NOT_FOUND", "No account data of that type"))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
