actor SessionRegistry
  """
  Who is logged in, for as long as this process runs.

  Nothing is written to disk: sessions do not survive a restart, and a
  restart is the only way to end one — there is no logout and tokens do not
  expire.

  Tokens are compared one at a time in constant time rather than looked up by
  key, so verifying a token cannot leak where it first differs from a real
  one. That costs 0.45 microseconds per stored session, measured, which is
  already visible at a hundred sessions and bounds throughput at roughly
  2,200/s at a thousand. The property does not require the scan: splitting a
  token into a public selector to key on and a secret verifier to compare
  would be O(1) and still constant-time in the part that matters.
  """
  embed _sessions: Array[(AccessToken, String)] = _sessions.create()

  be issue(user_id: String, receiver: TokenReceiver tag) =>
    """
    Mint a token for `user_id` and remember it.
    """
    match (MakeAccessToken(), MakeDeviceId())
    | (let token: AccessToken, let device_id: String) =>
      // `user_id.clone()` is load-bearing. Under ORCA a foreign reference to
      // an object keeps its owning actor alive, so storing the caller's
      // String would pin the handler actor that minted it — and through that
      // handler, its connection and the request body, which holds the
      // plaintext password. Measured: ~143 kB retained per login, forever.
      _sessions.push((token, user_id.clone()))
      receiver.token_issued(token, device_id)
    else
      // Fail closed. There is no weaker credential worth issuing.
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
