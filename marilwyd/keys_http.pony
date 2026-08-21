use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _UploadKeys
  """
  `POST /_matrix/client/v3/keys/upload`.

  A client publishes two different things in one request. Its device keys
  are its public identity and belong to the account, so they go to the
  `User`; its one-time keys are spent one per session another device opens
  and belong to the device, so they go to the `Device`.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _UploadKeysHandler(consume ctx, _sessions)

actor _UploadKeysHandler is
  (hobby.HandlerReceiver & UserReceiver & OneTimeKeyReceiver)
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
    | let uploaded: JSONObject =>
      match _PrintedField(uploaded, "device_keys")
      | let keys: String =>
        session.user.publish_keys(session.device.string(), keys)
      end
      // Always asked, even for an upload carrying no one-time keys: the
      // answer is the count the client reads to decide whether to send
      // more, and it is a fact about the device rather than about this
      // request.
      session.stream.take_one_time_keys(
        ReadOneTimeKeys(uploaded, "one_time_keys"), this)
    | MalformedKeys =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedKeys.message()))
    end

  be one_time_keys_held(count: USize) =>
    _respond(stallion.StatusOK, KeysUploaded(count))

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _QueryKeys
  """
  `POST /_matrix/client/v3/keys/query`.

  The endpoint that has to be right rather than merely present. A client's
  crypto machine asks this before it will let a session start, and it
  re-asks immediately for as long as the answer does not resolve what it
  asked about — with empty key maps that was measured at 10,325 requests in
  seventy seconds, which is worse than the 404 it replaced.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _QueryKeysHandler(consume ctx, _sessions)

actor _QueryKeysHandler is
  (hobby.HandlerReceiver & UserReceiver & UserLookupReceiver
    & PublishedKeysReceiver)
  embed _handler: hobby.RequestHandler
  let _sessions: SessionRegistry tag
  let _body: Array[U8] val
  embed _answers: Array[(String, PublishedKeys)] = _answers.create()
  var _asking: String = ""
  var _expected: USize = 0

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _sessions = sessions
    _body = ctx.body
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _KeysBody(_body)
    | let asked: JSONObject =>
      _asking = session.user_id
      _sessions.lookup_users(QueriedUsers(asked, session.user_id), this)
    | MalformedKeys =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedKeys.message()))
    end

  be users_found(
    known: Array[(String, User tag)] val,
    unknown: Array[String] val)
  =>
    """
    An account marilwyd has never seen still gets an entry, with no devices
    in it. Leaving it out is what a client reads as an unanswered query.
    """
    for user_id in unknown.values() do
      _answers.push((user_id,
        PublishedKeys(recover val Array[DeviceKeys] end, None, None, None)))
    end

    _expected = known.size()
    if _expected == 0 then
      _answer()
    else
      for (user_id, user) in known.values() do
        user.published_keys(this, user_id == _asking)
      end
    end

  be keys_published(user_id: String, keys: PublishedKeys) =>
    """
    One account's answer. The response goes out when the last one arrives.
    """
    _answers.push((user_id, keys))
    _expected = _expected - 1
    if _expected == 0 then
      _answer()
    end

  fun ref _answer() =>
    let found = recover iso Array[(String, PublishedKeys)] end
    for answer in _answers.values() do
      found.push(answer)
    end
    _respond(stallion.StatusOK, KeysQueried(consume found))

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive QueriedUsers
  """
  The accounts a `keys/query` body asks about.

  The querying account is always included, whether or not it named itself.
  A client asks about itself constantly — it is how it learns about its own
  other devices — and an answer that omitted it would be the unanswered
  query that costs a request storm.
  """
  fun apply(body: JSONObject, asking: String): Array[String] val =>
    """
    Every account named, plus the one asking.
    """
    let wanted = recover iso Array[String] end
    wanted.push(asking.clone())
    try
      match body("device_keys")?
      | let asked: JSONObject =>
        for user_id in asked.keys() do
          if user_id != asking then
            wanted.push(user_id.clone())
          end
        end
      end
    end
    consume wanted

class val _UploadCrossSigningKeys
  """
  `POST /_matrix/client/v3/keys/device_signing/upload`.

  No user-interactive authentication. The specification allows a first
  upload without it, and marilwyd has no second factor to ask for: the only
  credential it holds is the password that minted the token already
  presented, so a `401` here would be a form a client fills in with what it
  has already proved.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _UploadCrossSigningKeysHandler(consume ctx, _sessions)

actor _UploadCrossSigningKeysHandler is
  (hobby.HandlerReceiver & UserReceiver)
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
    | let uploaded: JSONObject =>
      session.user.publish_cross_signing(
        _PrintedField(uploaded, "master_key"),
        _PrintedField(uploaded, "self_signing_key"),
        _PrintedField(uploaded, "user_signing_key"))
      _respond(stallion.StatusOK, LogoutSuccess())
    | MalformedKeys =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedKeys.message()))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

class val _UploadSignatures
  """
  `POST /_matrix/client/v3/keys/signatures/upload`.

  Load-bearing, and not obviously so. Answering `M_UNRECOGNIZED` here ends
  a session at "Unable to set up keys" without ever reaching the backup
  step — measured by removing exactly this endpoint and changing nothing
  else.

  Only signatures made by the account that is signed in are stored. Cross
  signing another account's keys is what this endpoint is for in a
  federated server; here it would be an account publishing signatures under
  someone else's name.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _UploadSignaturesHandler(consume ctx, _sessions)

actor _UploadSignaturesHandler is (hobby.HandlerReceiver & UserReceiver)
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
    | let uploaded: JSONObject =>
      try
        match uploaded(session.user_id)?
        | let mine: JSONObject =>
          for (key_id, signed) in mine.pairs() do
            match signed
            | let o: JSONObject =>
              session.user.sign_key(key_id.clone(), JSONPrinter.print(o))
            end
          end
        end
      end
      _respond(stallion.StatusOK, SignaturesUploaded())
    | MalformedKeys =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedKeys.message()))
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None
