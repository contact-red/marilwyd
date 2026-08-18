interface tag RoomSummaryReceiver
  """
  Something waiting for one room's description.
  """
  be room_summarised(summary: RoomSummary)
    """
    What the room is called, and how many people are in it.
    """
