interface tag DeclaredChannelReceiver
  """
  Something waiting to be told about a room declared in the configuration.
  """
  be channel_declared(channel: BridgedChannel, network: BridgedNetwork)
    """
    A channel was declared. No room exists for it yet — one is made for
    each person who enters it.
    """

  be declaration_refused(channel: String)
    """
    The room could not be made — a room id could not be minted, or the id
    or alias the file declared is already in use.
    """
