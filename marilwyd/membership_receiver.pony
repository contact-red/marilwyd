interface tag MembershipReceiver
  """
  Something waiting to be told a membership change took effect.
  """
  be membership_changed(room: RoomId)
    """
    The caller is now in the room, or has left it.

    One behaviour for both because the specification gives each the same
    answer — an empty body naming the room — and a handler that had to tell
    them apart would be inventing a distinction no client reads.
    """

  be membership_refused(why: NotInvited)
    """
    The room would not have them, and this is why.
    """
