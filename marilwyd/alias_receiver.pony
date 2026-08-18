interface tag AliasReceiver
  """
  Something waiting to learn which room an alias names.
  """
  be alias_resolved(room_id: String)
    """
    The alias names this room.
    """

  be alias_unknown()
    """
    No room on this server answers to that alias.
    """

interface tag PublishedRoomsReceiver
  """
  Something waiting for the rooms in the public directory.
  """
  be rooms_published(rooms: Array[Room tag] val)
    """
    Every published room, for the caller to ask each what it is.
    """
