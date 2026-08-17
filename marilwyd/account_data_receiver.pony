interface tag AccountDataReceiver
  """
  Something waiting for one piece of an account's data.
  """
  be account_datum_found(content: String)
    """
    The content stored under the type that was asked for.
    """

  be account_datum_missing()
    """
    Nothing is stored under that type.
    """
