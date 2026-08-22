use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _Logout
  """
  `POST /_matrix/client/v3/logout`.

  Ends the session the request's own token belongs to, and no other. With
  several clients signed in as one account, this is how one of them stops
  being signed in without restarting the server or disturbing the rest.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _LogoutHandler(consume ctx, _sessions)

actor _LogoutHandler is (hobby.HandlerReceiver & RevocationReceiver)
  embed _handler: hobby.RequestHandler

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.revoke(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be session_revoked() =>
    _respond(stallion.StatusOK, LogoutSuccess())

  be revocation_rejected() =>
    // Not 200: a client told its logout succeeded will discard a token
    // that was never live and stop being able to tell the difference.
    //
    // `ExpiredToken`, not `UnknownToken`, because the latter carries
    // `soft_logout`, which asks a client to sign in again and keep its
    // local state. That is the right offer almost everywhere and the wrong
    // one here, where the client just asked to stop being signed in.
    _respond(stallion.StatusUnauthorized, ExpiredToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _Devices
  """
  `GET /_matrix/client/v3/devices`.

  Every device of the calling account, so a client can show the sessions
  signed in and offer to end them. Element's session manager is built on
  this and on `POST /delete_devices`; without the list it renders nothing
  and its sign-out affordance never appears.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _DevicesHandler(consume ctx, _sessions)

actor _DevicesHandler is (hobby.HandlerReceiver & DeviceReceiver)
  embed _handler: hobby.RequestHandler

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.devices(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be devices_listed(found: Array[DeviceId] val) =>
    _respond(stallion.StatusOK, DeviceList(found))

  be devices_refused() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _DeleteDevices
  """
  `POST /_matrix/client/v3/delete_devices`.

  Ends several of the calling account's sessions at once — the phone and
  the old laptop, from the desktop. This is what Element's session manager
  calls; it has no call site for the specification's single-device
  `DELETE /devices/{deviceId}`.

  **Deviates from the specification**: this endpoint is defined as
  requiring user-interactive authentication, so a conformant server answers
  401 with a flow to complete and only then deletes. marilwyd has no UIA
  and the bearer token is the whole check, which is weaker against an
  attacker who already holds a token. See `SECURITY.md`. Element handles
  the absence: its call passes an auth object only if a challenge came
  back, so answering directly is a path it already takes.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _DeleteDevicesHandler(consume ctx, _sessions)

actor _DeleteDevicesHandler is (hobby.HandlerReceiver & RevocationReceiver)
  embed _handler: hobby.RequestHandler

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    let body = ctx.body
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String =>
      // Parsed only once a token is present, so an unauthenticated caller
      // cannot drive a JSON parse — the rule `_SyncHandler` states and
      // enforces for its query string.
      match \exhaustive\ _DeviceNames(body)
      | let names: Array[String] val => sessions.revoke_devices(t, names, this)
      | None =>
        _respond(
          stallion.StatusBadRequest,
          MatrixError("M_BAD_JSON", "devices must be an array of strings"))
      end
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be session_revoked() =>
    _respond(stallion.StatusOK, LogoutSuccess())

  be revocation_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive _DeviceNames
  """
  Pull the `devices` array out of a delete request body.

  Answers `None` for a body that is not an object, has no `devices` array,
  or whose entries are not all strings. An empty array is accepted and
  deletes nothing, which is what it asks for.
  """
  fun apply(body: Array[U8] val): (Array[String] val | None) =>
    let parsed =
      match _ObjectBody(body, MaxDeviceNamesBody())
      | let o: JSONObject => o
      else
        return None
      end

    let listed =
      match parsed.get_or_else("devices", None)
      | let a: JSONArray => a
      else
        return None
      end

    recover val
      let names = Array[String]
      for entry in listed.values() do
        match entry
        | let name: String => names.push(name)
        else
          return None
        end
      end
      names
    end

primitive MaxDeviceNamesBody
  """
  The largest `delete_devices` request marilwyd will read.

  A list of device ids and nothing else. It had no bound at all — neither
  size nor depth — which made it the cheapest unbounded parse behind a
  token in the server.
  """
  fun apply(): USize => 8192
