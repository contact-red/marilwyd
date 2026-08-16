use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _Login
  """
  `POST /_matrix/client/v3/login`.
  """
  let _homeserver: Homeserver
  let _credentials: Credentials
  let _sessions: SessionRegistry tag

  new val create(
    homeserver: Homeserver,
    credentials: Credentials,
    sessions: SessionRegistry tag)
  =>
    _homeserver = homeserver
    _credentials = credentials
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _LoginHandler(consume ctx, _homeserver, _credentials, _sessions)

actor _LoginHandler is (hobby.HandlerReceiver & TokenReceiver)
  """
  Verifies a password, then waits for the registry to mint a token.

  Verification runs here rather than inline in the connection actor because
  PBKDF2 at the configured iteration count is deliberately expensive — that
  cost is the whole point of a KDF, and it belongs on an actor that is not
  also reading the socket.
  """
  embed _handler: hobby.RequestHandler
  let _homeserver: Homeserver
  var _user_id: String = ""

  new create(
    ctx: hobby.HandlerContext iso,
    homeserver: Homeserver,
    credentials: Credentials,
    sessions: SessionRegistry tag)
  =>
    _homeserver = homeserver
    let body = ctx.body
    _handler = hobby.RequestHandler(consume ctx)

    match _ParseLogin(body)
    | let r: _LoginRequest =>
      match credentials(r.localpart)
      | let c: Credential if c.verify(r.password) =>
        _user_id = "@" + r.localpart + ":" + _homeserver.server_name
        sessions.issue(_user_id, this)
      else
        // One answer for "no such user" and for "wrong password", so a
        // caller cannot use the response to enumerate accounts.
        _respond(
          stallion.StatusForbidden,
          MatrixError("M_FORBIDDEN", "Invalid username or password"))
      end
    | let e: _LoginRefusal =>
      _respond(e.status, MatrixError(e.errcode, e.message))
    end

  be token_issued(token: AccessToken, device_id: String) =>
    // The one place an access token leaves marilwyd.
    _respond(
      stallion.StatusOK,
      LoginSuccess(
        _user_id,
        token.reveal(),
        device_id,
        _homeserver.server_name))

  be token_refused() =>
    _respond(
      stallion.StatusInternalServerError,
      MatrixError("M_UNKNOWN", NoSecureRandom.string()))

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _LoginRequest
  """
  The two fields marilwyd needs out of a login request body.
  """
  let localpart: String
  let password: String

  new val create(localpart': String, password': String) =>
    localpart = localpart'
    password = password'

class val _LoginRefusal
  """
  A login marilwyd would not even attempt, and the Matrix error that says so.
  """
  let status: stallion.Status
  let errcode: String
  let message: String

  new val create(
    status': stallion.Status,
    errcode': String,
    message': String)
  =>
    status = status'
    errcode = errcode'
    message = message'

primitive _ParseLogin
  """
  Read a Matrix login request.

  Accepts both the current shape, where the user sits in an `identifier`
  object, and the deprecated top-level `user`, because clients in the wild
  still send the latter.
  """
  fun apply(body: Array[U8] val): (_LoginRequest | _LoginRefusal) =>
    let text = String.from_array(body)

    let o =
      match JsonParser.parse(consume text)
      | let j: JsonObject => j
      else
        return _LoginRefusal(
          stallion.StatusBadRequest,
          "M_NOT_JSON",
          "Request body is not a JSON object")
      end

    match o.get_or_else("type", None)
    | "m.login.password" => None
    | let s: String =>
      return _LoginRefusal(
        stallion.StatusBadRequest,
        "M_UNKNOWN",
        "Unsupported login type: " + s)
    else
      return _LoginRefusal(
        stallion.StatusBadRequest,
        "M_MISSING_PARAM",
        "Missing login type")
    end

    let password =
      match o.get_or_else("password", None)
      | let s: String => s
      else
        return _LoginRefusal(
          stallion.StatusBadRequest,
          "M_MISSING_PARAM",
          "Missing password")
      end

    let user =
      match o.get_or_else("identifier", None)
      | let id: JsonObject =>
        match id.get_or_else("user", None)
        | let s: String => s
        else
          return _LoginRefusal(
            stallion.StatusBadRequest,
            "M_MISSING_PARAM",
            "identifier has no user")
        end
      else
        match o.get_or_else("user", None)
        | let s: String => s
        else
          return _LoginRefusal(
            stallion.StatusBadRequest,
            "M_MISSING_PARAM",
            "Missing user")
        end
      end

    // Accept a full user ID as well as a bare localpart: Element sends
    // whatever the person typed into the username box.
    let localpart =
      if user.at("@", 0) then
        try
          user.substring(1, user.find(":")?)
        else
          user.substring(1)
        end
      else
        user
      end

    _LoginRequest(consume localpart, password)
