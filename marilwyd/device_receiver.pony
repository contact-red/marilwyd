interface tag DeviceReceiver
  """
  Something waiting to be told which devices an account has.
  """
  be devices_listed(found: Array[DeviceId] val)
    """
    Every device belonging to the token's own user, in the order the
    sessions were issued.
    """

  be devices_refused()
    """
    No live session holds that token, so there is no account to list.
    """
