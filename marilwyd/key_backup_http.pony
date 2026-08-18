use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _CreateKeyBackup
  """
  `POST /_matrix/client/v3/room_keys/version`.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _CreateKeyBackupHandler(consume ctx, _sessions)

actor _CreateKeyBackupHandler is
  (hobby.HandlerReceiver & UserReceiver & KeyBackupReceiver)
  embed _handler: hobby.RequestHandler
  let _body: Array[U8] val

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _body = ctx.body
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _KeysBody(_body)
    | let described: JsonObject =>
      match (_Algorithm(described), _PrintedField(described, "auth_data"))
      | (let algorithm: String, let auth_data: String) =>
        session.user.create_backup(KeyBackup(algorithm, auth_data), this)
      else
        _respond(
          stallion.StatusBadRequest,
          MatrixError(
            "M_INVALID_PARAM",
            "A backup needs an algorithm and auth_data"))
      end
    | MalformedKeys =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedKeys.message()))
    end

  be backup_created(version: String) =>
    _respond(stallion.StatusOK, KeyBackupCreated(version))

  be backup_found(backup: KeyBackup, version: String) => None
  be backup_missing() => None

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive _Algorithm
  """
  The `algorithm` of a backup description, if it named one as text.
  """
  fun apply(described: JsonObject): (String | None) =>
    try
      match described("algorithm")?
      | let name: String => name.clone()
      else
        None
      end
    else
      None
    end

class val _KeyBackupVersion
  """
  `GET /_matrix/client/v3/room_keys/version`.

  Only the current version. The specification also has
  `/room_keys/version/{version}` for an older one, which no client marilwyd
  serves asks for.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _KeyBackupVersionHandler(consume ctx, _sessions)

actor _KeyBackupVersionHandler is
  (hobby.HandlerReceiver & UserReceiver & KeyBackupReceiver)
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
    session.user.latest_backup(this)

  be backup_created(version: String) => None

  be backup_found(backup: KeyBackup, version: String) =>
    _respond(stallion.StatusOK, backup.render(version))

  be backup_missing() =>
    _respond(stallion.StatusNotFound, NoKeyBackup())

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
