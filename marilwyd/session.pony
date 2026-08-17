class val Session
  """
  Everything a handler needs about who is making a request.

  The two actor tags travel with the identity because every handler that
  does more than answer a constant needs one of them: a room join needs the
  `User` so the room has a stable target, and a sync needs the `Device` so
  it can be parked. Resolving a token is already a scan, and this is what
  stops a handler paying for a second one.
  """
  let user_id: String
  let device: DeviceId
  let user: User tag
  let stream: Device tag

  new val create(
    user_id': String,
    device': DeviceId,
    user': User tag,
    stream': Device tag)
  =>
    user_id = user_id'
    device = device'
    user = user'
    stream = stream'
