actor SessionRegistry
  """
  Who is logged in, for as long as this process runs.

  Nothing is written to disk, so a restart logs everyone out. That is the
  whole persistence story for this increment, and it is deliberate: there is
  nothing here worth persisting until rooms and events exist.

  Tokens are compared one at a time in constant time rather than looked up by
  key, so verifying a token cannot leak where it first differs from a real
  one. That makes resolution O(sessions); with a handful of logins on a
  personal homeserver it is not worth trading the property away. Revisit when
  a session count makes the scan measurable.
  """
  embed _sessions: Array[(AccessToken, String)] = _sessions.create()

  be issue(user_id: String, receiver: TokenReceiver tag) =>
    """
    Mint a token for `user_id` and remember it.
    """
    match MakeAccessToken()
    | let token: AccessToken =>
      match MakeAccessToken()
      | let device: AccessToken =>
        _sessions.push((token, user_id))
        receiver.token_issued(token, device.reveal().trim(0, 10))
      | NoSecureRandom => receiver.token_refused()
      end
    | NoSecureRandom =>
      // Fail closed. There is no weaker token worth issuing.
      receiver.token_refused()
    end

  be resolve(supplied: String, receiver: UserReceiver tag) =>
    """
    Answer who holds `supplied`, if anyone does.
    """
    for (token, user_id) in _sessions.values() do
      if token.matches(supplied) then
        receiver.token_resolved(user_id)
        return
      end
    end
    receiver.token_rejected()
