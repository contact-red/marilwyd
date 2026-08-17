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

  new create(id': String) =>
    id = id'

  be attach(device_id: String, device: Device tag) =>
    """
    Register a device, or re-register one that signed back in.

    Idempotent by key: a device that reconnects with the id it stored
    replaces its own entry and keeps everything the actor was holding.
    """
    _devices(device_id) = device
    // A returning device knows nothing about the rooms joined while it was
    // away, so it is told the current state of each.
    for (room_id, room) in _rooms.pairs() do
      room.describe(device)
    end

  be detach(device_id: String) =>
    """
    Forget a device. Its actor becomes unreachable from here, and nothing
    else holds it, so its queue goes with it.
    """
    try
      (_, _) = _devices.remove(device_id)?
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

  be rooms(receiver: RoomListReceiver tag) =>
    let found = recover iso Array[String] end
    for room_id in _rooms.keys() do
      found.push(room_id)
    end
    receiver.rooms_listed(consume found)
