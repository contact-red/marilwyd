use hobby = "hobby"
use stallion = "stallion"

class val _AuthedJSON
  """
  Respond with one JSON document, but only to a live session.

  The third combination marilwyd needs: `_ServeJSON` answers everyone,
  `_Whoami` answers a session with something about that session, and these
  routes answer a session with a constant. The document is what differs;
  the authentication answer is what is worth sharing.

  An actor is unavoidable here even though the body is fixed, because
  `SessionRegistry.resolve` is a behaviour — which is also why this cannot
  simply be `_ServeJSON` with a token check bolted on.

  Two triggers to split this type up. The first body that differs per user
  is one. The other is `:userId`: these routes carry it, marilwyd does not
  read it, and the specification says a mismatch against the token's own
  user is `403 M_FORBIDDEN`. Ignoring it discloses nothing while every
  document is a constant, and stops being defensible the moment one is not.
  Path parameters arrive percent-encoded, so that check is a `PercentDecode`
  before a comparison, not a string equality.
  """
  let _sessions: SessionRegistry tag
  let _body: String

  new val create(sessions: SessionRegistry tag, body: String) =>
    _sessions = sessions
    _body = body

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _AuthedJSONHandler(consume ctx, _sessions, _body)

actor _AuthedJSONHandler is (hobby.HandlerReceiver & UserReceiver)
  embed _handler: hobby.RequestHandler
  let _body: String

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    body: String)
  =>
    let supplied = _BearerToken(ctx.request)
    _body = body
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    _respond(stallion.StatusOK, _body)

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
