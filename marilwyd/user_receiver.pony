interface tag UserReceiver
  """
  Something waiting to be told whose token it is holding.
  """
  be token_resolved(session: Session)
    """
    The token belongs to this session — a user, one of their devices, and
    the actors that own each.
    """

  be token_rejected()
    """
    No live session holds that token.
    """
