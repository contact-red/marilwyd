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

class val Pending[A: Any val]
  """
  What one device has not acknowledged yet.

  Generic over what is queued because a device holds two of these and the
  hard part is the same for both: an entry is kept until the client comes
  back with a position past it, the queue is bounded, and going over the
  bound is a fact the device remembers. Room events and to-device messages
  differ only in what a client does with them.

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
  let _events: per.Vec[(USize, A)]
  let _dropped: USize

  new val create() =>
    _events = per.Vec[(USize, A)]
    _dropped = 0

  new val _from(events': per.Vec[(USize, A)], dropped': USize) =>
    _events = events'
    _dropped = dropped'

  fun val push(
    at: USize,
    event: A,
    limit: USize = PendingLimit())
    : Pending[A]
  =>
    """
    Add an event, dropping the oldest if that puts the queue over its limit.

    Dropping rather than refusing: the alternative would let one sleeping
    device stop a room delivering to everyone else, which is a worse
    failure than a device missing what it was too long away to receive.
    """
    let grown = _events.push((at, event))
    if grown.size() <= limit then
      Pending[A]._from(grown, _dropped)
    else
      let excess = grown.size() - limit
      try
        Pending[A]._from(grown.remove(0, excess)?, _dropped + excess)
      else
        Pending[A]._from(grown, _dropped)
      end
    end

  fun val since(n: (USize | None)): Array[A] val =>
    """
    Everything after `n`, or everything held when the position is unusable.

    A position below what is still held names events that are gone, and is
    answered the same way as no position at all — with what there is.
    """
    // Each entry carries the device position it was queued at, so a
    // client's `since` is compared rather than turned into an index. That
    // matters because a device's position advances for things that are not
    // events — a change to the account's data is one — so an index derived
    // from a position would drift the moment one happened.
    let found = recover iso Array[A] end
    for (at, event) in _events.values() do
      match n
      | let given: USize if at <= given => None
      else
        found.push(event)
      end
    end
    consume found

  fun val acknowledged(n: (USize | None)): Pending[A] =>
    """
    Drop everything at or before `n`, which the client has confirmed by
    asking for what comes after it.
    """
    match n
    | let given: USize =>
      var drop: USize = 0
      for (at, _) in _events.values() do
        if at <= given then
          drop = drop + 1
        end
      end
      if drop == 0 then
        this
      else
        try
          Pending[A]._from(_events.remove(0, drop)?, _dropped)
        else
          this
        end
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

  fun val events(): Array[A] val =>
    since(None)
