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
  let gap: Bool

  new val create(
    next_batch': String,
    events': Array[RoomEvent] val,
    state': Array[RoomEvent] val,
    account': Array[AccountDatum] val,
    to_device': Array[ToDeviceEvent] val,
    gap': Bool)
  =>
    next_batch = next_batch'
    events = events'
    state = state'
    account = account'
    to_device = to_device'
    gap = gap'
