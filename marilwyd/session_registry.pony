use "collections"

actor SessionRegistry
  """
  Who is logged in, for as long as this process runs.

  Nothing is written to disk, so no session survives a restart. A session
  also ends when its own client calls `POST /logout`, or when another of
  that account's clients deletes its device. Nothing else ends one: there is
  no expiry, a login never reuses a device a client asks for, and there is
  no `/logout/all`, so the count only falls when a client asks it to.

  One session is one device. Signing in twice — a browser and a phone, or
  two browsers — produces two sessions for the same user, each with its own
  token and its own device id, and ending either leaves the other alone.

  Tokens are compared one at a time in constant time rather than looked up
  by key, so verifying a token cannot leak where it first differs from a
  real one. That costs 0.45 microseconds per stored session, measured. Since
  `/sync` long-polls, every signed-in client pays a scan every 25 seconds
  against every session stored, so the work is quadratic in sessions and
  falls on one actor: roughly 7,500 concurrent sessions saturate a core. The
  property does not require the scan — splitting a token into a public
  selector to key on and a secret verifier to compare would be O(1) and
  still constant-time in the part that matters.
  """
  embed _sessions: Array[_Session] = _sessions.create()

  be issue(user_id: String, receiver: TokenReceiver tag) =>
    """
    Mint a token and a device for `user_id` and remember both.
    """
    match (MakeAccessToken(), MakeDeviceId())
    | (let token: AccessToken, let device: DeviceId) =>
      // `user_id.clone()` is load-bearing. Under ORCA a foreign reference to
      // an object keeps its owning actor alive, so storing the caller's
      // String would pin the handler actor that minted it — and through that
      // handler, its connection and the request body, which holds the
      // plaintext password. Measured: ~143 kB retained per login, forever.
      _sessions.push(_Session(token, user_id.clone(), device))
      receiver.token_issued(token, device)
    else
      // Fail closed. There is no weaker credential worth issuing.
      receiver.token_refused()
    end

  be resolve(supplied: String, receiver: UserReceiver tag) =>
    """
    Answer who holds `supplied`, and which of their devices it belongs to.
    """
    for session in _sessions.values() do
      if session.token.matches(supplied) then
        receiver.token_resolved(session.user_id, session.device)
        return
      end
    end
    receiver.token_rejected()

  be devices(supplied: String, receiver: DeviceReceiver tag) =>
    """
    List every device belonging to whoever holds `supplied`.

    Only their own. A device id is a public label within an account, but
    the set of an account's devices is not something another account may
    enumerate.
    """
    for session in _sessions.values() do
      if session.token.matches(supplied) then
        let owner = session.user_id
        // Built as `iso` and consumed rather than assembled in a `recover`
        // block, which cannot reach `_sessions` at all. `DeviceId` is `val`,
        // so collecting them into an isolated array shares nothing.
        let found = recover iso Array[DeviceId] end
        for other in _sessions.values() do
          if other.user_id == owner then
            found.push(other.device)
          end
        end
        receiver.devices_listed(consume found)
        return
      end
    end
    receiver.devices_refused()

  be revoke(supplied: String, receiver: RevocationReceiver tag) =>
    """
    End the session that holds `supplied` — the caller's own.

    A held `/sync` belonging to that session runs to completion: it answers
    its empty document when its deadline arrives, up to `MaxSyncWait()`
    later, and the request after that is the one refused. Revocation is
    therefore not instant for a client that is mid-poll.
    """
    for (index, session) in _sessions.pairs() do
      if session.token.matches(supplied) then
        if _remove(index) then
          receiver.session_revoked()
        else
          receiver.revocation_rejected()
        end
        return
      end
    end
    receiver.revocation_rejected()

  be revoke_devices(
    supplied: String,
    device_ids: Array[String] val,
    receiver: RevocationReceiver tag)
  =>
    """
    End the sessions for `device_ids` that belong to whoever holds
    `supplied`.

    Scoped to the supplied token's own user. A device id is a public label,
    so without that scope one account could end another's sessions by
    naming ten hex characters — and once the crypto endpoints publish
    device ids to everyone in a shared room, naming them stops requiring a
    guess at all. The ownership check is the whole barrier, not a second
    one behind entropy.

    Answers `session_revoked` if the token was good, whatever was or was
    not found. Deleting a device that is already gone is the state the
    caller asked for, and reporting the difference would say which ids are
    in use. A list naming a mix of one's own and another's devices removes
    the former and ignores the latter.
    """
    var owner: (String | None) = None
    for session in _sessions.values() do
      if session.token.matches(supplied) then
        owner = session.user_id
        break
      end
    end

    match owner
    | let user_id: String =>
      for device_id in device_ids.values() do
        _remove_device(user_id, device_id)
      end
      receiver.session_revoked()
    else
      receiver.revocation_rejected()
    end

  fun ref _remove_device(user_id: String, device_id: String) =>
    """
    Drop `user_id`'s session for `device_id`, if they have one.

    Stops at the first match, which is what keeps the enclosing loop safe:
    `Array.delete` compacts, and `ArrayValues` does not adjust its cursor
    for that, so an iteration that continued after removing would skip the
    next session. Any future bulk operation must remove one per pass for
    the same reason.
    """
    for (index, session) in _sessions.pairs() do
      if session.device.matches(device_id) and (session.user_id == user_id)
      then
        _remove(index)
        return
      end
    end

  fun ref _remove(index: USize): Bool =>
    """
    Drop one session, reporting whether it went.

    The caller answers a client with it: telling someone their session was
    revoked when it was not is the one failure worth being sure about, so
    success is derived rather than assumed.
    """
    try
      _sessions.delete(index)?
      true
    else
      false
    end

class val _Session
  """
  One signed-in device: the token that proves it, who it belongs to, and
  which of their devices it is.
  """
  let token: AccessToken
  let user_id: String
  let device: DeviceId

  new val create(token': AccessToken, user_id': String, device': DeviceId) =>
    token = token'
    user_id = user_id'
    device = device'
