interface tag ChannelListReceiver
  """
  Something waiting for the channels an operator declared.
  """
  be channels_listed(channels: Array[BridgedChannel] val)
    """
    Every declared channel, whether or not anyone has entered one.
    """
