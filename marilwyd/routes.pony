use "time"
use hobby = "hobby"
use stallion = "stallion"

primitive Routes
  """
  The whole server, in one table. Every row states its own full path.

  Registration order does not matter — hobby resolves a request by
  specificity, static beating parameter beating wildcard, structurally in a
  trie. The rows are grouped by namespace because that is how they read.

  The rows marked `hobby#1` are companions. hobby's router does not consult
  a node's wildcard entries once the request's path segments are exhausted,
  so a wildcard mount cannot answer its own mount point. A companion route
  is needed wherever a declared namespace root must answer in that
  namespace's own vocabulary — `/`, `/element` and `/_matrix` — and nowhere
  else, and it is needed once per method the wildcard covers.
  `/element/bundles` also 404s plain-text, and no client asks for it.
  """
  fun apply(
    config: Config,
    sessions: SessionRegistry tag,
    rooms: RoomDirectory tag,
    epoch: StreamEpoch,
    log: (OutStream tag | None) = None)
    : hobby.BuildResult
  =>
    """
    Build the route table, or report the configuration error that stops it.

    Pass an `OutStream` to log every request as it arrives and every
    response as it leaves.
    """
    let hs = config.homeserver
    let element_config = _ServeJSON(ElementConfig(hs))
    // Checks any token it is given before answering, so a client holding a
    // session from before a restart is told so rather than being told the
    // endpoint is missing.
    let unrecognized = _Unrecognized(sessions)
    let to_element = _Redirect("/element/index.html")

    let app = hobby.Application

    match log
    | let out: OutStream tag =>
      // One start for both, so the two halves of a request are stamped on
      // the same clock and their difference is the time it took.
      let start = Time.nanos()
      app.add_request_interceptor(_LogRequest(out, start))
      app.add_response_interceptor(_LogResponse(out, start))
    end

    (app
      // The origin root is marilwyd's, not Element's. Mounting Element here
      // would serve its `apple-app-site-association` and
      // `.well-known/assetlinks.json`, which delegate universal-link handling
      // and iOS keychain credential sharing for this domain to Element's
      // published mobile apps.
      .> get("/", to_element)                                      // hobby#1

      .> get("/element", to_element)                               // hobby#1
      .> get("/element/config.json", element_config)
      // Element probes this before `config.json`. The host is fixed at
      // startup from `--server-name`, so this only shadows when the browser
      // reaches marilwyd under that name; any other name 404s and Element
      // falls through to `config.json`, which is also correct.
      .> get("/element/config." + hs.host() + ".json", element_config)
      .> get(
        "/element/bundles/*filepath",
        hobby.ServeFiles(
          config.bundles_root
          where cache_control = "public, max-age=31536000, immutable"))
      // `no-cache`, never `None`. Omitting the header entirely lets the
      // browser invent a freshness lifetime from the file's age, and an
      // Element upgrade then goes unseen by a returning user.
      .> get(
        "/element/*filepath",
        hobby.ServeFiles(
          config.asset_root
          where cache_control = "no-cache"))

      .> get("/_matrix", unrecognized)                             // hobby#1
      .> get("/_matrix/client/versions", _ServeJSON(ClientVersions()))
      .> get("/_matrix/client/v3/login", _ServeJSON(LoginFlows()))
      .> post(
        "/_matrix/client/v3/login",
        _Login(hs, config.credentials, sessions))
      .> get(
        "/_matrix/client/v3/account/whoami",
        _Whoami(sessions))
      .> post("/_matrix/client/v3/logout", _Logout(sessions))
      // The pair Element's session manager is built on. It has no call
      // site for the specification's single-device
      // `DELETE /devices/{deviceId}`, so marilwyd does not answer one.
      .> get("/_matrix/client/v3/devices", _Devices(sessions))
      .> post(
        "/_matrix/client/v3/delete_devices",
        _DeleteDevices(sessions))
      .> get("/_matrix/client/v3/sync", _Sync(sessions, epoch))
      .> post("/_matrix/client/v3/createRoom", _CreateRoom(sessions, rooms, hs))
      // `/join/{roomIdOrAlias}` and not `/rooms/{roomId}/join`: the former
      // is what matrix-js-sdk builds and the latter has no call site in
      // any client marilwyd ships.
      // How a person finds a room without being handed its id. A bridged
      // channel is published with an alias, so Element's Explore dialog
      // lists it and joining is a click rather than a paste.
      .> get(
        "/_matrix/client/v3/directory/room/:roomAlias",
        _ResolveAlias(sessions, rooms, hs))
      .> get("/_matrix/client/v3/publicRooms", _PublicRooms(sessions, rooms))
      .> post("/_matrix/client/v3/publicRooms", _PublicRooms(sessions, rooms))
      .> post(
        "/_matrix/client/v3/join/:roomIdOrAlias",
        _JoinRoom(sessions, rooms))
      .> post(
        "/_matrix/client/v3/rooms/:roomId/leave",
        _LeaveRoom(sessions, rooms))
      .> put(
        "/_matrix/client/v3/rooms/:roomId/send/:eventType/:txnId",
        _SendEvent(sessions, rooms))
      .> get(
        "/_matrix/client/v3/rooms/:roomId/state",
        _RoomState(sessions, rooms))
      // Asked as soon as a client renders a room, and again for every
      // participant it does not recognise.
      .> get(
        "/_matrix/client/v3/rooms/:roomId/members",
        _RoomState(sessions, rooms, MembersOnly))
      .> get(
        "/_matrix/client/v3/profile/:userId",
        _Profile(sessions, hs))
      .> put(
        "/_matrix/client/v3/user/:userId/account_data/:type",
        _SetAccountData(sessions))
      .> get(
        "/_matrix/client/v3/user/:userId/account_data/:type",
        _GetAccountData(sessions))
      // Element asks for `/pushrules/`. hobby strips a trailing slash at
      // both registration and lookup, so the two spellings are one route
      // and only one may be registered — a second would silently replace
      // the first rather than fail to build.
      .> get(
        "/_matrix/client/v3/pushrules",
        _AuthedJSON(sessions, PushRules()))
      .> post(
        "/_matrix/client/v3/user/:userId/filter",
        _AuthedJSON(sessions, FilterCreated()))
      .> get(
        "/_matrix/client/v3/user/:userId/filter/:filterId",
        _AuthedJSON(sessions, EmptyFilter()))

      // Encryption. A client will not finish signing in without all four of
      // these: removing any one of them was measured to leave Element at
      // "Setting up keys" or "Unable to set up keys" rather than in the app.
      .> post("/_matrix/client/v3/keys/upload", _UploadKeys(sessions))
      .> post("/_matrix/client/v3/keys/query", _QueryKeys(sessions))
      .> post(
        "/_matrix/client/v3/keys/device_signing/upload",
        _UploadCrossSigningKeys(sessions))
      .> post(
        "/_matrix/client/v3/keys/signatures/upload",
        _UploadSignatures(sessions))
      // Not encryption itself, but part of the same gate: a client that
      // cannot create a backup version stops at "Unable to set up keys".
      .> post(
        "/_matrix/client/v3/room_keys/version",
        _CreateKeyBackup(sessions))
      .> get(
        "/_matrix/client/v3/room_keys/version",
        _KeyBackupVersion(sessions))
      // What one device says to another. `keys/claim` spends a one-time
      // key so the two can open a session; `sendToDevice` is what they say
      // once they have one.
      .> post("/_matrix/client/v3/keys/claim", _ClaimKeys(sessions))
      .> put(
        "/_matrix/client/v3/sendToDevice/:eventType/:txnId",
        _SendToDevice(sessions))

      // A method with no row at all is hobby's business, and hobby answers
      // it with a plain-text `Method Not Allowed` carrying no `errcode` —
      // the exact failure `UnrecognizedRequest` exists to prevent. These
      // four are the methods Element was observed to send; it uses
      // `POST .../keys/query` and `PUT .../account_data/...` every session.
      // `OPTIONS` and `PATCH` still get the plain-text 405, and `OPTIONS`
      // is a real gap: a browser preflight needs CORS headers, which a
      // `M_UNRECOGNIZED` row would not supply either.
      .> get("/_matrix/*endpoint", unrecognized)
      .> post("/_matrix/*endpoint", unrecognized)
      .> put("/_matrix/*endpoint", unrecognized)
      .> delete("/_matrix/*endpoint", unrecognized)

      // One companion per method, for the same reason as the GET above.
      .> post("/_matrix", unrecognized)                            // hobby#1
      .> put("/_matrix", unrecognized)                             // hobby#1
      .> delete("/_matrix", unrecognized)                          // hobby#1
    ).build()

