class val SyncView
  """
  What one device is owed at one moment.

  Data, not a document: the handler renders it, so rendering happens on a
  per-request actor rather than on any of the shared ones.
  """
  let next_batch: String
  let events: Array[RoomEvent] val
  let state: Array[RoomEvent] val
  let account: Array[AccountDatum] val
  let to_device: Array[ToDeviceEvent] val
  let ephemeral: Array[(String, Ephemeral)] val
  // Rooms this device has been invited to and has not answered. Their
  // state and nothing else: an invitation carries enough to decide by —
  // the room's name, who asked — and none of what is said in it, because
  // the holder is not in it yet.
  let invites: Array[(String, Array[RoomEvent] val)] val
  let gap: Bool

  new val create(
    next_batch': String,
    events': Array[RoomEvent] val,
    state': Array[RoomEvent] val,
    account': Array[AccountDatum] val,
    to_device': Array[ToDeviceEvent] val,
    ephemeral': Array[(String, Ephemeral)] val,
    invites': Array[(String, Array[RoomEvent] val)] val,
    gap': Bool)
  =>
    next_batch = next_batch'
    events = events'
    state = state'
    account = account'
    to_device = to_device'
    ephemeral = ephemeral'
    invites = invites'
    gap = gap'
