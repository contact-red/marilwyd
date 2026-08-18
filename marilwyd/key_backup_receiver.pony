interface tag KeyBackupReceiver
  """
  Something waiting to be told about an account's room key backup.
  """
  be backup_created(version: String)
    """
    A new version was recorded, and this is what it is called.
    """

  be backup_found(backup: KeyBackup, version: String)
    """
    The most recent version, and the description the client gave for it.
    """

  be backup_missing()
    """
    This account has made no backup.
    """
