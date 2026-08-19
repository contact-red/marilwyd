use "collections"
use "time"

actor Device
  """
  One client of one account: what it has not acknowledged, and its held
  sync if it has one.

  One actor per device id rather than per login, so a client that signs out
  and back in with the id it stored finds the queue that was kept for it.
  Without that the buffer would be unreachable by construction — held for a
  device that could no longer prove it was that device.

  A `Room` never knows this actor exists. Rooms fan out to `User`, which
  fans out here, so devices can come and go without any room holding a
  reference to one — which under ORCA would keep a signed-out device's
  queue alive for as long as the room lived.
  """
  let _id: DeviceId
  let _epoch: StreamEpoch
  var _pending: Pending[RoomEvent] = Pending[RoomEvent]
  var _parked: (SyncReceiver tag | None) = None
  var _parked_since: (USize | None) = None
  // Keyed by room, because a device is in more than one. Held as one
  // array, a second room's state replaced the first's rather than joining
  // it, and a client signing in saw exactly one of its rooms.
  embed _state: Map[String, Array[RoomEvent] val] = _state.create()
  // The position each room's state was last set at, so a client that
  // already has a position is still told about a room it has only just
  // joined. Without it, state travelled on a fresh sync alone and joining
  // a room mid-session produced one with no name and no members.
  embed _described: Map[String, USize] = _described.create()
  var _account: Array[AccountDatum] val =
    recover val Array[AccountDatum] end
  var _account_at: USize = 0
  var _position: USize = 0
  // One-time keys are the one piece of key material that belongs to a
  // device rather than to its account: they are consumed one per session
  // another device opens, so they cannot be shared between the devices of
  // one user the way published identity keys are.
  embed _one_time: Map[String, String] = _one_time.create()
  // To-device messages queue separately from room events because they are
  // acknowledged the same way but read differently: one is history a
  // client displays, the other is a handshake between two devices that
  // marilwyd carries without reading.
  //
  // One queue per sending account, not one queue. Any signed-in account
  // may send to any device it can name, so a single queue would let a
  // stranger push a hundred messages and evict a handshake this device was
  // in the middle of. Separated, the only messages a flood can cost are
  // the flooder's own.
  //
  // Keyed by account rather than by device, and that is what bounds it:
  // accounts come from the credentials file and cannot be created, while
  // anyone may mint devices without limit by signing in again.
  embed _to_device: Map[String, Pending[ToDeviceEvent]] =
    _to_device.create()

  new create(id': DeviceId, epoch: StreamEpoch) =>
    _id = id'
    _epoch = epoch

  be take_one_time_keys(
    keys: Array[(String, String)] val,
    receiver: OneTimeKeyReceiver tag)
  =>
    """
    Add one-time keys to this device's pool and say how many it now holds.

    The count is answered rather than assumed because a client uses it to
    decide whether to upload more, and it is a count of keys marilwyd is
    holding — not of keys it was sent. Keys past the cap are refused, which
    keeps the two the same number.

    Keyed by key id, so a client re-sending one it has already uploaded
    leaves the pool the size it was rather than growing it.
    """
    for (key_id, content) in keys.values() do
      if _one_time.size() >= MaxOneTimeKeys() then
        break
      end
      _one_time(key_id.clone()) = content.clone()
    end
    receiver.one_time_keys_held(_one_time.size())

  be claim_one_time_key(user_id: String, receiver: OneTimeKeyClaimReceiver tag)
  =>
    """
    Hand over one of this device's one-time keys and forget it.

    Spent, not lent. A one-time key names one session, and offering the
    same key twice would let two devices open sessions that each believe
    they are the only one — which is the failure the pool exists to
    prevent. A device that has run out says so rather than staying silent.
    """
    try
      let key_id: String = _any_one_time_key()?
      let content: String = _one_time(key_id)?
      _one_time.remove(key_id)?
      receiver.one_time_key_claimed(
        user_id, _id.string(), key_id, content)
    else
      receiver.one_time_key_missing(user_id, _id.string())
    end

  fun _any_one_time_key(): String ? =>
    """
    Any key id the pool still holds.

    Any, deliberately: the keys are interchangeable, none is older or
    better than another, and nothing about which one is handed over is
    observable to either device.
    """
    for key_id in _one_time.keys() do
      return key_id
    end
    error

  be deliver_to_device(event: ToDeviceEvent) =>
    """
    Take a message another device addressed to this one.
    """
    _position = _position + 1
    let queue =
      try
        _to_device(event.sender)?
      else
        Pending[ToDeviceEvent]
      end
    _to_device(event.sender) = queue.push(_position, event, ToDeviceLimit())
    _wake()

  be deliver(event: RoomEvent) =>
    """
    Take an event this device's user is entitled to.
    """
    // The device's own position, which advances for anything a client
    // needs to know about — not only events. Account data is the other
    // one, and deriving a position from the queue's length would miss it.
    _position = _position + 1
    _pending = _pending.push(_position, event)
    _wake()

  be room_state(room_id: String, state': Array[RoomEvent] val) =>
    """
    Replace what this device would be told about one room on a fresh sync.

    Held here rather than fetched at sync time so an initial sync needs no
    round trip to every room the user is in. Per room, because replacing
    the lot is what made a device in two rooms see one of them.

    Stamped and woken like anything else a client needs to know about: a
    room described after the position a client holds is a room that client
    has not been told about yet.
    """
    let key: String = room_id.clone()
    _state(key) = state'
    _position = _position + 1
    _described(key) = _position
    _wake()

  be forget_room(room_id: String) =>
    """
    Drop a room this device's account has left.

    Necessary rather than tidy: state is now kept per room, so a room left
    behind would go on being described to this device on every fresh sync
    for as long as the process ran. Holding one array hid that, by
    discarding everything on the next room's arrival.
    """
    try
      (_, _) = _state.remove(room_id)?
    end
    try
      (_, _) = _described.remove(room_id)?
    end

  be account_data(data: Array[AccountDatum] val) =>
    """
    Replace what this device is owed about its account's data.

    Stamped with the current position, so a sync includes it exactly when
    the client's position predates the change — the same rule room state
    uses, and one that survives a response being lost, since the client's
    position only advances when it asks for what comes after it.
    """
    _account = data
    _position = _position + 1
    _account_at = _position
    _wake()

  be sync(since: (USize | None), wait: U64, receiver: SyncReceiver tag) =>
    """
    Answer what is owed, or hold the request until something is.
    """
    // Asking for what comes after a position is how a client confirms it
    // received everything up to it.
    _pending = _pending.acknowledged(since)
    _acknowledge_to_device(since)

    if (_pending.size() > 0) or (_to_device_waiting() > 0) or (wait == 0)
      or (since is None) or _account_unseen(since)
      or (_describing(since).size() > 0)
    then
      _answer(receiver, since)
    else
      _parked = receiver
      // Kept, because a woken sync is a continuation of the one that
      // parked — not a fresh one. Answering it as fresh would re-send the
      // room state the client already has, on every message it receives.
      _parked_since = since
    end

  be expired(receiver: SyncReceiver tag) =>
    """
    The handler's deadline arrived. Answer with whatever there is, which
    for a client in a quiet room is nothing but a position.
    """
    if _parked is receiver then
      let since = _parked_since
      _parked = None
      _parked_since = None
      _answer(receiver, since)
    end

  be abandon(receiver: SyncReceiver tag) =>
    """
    The connection went away before the deadline did.
    """
    if _parked is receiver then
      _parked = None
      _parked_since = None
    end

  fun ref _acknowledge_to_device(since: (USize | None)) =>
    """
    Drop what every sender's queue has had confirmed.

    An emptied queue is left in place rather than removed. Nothing could
    observe the difference — a queue answers from a position, so an
    acknowledged message is filtered out whether or not its queue is still
    there — and there is nothing to reclaim: a sender is an account, and
    accounts come from the credentials file, so the map is bounded by that
    file however long the process runs.
    """
    for (sender, queue) in _to_device.pairs() do
      _to_device(sender) = queue.acknowledged(since)
    end

  fun _to_device_waiting(): USize =>
    var waiting: USize = 0
    for queue in _to_device.values() do
      waiting = waiting + queue.size()
    end
    waiting

  fun _to_device_dropped(): USize =>
    var dropped: USize = 0
    for queue in _to_device.values() do
      dropped = dropped + queue.dropped()
    end
    dropped

  fun _to_device_since(since: (USize | None)): Array[ToDeviceEvent] val =>
    """
    Every sender's owed messages, back in the order they arrived.

    Each queue is already in position order, so this repeatedly takes
    whichever queue's next message is earliest. Order within one sender is
    what matters to a crypto machine — a handshake is a sequence — and
    merging on the device position preserves the order across senders too.

    The work is the messages owed times the senders owing them. Both are
    bounded — `ToDeviceLimit()` per sender, and a sender is an account —
    so the worst case needs every account on the server to be mid-flood at
    one device, and it is paid by that device alone. In ordinary use a
    device hears from one or two accounts at a time.
    """
    let slices = Array[Array[(USize, ToDeviceEvent)] val]
    for queue in _to_device.values() do
      let slice = queue.paired(since)
      if slice.size() > 0 then
        slices.push(slice)
      end
    end

    let cursors = Array[USize].init(0, slices.size())
    let merged = recover iso Array[ToDeviceEvent] end
    var taken: USize = 0
    var total: USize = 0
    for slice in slices.values() do
      total = total + slice.size()
    end

    while taken < total do
      var best: (USize | None) = None
      var best_at: USize = 0
      for (index, slice) in slices.pairs() do
        try
          let cursor = cursors(index)?
          if cursor < slice.size() then
            (let at: USize, _) = slice(cursor)?
            if (best is None) or (at < best_at) then
              best = index
              best_at = at
            end
          end
        end
      end
      match best
      | let index: USize =>
        try
          let cursor = cursors(index)?
          (_, let event: ToDeviceEvent) = slices(index)?(cursor)?
          merged.push(event)
          cursors(index)? = cursor + 1
        end
        taken = taken + 1
      else
        // Unreachable: `taken < total` means some queue still has one.
        break
      end
    end
    consume merged

  fun _describing(since: (USize | None)): Array[RoomEvent] val =>
    """
    The state of every room this client has not been told about yet.

    Everything on a fresh sync, and on an incremental one the rooms
    described since the position the client gave — which is how a room
    joined mid-session arrives with its name and its members rather than
    as a bare id.
    """
    let found = recover iso Array[RoomEvent] end
    for (room_id, events) in _state.pairs() do
      let unseen =
        match since
        | let given: USize => _described.get_or_else(room_id, 0) > given
        else
          true
        end
      if unseen then
        for event in events.values() do
          found.push(event)
        end
      end
    end
    consume found

  fun _account_unseen(since: (USize | None)): Bool =>
    """
    Whether the account data changed after the position the client gave.
    """
    match since
    | let n: USize => _account_at > n
    else
      _account.size() > 0
    end

  fun ref _wake() =>
    match _parked
    | let receiver: SyncReceiver tag =>
      let since = _parked_since
      _parked = None
      _parked_since = None
      _answer(receiver, since)
    end

  fun ref _answer(receiver: SyncReceiver tag, since: (USize | None)) =>
    let owed = _pending.since(since)
    // State travels only when the client has no usable position. A client
    // that is up to date has already been told, and a state change since
    // then arrived as an ordinary event.
    let state' = _describing(since)
    let account =
      if _account_unseen(since) then
        _account
      else
        recover val Array[AccountDatum] end
      end

    receiver.synced(
      SyncView(
        StreamPositionText(_epoch, _position),
        owed,
        state',
        account,
        _to_device_since(since),
        (_pending.dropped() + _to_device_dropped()) > 0))
