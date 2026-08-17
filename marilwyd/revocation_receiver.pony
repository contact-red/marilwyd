interface tag RevocationReceiver
  """
  Something waiting to be told whether a session was ended.
  """
  be session_revoked()
    """
    The request was carried out. Also the answer when a named device was
    already absent, or belongs to another account, since neither is a
    state the caller can be told apart from success without learning which
    device ids are in use.
    """

  be revocation_rejected()
    """
    The token offered does not belong to a live session, so there was
    nothing to end and no user to scope a device deletion to.
    """
