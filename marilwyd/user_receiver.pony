interface tag UserReceiver
  """
  Something waiting to be told who a token belongs to.
  """
  be token_resolved(user_id: String)
    """
    The token belongs to `user_id`.
    """

  be token_rejected()
    """
    No live session holds that token.
    """
