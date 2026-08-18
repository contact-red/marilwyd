interface tag OneTimeKeyClaimReceiver
  """
  Something waiting to be handed one device's one-time key.
  """
  be one_time_key_claimed(
    user_id: String,
    device_id: String,
    key_id: String,
    content: String)
    """
    A key was held and has now been spent. It will not be offered again.
    """

  be one_time_key_missing(user_id: String, device_id: String)
    """
    That device has no unclaimed key left, or marilwyd has never seen it.

    Reported rather than left silent because a claim answers about every
    device it was asked about, and a caller counting replies would wait
    forever for a device that does not exist.
    """
