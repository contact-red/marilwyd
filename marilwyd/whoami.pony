use hobby = "hobby"
use stallion = "stallion"

class val _Whoami
  """
  `GET /_matrix/client/v3/account/whoami`.

  The smallest endpoint that proves a token issued by login can actually be
  spent.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _WhoamiHandler(consume ctx, _sessions)

actor _WhoamiHandler is (hobby.HandlerReceiver & UserReceiver)
  embed _handler: hobby.RequestHandler

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    _respond(
      stallion.StatusOK,
      WhoamiSuccess(session.user_id, session.device))

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive _BearerToken
  """
  Pull the access token out of an `Authorization: Bearer` header.

  Matrix also permits `?access_token=` in the query string. marilwyd does not
  read it: a query string reaches logs, proxies and browser history far too
  easily, and every current client sends the header.
  """
  fun apply(request: stallion.Request val): (String | None) =>
    match request.headers.get("authorization")
    | let h: String if h.size() > 7 =>
      // RFC 9110 makes the scheme case-insensitive.
      if h.substring(0, 7).lower() == "bearer " then
        h.substring(7)
      else
        None
      end
    else
      None
    end
