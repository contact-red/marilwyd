interface tag PublishedKeysReceiver
  """
  Something waiting to be told what one account has published.
  """
  be keys_published(user_id: String, keys: PublishedKeys)
    """
    The account's device keys and whichever cross-signing keys it may see.
    """

interface tag OneTimeKeyReceiver
  """
  Something waiting to be told how many one-time keys a device holds.
  """
  be one_time_keys_held(count: USize)
    """
    The size of the pool after an upload, which is what a client reads to
    decide whether to send more.
    """
