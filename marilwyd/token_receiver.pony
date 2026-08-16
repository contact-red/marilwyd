interface tag TokenReceiver
  """
  Something waiting to be told whether a token was issued.
  """
  be token_issued(token: AccessToken, device_id: String)
    """
    A token was minted and recorded.
    """

  be token_refused()
    """
    No token could be minted. There is no weaker one worth issuing.
    """
