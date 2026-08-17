use hobby = "hobby"
use stallion = "stallion"

class val _Unrecognized
  """
  The answer for any `/_matrix/` path marilwyd does not implement.

  A request carrying a token gets that token checked first. Element does not
  call `whoami` when it restores a session — it goes straight to endpoints
  like `/capabilities`, `/keys/query` and `/profile`, which marilwyd does not
  implement. If those answered a flat 404, a client holding a token from
  before a restart would be told "no such endpoint" and never "your session
  is gone", so it would keep the stale token, keep showing a signed-in
  account, and wait for data that cannot arrive.

  Checking the token here means the client learns the truth from whichever
  endpoint it happens to reach first.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _UnrecognizedHandler(consume ctx, _sessions)

actor _UnrecognizedHandler is (hobby.HandlerReceiver & UserReceiver)
  embed _handler: hobby.RequestHandler

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      // No token offered, so there is nothing to say about one.
      _unrecognized()
    end

  be token_resolved(user_id: String, device: DeviceId) =>
    // The session is live; the endpoint really is the missing part.
    _unrecognized()

  be token_rejected() =>
    _handler.respond_with_headers(
      stallion.StatusUnauthorized, _JSONHeaders(), UnknownToken())

  fun ref _unrecognized() =>
    _handler.respond_with_headers(
      stallion.StatusNotFound, _JSONHeaders(), UnrecognizedRequest())

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
