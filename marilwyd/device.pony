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
  var _pending: Pending = Pending
  var _parked: (SyncReceiver tag | None) = None
  var _parked_since: (USize | None) = None
  var _state: Array[RoomEvent] val = recover val Array[RoomEvent] end
  var _account: Array[AccountDatum] val =
    recover val Array[AccountDatum] end
  var _account_at: USize = 0
  var _position: USize = 0
  // One-time keys are the one piece of key material that belongs to a
  // device rather than to its account: they are consumed one per session
  // another device opens, so they cannot be shared between the devices of
  // one user the way published identity keys are.
  embed _one_time: Map[String, String] = _one_time.create()

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

  be room_state(state': Array[RoomEvent] val) =>
    """
    Replace the state this device would be told about on a fresh sync.

    Held here rather than fetched at sync time so an initial sync needs no
    round trip to every room the user is in.
    """
    _state = state'

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

    if (_pending.size() > 0) or (wait == 0) or (since is None)
      or _account_unseen(since)
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
    let state' =
      match since
      | let _: USize => recover val Array[RoomEvent] end
      else
        _state
      end
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
        _pending.dropped() > 0))
