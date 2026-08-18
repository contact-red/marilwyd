use "collections"
use "json"
use hobby = "hobby"
use stallion = "stallion"

class val _ClaimKeys
  """
  `POST /_matrix/client/v3/keys/claim`.

  What makes a device's one-time keys worth storing. A device opening an
  Olm session with another takes one key here, and that key is spent — the
  pool `keys/upload` fills is the pool this drains.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _ClaimKeysHandler(consume ctx, _sessions)

actor _ClaimKeysHandler is
  (hobby.HandlerReceiver & UserReceiver & UserLookupReceiver
    & OneTimeKeyClaimReceiver)
  embed _handler: hobby.RequestHandler
  let _sessions: SessionRegistry tag
  let _body: Array[U8] val
  embed _wanted: Map[String, Array[String] val] = _wanted.create()
  embed _claimed: Array[ClaimedKey] = _claimed.create()
  var _outstanding: USize = 0

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
    | let asked: JsonObject =>
      for (user_id, device_ids) in _ClaimedDevices(asked).pairs() do
        _wanted(user_id) = device_ids
      end
      if _wanted.size() == 0 then
        _answer()
      else
        let names = recover iso Array[String] end
        for user_id in _wanted.keys() do
          names.push(user_id)
        end
        _sessions.lookup_users(consume names, this)
      end
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
    Only accounts marilwyd holds are asked. An account it has never seen
    has no device that could answer, and the response leaves it out — a
    claim names devices rather than accounts, and there is nothing to say
    about one that does not exist.
    """
    for (user_id, _) in known.values() do
      _outstanding = _outstanding + _requested(user_id).size()
    end
    if _outstanding == 0 then
      _answer()
    else
      for (user_id, user) in known.values() do
        user.claim_keys(_requested(user_id), this)
      end
    end

  be one_time_key_claimed(
    user_id: String,
    device_id: String,
    key_id: String,
    content: String)
  =>
    _claimed.push(ClaimedKey(user_id, device_id, key_id, content))
    _settled()

  be one_time_key_missing(user_id: String, device_id: String) =>
    _settled()

  fun ref _settled() =>
    _outstanding = _outstanding - 1
    if _outstanding == 0 then
      _answer()
    end

  fun ref _requested(user_id: String): Array[String] val =>
    _wanted.get_or_else(user_id, recover val Array[String] end)

  fun ref _answer() =>
    let found = recover iso Array[ClaimedKey] end
    for key in _claimed.values() do
      found.push(key)
    end
    _respond(stallion.StatusOK, KeysClaimed(consume found))

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive _ClaimedDevices
  """
  The devices a `keys/claim` body asks about, by account.

  The algorithm each device is asked for is read and discarded. marilwyd
  holds one kind of one-time key, `signed_curve25519`, because that is the
  only kind clients upload; a request for another would be answered with
  nothing whether or not this compared them, and comparing would only
  change an absent key into a differently absent key.
  """
  fun apply(body: JsonObject): Map[String, Array[String] val] val =>
    let wanted = recover iso Map[String, Array[String] val] end
    try
      match body("one_time_keys")?
      | let accounts: JsonObject =>
        for (user_id, devices) in accounts.pairs() do
          match devices
          | let named: JsonObject =>
            let ids = recover iso Array[String] end
            for device_id in named.keys() do
              ids.push(device_id.clone())
            end
            wanted(user_id.clone()) = consume ids
          end
        end
      end
    end
    consume wanted

class val _SendToDevice
  """
  `PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId}`.

  The channel two devices talk over once they have a session: verification,
  key sharing, and anything else clients say to each other rather than to a
  room. marilwyd carries the content and never reads it.

  `txnId` is routed and not read, the same as a room send. Retrying a
  `sendToDevice` therefore delivers twice, and the messages that travel
  here are the ones a crypto machine already has to tolerate duplicates of.
  """
  let _sessions: SessionRegistry tag

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _SendToDeviceHandler(consume ctx, _sessions)

actor _SendToDeviceHandler is
  (hobby.HandlerReceiver & UserReceiver & UserLookupReceiver)
  embed _handler: hobby.RequestHandler
  let _sessions: SessionRegistry tag
  let _params: Map[String, String] val
  let _body: Array[U8] val
  var _sender: String = ""
  var _kind: String = ""
  embed _messages: Map[String, Array[(String, String)] val] =
    _messages.create()

  new create(ctx: hobby.HandlerContext iso, sessions: SessionRegistry tag) =>
    let supplied = _BearerToken(ctx.request)
    _sessions = sessions
    _params = ctx.params
    _body = ctx.body
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(session: Session) =>
    match \exhaustive\ _PathParam(_params, "eventType")
    | let kind: String =>
      if _body.size() > MaxToDeviceBody() then
        _respond(
          stallion.StatusBadRequest,
          MatrixError("M_BAD_JSON", MalformedKeys.message()))
      else
        _dispatch(session, kind)
      end
    | None =>
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_INVALID_PARAM", "That is not an event type"))
    end

  fun ref _dispatch(session: Session, kind: String) =>
    match JsonParser.parse(String.from_array(_body))
    | let sent: JsonObject =>
      _sender = session.user_id
      _kind = kind
      for (user_id, addressed) in _Addressed(sent).pairs() do
        _messages(user_id) = addressed
      end
      let names = recover iso Array[String] end
      for user_id in _messages.keys() do
        names.push(user_id)
      end
      _sessions.lookup_users(consume names, this)
    else
      _respond(
        stallion.StatusBadRequest,
        MatrixError("M_BAD_JSON", MalformedEvent.message()))
    end

  be users_found(
    known: Array[(String, User tag)] val,
    unknown: Array[String] val)
  =>
    """
    Answered as soon as the messages are handed over, not once they are
    delivered. A device that is offline has its queue filled and reads it
    when it next syncs, so there is nothing further for the sender to wait
    for — and an account marilwyd has never seen is dropped in silence
    rather than reported, which is what stops this enumerating accounts.
    """
    for (user_id, user) in known.values() do
      try
        for (device_id, content) in _messages(user_id)?.values() do
          user.send_to_device(_sender, _kind, device_id, content)
        end
      end
    end
    _respond(stallion.StatusOK, LogoutSuccess())

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  fun ref _respond(status: stallion.Status, body: String) =>
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  be dispose() => None
  be throttled() => None
  be unthrottled() => None

primitive _Addressed
  """
  The devices a `sendToDevice` body names, by account, with what each is
  sent.

  Content is printed here rather than passed on as an object, for the
  reason `_EventContent` gives: what is queued outlives the request that
  carried it.
  """
  fun apply(body: JsonObject): Map[String, Array[(String, String)] val] val =>
    let out = recover iso Map[String, Array[(String, String)] val] end
    try
      match body("messages")?
      | let accounts: JsonObject =>
        for (user_id, devices) in accounts.pairs() do
          match devices
          | let named: JsonObject =>
            let addressed = recover iso Array[(String, String)] end
            for (device_id, content) in named.pairs() do
              match content
              | let o: JsonObject =>
                addressed.push((device_id.clone(), JsonPrinter.print(o)))
              end
            end
            out(user_id.clone()) = consume addressed
          end
        end
      end
    end
    consume out
