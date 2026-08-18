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

interface tag UserLookupReceiver
  """
  Something waiting to be told which of the accounts it named are held.
  """
  be users_found(
    known: Array[(String, User tag)] val,
    unknown: Array[String] val)
    """
    The accounts marilwyd holds, paired with their actors, and the names it
    holds nothing for.
    """
