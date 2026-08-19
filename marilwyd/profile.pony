use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"

primitive ProfileFor
  """
  The body of `GET /_matrix/client/v3/profile/{userId}`.

  A display name and nothing else. marilwyd stores no profile — there is no
  endpoint to set one and no room to keep one in — so the only honest
  answer is the one thing it can derive: the local part of the user's own
  id, which is what a person calls themselves here anyway.

  A bridged participant is left as marilwyd addresses them. Undoing the
  escaping alone would show `irc_fussake_bob{m}` — the far-side name with
  the mapping's own prefix still on it — and stripping the prefix here
  would mean this endpoint knowing the bridge configuration, which it has
  no other reason to hold. The name a person actually reads comes from the
  membership event the bridge writes, which carries the nickname as its
  owner spells it; this endpoint answers before a client has one, and
  answering with the id is honest where guessing is not.

  No `avatar_url`. An absent field and an empty one are different to a
  client — the second is a picture it will try to fetch — and marilwyd has
  no media repository to fetch from.
  """
  fun apply(displayname: String): String =>
    "{\"displayname\":" + JsonPrinter.print(displayname) + "}"

primitive DisplayName
  """
  What to call the account a user id names, or `None` when it names none.

  The local part, which is what a person calls themselves on this server.
  A bridged participant is the exception worth the code: their id carries
  the escaped form of a nickname, so `@irc_fussake_bob=5bm=5d` reads back
  as `bob[m]` rather than as its own escaping.
  """
  fun apply(user_id: String, server_name: String): (String | None) =>
    """
    The name to show for `user_id`, or `None` when it names nobody here.
    """
    let colon =
      try
        user_id.find(":")?
      else
        return None
      end

    let named: String = user_id.substring(colon + 1)
    if named != server_name then
      return None
    end

    try
      if user_id(0)? != '@' then
        return None
      end
    else
      return None
    end

    let localpart: String = user_id.substring(1, colon)
    if localpart.size() == 0 then
      return None
    end
    localpart

class val _Profile
  """
  `GET /_matrix/client/v3/profile/{userId}`.

  Element asks for it as soon as it renders a room, and asks again for
  every participant it does not recognise. Answering `M_UNRECOGNIZED` is
  why a client shows a user id where a name belongs.

  Authenticated, like everything else here. The specification permits this
  one unauthenticated — it is public data on a federating server — but
  marilwyd federates with nothing, so the only callers are its own
  clients, and an unauthenticated endpoint that names accounts is a way to
  ask whether an account exists.
  """
  let _sessions: SessionRegistry tag
  let _homeserver: Homeserver

  new val create(sessions: SessionRegistry tag, homeserver: Homeserver) =>
    _sessions = sessions
    _homeserver = homeserver

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _ProfileHandler(consume ctx, _sessions, _homeserver)

actor _ProfileHandler is (hobby.HandlerReceiver & UserReceiver)
  embed _handler: hobby.RequestHandler
  let _params: Map[String, String] val
  let _server_name: String

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    homeserver: Homeserver)
  =>
    let supplied = _BearerToken(ctx.request)
    _params = ctx.params
    _server_name = homeserver.server_name
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _PathParam(_params, "userId")
    | let who: String =>
      match \exhaustive\ DisplayName(who, _server_name)
      | let shown: String => _respond(stallion.StatusOK, ProfileFor(shown))
      | None =>
        // An id this server could not have issued names nobody here, and
        // nothing federates, so there is nowhere else to ask.
        _respond(
          stallion.StatusNotFound,
          MatrixError("M_NOT_FOUND", "No profile for that user"))
      end
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not a user identifier"))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
