interface tag BridgeReceiver
  """
  Something waiting to learn whether a room carries an IRC channel.
  """
  be room_is_bridged(channel: BridgedChannel, network: BridgedNetwork)
    """
    It does, and entering it means connecting to that network.
    """

  be room_is_local()
    """
    It does not, so joining is marilwyd's business alone.
    """
