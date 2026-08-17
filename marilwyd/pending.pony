use per = "collections/persistent"

primitive PendingLimit
  """
  How many undelivered events one device accumulates before the oldest are
  dropped.

  A device that is offline is the only thing in marilwyd that grows without
  anyone asking it to, so this is the bound that matters. A count rather
  than an age: it bounds what actually occupies memory, needs no clock, and
  is testable by pushing one event past it.
  """
  fun apply(): USize => 1000

class val Pending
  """
  What one device has not acknowledged yet.

  Events are held until the client comes back with a position at or past
  them, not until they are first sent. A response lost in transit would
  otherwise take its events with it, and the client would have no way to
  discover the loss — its next sync would carry a position the server had
  already discarded.

  A persistent vector, so handing a device the events it is owed leaves the
  queue valid while the next arrival builds a version sharing almost all of
  its structure. The events are `val` and shared: three devices owed the
  same ten messages hold ten events and three spines of pointers, and ORCA
  traces the one copy.
  """
  let _events: per.Vec[RoomEvent]
  let _base: USize
  let _dropped: USize

  new val create() =>
    _events = per.Vec[RoomEvent]
    _base = 0
    _dropped = 0

  new val _from(
    events': per.Vec[RoomEvent],
    base': USize,
    dropped': USize)
  =>
    _events = events'
    _base = base'
    _dropped = dropped'

  fun val position(): USize =>
    """
    The position a client is given as `next_batch`, and hands back as
    `since`. Counts every event ever queued for this device.
    """
    _base + _events.size()

  fun val push(event: RoomEvent, limit: USize = PendingLimit()): Pending =>
    """
    Add an event, dropping the oldest if that puts the queue over its limit.

    Dropping rather than refusing: the alternative would let one sleeping
    device stop a room delivering to everyone else, which is a worse
    failure than a device missing what it was too long away to receive.
    """
    let grown = _events.push(event)
    if grown.size() <= limit then
      Pending._from(grown, _base, _dropped)
    else
      let excess = grown.size() - limit
      try
        Pending._from(
          grown.remove(0, excess)?, _base + excess, _dropped + excess)
      else
        Pending._from(grown, _base, _dropped)
      end
    end

  fun val since(n: (USize | None)): Array[RoomEvent] val =>
    """
    Everything after `n`, or everything held when the position is unusable.

    A position below what is still held names events that are gone, and is
    answered the same way as no position at all — with what there is.
    """
    // A position below what is still held names events that are gone; one
    // above `position()` names events this device has never had. Both are
    // unusable and both are answered the same way — with everything there
    // is — because a client cannot tell them apart and neither can be
    // repaired by sending less.
    let from =
      match n
      | let given: USize
        if (given >= _base) and (given <= position()) => given - _base
      else
        USize(0)
      end

    let found = recover iso Array[RoomEvent] end
    var i = from
    while i < _events.size() do
      try found.push(_events(i)?) end
      i = i + 1
    end
    consume found

  fun val acknowledged(n: (USize | None)): Pending =>
    """
    Drop everything at or before `n`, which the client has confirmed by
    asking for what comes after it.
    """
    match n
    | let given: USize if given > _base =>
      let drop = (given - _base).min(_events.size())
      try
        Pending._from(_events.remove(0, drop)?, _base + drop, _dropped)
      else
        this
      end
    else
      this
    end

  fun val size(): USize =>
    _events.size()

  fun val dropped(): USize =>
    """
    How many events were discarded for being too far behind. A device that
    finds this above zero has a gap nothing in marilwyd can fill.
    """
    _dropped

  fun val events(): Array[RoomEvent] val =>
    since(None)