primitive _JSONHeaders
  """
  The headers on every JSON response marilwyd generates.

  `no-store` because these bodies are derived from configuration or from a
  session; a copy cached in a browser would outlive either.
  """
  fun apply(): stallion.Headers val =>
    recover val
      stallion.Headers
        .> set("Content-Type", "application/json")
        .> set("Cache-Control", "no-store")
        // A login error echoes back a string the caller chose, and Element
        // is served from this same origin.
        .> set("X-Content-Type-Options", "nosniff")
    end

class val _ServeJSON
  """
  Respond to every request with one JSON document, rendered once at startup.
  """
  let _headers: stallion.Headers val
  let _body: String
  let _status: stallion.Status

  new val create(body: String, status: stallion.Status = stallion.StatusOK) =>
    _headers = _JSONHeaders()
    _body = body
    _status = status

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    hobby.RequestHandler(consume ctx)
      .respond_with_headers(_status, _headers, _body)
    None

class val _Redirect
  """
  Respond to every request with a temporary redirect to a fixed location.

  Temporary rather than permanent: browsers cache a 301 hard, and this one
  marks a namespace boundary that may move.
  """
  let _headers: stallion.Headers val

  new val create(location: String) =>
    _headers =
      recover val
        stallion.Headers .> set("Location", location)
      end

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    hobby.RequestHandler(consume ctx)
      .respond_with_headers(stallion.StatusFound, _headers, "")
    None
