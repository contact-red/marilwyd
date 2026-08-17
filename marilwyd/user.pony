use "collections"

actor User
  """
  One account: which rooms it is in, and which devices are signed in to it.

  It exists so that a `Room` has one target that does not change. Membership
  is a fact about a user, and a device signing in or out is not a membership
  change — if rooms held device references instead, every login would have
  to find every room the user is in, every logout would have to be removed
  from all of them, and until it was, ORCA would keep the signed-out
  device's queue alive because a room still pointed at it.

  Fanning out here rather than in the room is also what keeps a room's cost
  proportional to its members rather than to their devices.
  """
  let id: String
  embed _devices: Map[String, Device tag] = _devices.create()
  embed _rooms: Map[String, Room tag] = _rooms.create()
  embed _account: Map[String, String] = _account.create()

  new create(id': String) =>
    id = id'

  be attach(device_id: String, device: Device tag) =>
    """
    Register a device, or re-register one that signed back in.

    Idempotent by key: a device that reconnects with the id it stored
    replaces its own entry and keeps everything the actor was holding.
    """
    _devices(device_id) = device
    // A returning device knows nothing about what happened while it was
    // away, so it is told the current state of each room and the account's
    // data as it stands.
    for (room_id, room) in _rooms.pairs() do
      room.describe(device)
    end
    if _account.size() > 0 then
      device.account_data(_snapshot())
    end

  be detach(device_id: String) =>
    """
    Forget a device. Its actor becomes unreachable from here, and nothing
    else holds it, so its queue goes with it.
    """
    try
      (_, _) = _devices.remove(device_id)?
    end

  be set_account_data(kind: String, content: String) =>
    """
    Store one piece of account data and tell every device.

    Cloned on the way in, because this actor outlives the handler that read
    the request — a stored foreign reference would keep that handler, its
    connection and its request body alive.
    """
    _account(kind.clone()) = content.clone()
    let snapshot = _snapshot()
    for device in _devices.values() do
      device.account_data(snapshot)
    end

  be account_datum(kind: String, receiver: AccountDataReceiver tag) =>
    """
    Answer one piece of account data.

    Element reads account data from its local store once its first sync
    completes, so this endpoint is only reached before that. It exists
    because that window is real, not because anything polls it.
    """
    try
      receiver.account_datum_found(_account(kind)?)
    else
      receiver.account_datum_missing()
    end

  be joined(room_id: String, room: Room tag) =>
    _rooms(room_id) = room
    for device in _devices.values() do
      room.describe(device)
    end

  be departed(room_id: String) =>
    try
      (_, _) = _rooms.remove(room_id)?
    end

  be deliver(event: RoomEvent) =>
    """
    Hand an event to every device signed in to this account.

    One event object, however many devices: `RoomEvent` is `val`, so this
    shares rather than copies.
    """
    for device in _devices.values() do
      device.deliver(event)
    end

  fun _snapshot(): Array[AccountDatum] val =>
    let found = recover iso Array[AccountDatum] end
    for (kind, content) in _account.pairs() do
      found.push(AccountDatum(kind, content))
    end
    consume found

  be rooms(receiver: RoomListReceiver tag) =>
    let found = recover iso Array[String] end
    for room_id in _rooms.keys() do
      found.push(room_id)
    end
    receiver.rooms_listed(consume found)
