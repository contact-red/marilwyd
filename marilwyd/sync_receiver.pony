interface tag SyncReceiver
  """
  Something waiting to be told what a device is owed.
  """
  be synced(view: SyncView)
    """
    What the device is owed, and the position to send back next time.
    """
