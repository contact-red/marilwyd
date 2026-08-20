interface tag LinkOwner
  """
  Whatever holds a connection and must drop it when it dies.

  An interface rather than `LinkDirectory` itself so that the death path
  can be driven without opening a socket. That path is the one this
  design turns on — a connection that dies without saying so is answered
  to the next join as though it were alive — and it was previously
  reachable only by making a real network fail.
  """
  be forget(user_id: String, network: String, channel: String)
    """
    This connection is finished. Drop it, so the next join opens a fresh
    one instead of being answered with this.
    """
