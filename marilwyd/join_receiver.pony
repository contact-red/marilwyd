interface tag JoinReceiver
  """
  Something waiting to learn whether a bridged room may be entered.
  """
  be joined_with(channel: String, link: UserLink tag)
    """
    The channel was joined, so the Matrix room may be too — and this is
    the connection that will carry what its owner says.
    """

  be join_allowed(channel: String)
    """
    The channel was already open, so nothing new was connected.
    """

  be join_refused(channel: String)
    """
    It was not, so the user is not in the room at all.
    """
