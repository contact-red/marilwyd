use "collections"
use "json"

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
  // Published keys are account-wide public data rather than device session
  // state: another user queries them by account, and they must outlive a
  // device being offline. They are removed when the device is deleted, not
  // when it signs out.
  embed _keys: Map[String, String] = _keys.create()
  var _master: (String | None) = None
  var _self_signing: (String | None) = None
  var _user_signing: (String | None) = None
  embed _backups: Array[KeyBackup] = _backups.create()

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

  be forget_device(device_id: String) =>
    """
    A device was deleted. Drop it and everything it published.

    Not what signing out does. A client that signs out and back in naming
    the id it stored is meant to find what was kept for it, so only an
    explicit deletion reaches here.

    Its keys go with it, and that is the part that matters to other people:
    keys published for a device that no longer exists tell everyone else to
    encrypt to something that can never read what they send.
    """
    try
      (_, _) = _devices.remove(device_id)?
    end
    try
      (_, _) = _keys.remove(device_id)?
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

  be publish_keys(device_id: String, keys: String) =>
    """
    Publish one device's identity keys.

    Cloned for the reason `set_account_data` gives.
    """
    _keys(device_id.clone()) = keys.clone()

  be publish_cross_signing(
    master: (String | None),
    self_signing: (String | None),
    user_signing: (String | None))
  =>
    """
    Publish whichever cross-signing keys an upload carried.

    An absent key leaves what is stored alone rather than clearing it: the
    endpoint takes the three keys in one request but a client need not send
    all three, and a client replacing one of them is not saying the others
    are gone.
    """
    match master
    | let k: String => _master = k.clone()
    end
    match self_signing
    | let k: String => _self_signing = k.clone()
    end
    match user_signing
    | let k: String => _user_signing = k.clone()
    end

  be sign_key(key_id: String, uploaded: String) =>
    """
    Add the signatures of one uploaded key object to what is stored.

    `key_id` is whatever the client keyed the upload by — a device id for a
    device's keys, or the public key itself for a cross-signing key. A key
    marilwyd does not hold is ignored: there is nothing to sign, and there
    is no version of it here that the signature could be attached to.
    """
    let fresh =
      match JsonParser.parse(uploaded)
      | let o: JsonObject => o
      else
        return
      end

    try
      _keys(key_id) = MergeSignatures(_keys(key_id)?, fresh)
      return
    end
    _master = _signed_if_named(_master, key_id, fresh)
    _self_signing = _signed_if_named(_self_signing, key_id, fresh)
    _user_signing = _signed_if_named(_user_signing, key_id, fresh)

  be published_keys(receiver: PublishedKeysReceiver tag, own: Bool) =>
    """
    Answer what this account has published.

    `own` says whether the account asking is this one. The user-signing key
    is what an account uses to sign *other* people, so the spec gives it to
    its owner alone; the rest are public by design — they are what everyone
    else encrypts to.
    """
    let devices = recover iso Array[DeviceKeys] end
    for (device_id, content) in _keys.pairs() do
      devices.push(DeviceKeys(device_id, content))
    end
    receiver.keys_published(
      id,
      PublishedKeys(
        consume devices,
        _master,
        _self_signing,
        if own then _user_signing else None end))

  be send_to_device(
    sender: String,
    kind: String,
    device_id: String,
    content: String)
  =>
    """
    Hand a message to one of this account's devices, or to all of them.

    A device this account does not have is dropped without a word. The
    endpoint reports no failures and a client is told nothing about which
    of the devices it named exist — which is deliberate on both counts:
    saying would let anyone enumerate an account's devices by sending to
    guesses.

    Built once and shared. `ToDeviceEvent` is `val`, so addressing every
    device of an account costs one object however many devices there are.
    """
    let event = ToDeviceEvent(sender.clone(), kind.clone(), content.clone())
    if device_id == AllDevices() then
      for device in _devices.values() do
        device.deliver_to_device(event)
      end
    else
      try
        _devices(device_id)?.deliver_to_device(event)
      end
    end

  be claim_keys(
    device_ids: Array[String] val,
    receiver: OneTimeKeyClaimReceiver tag)
  =>
    """
    Ask each named device of this account for a one-time key.

    Every device named is answered for, including ones this account does
    not have. A caller counts the replies to know when it has them all, so
    a device that simply never answered would hold a request open until its
    deadline.
    """
    for device_id in device_ids.values() do
      try
        _devices(device_id)?.claim_one_time_key(id, receiver)
      else
        receiver.one_time_key_missing(id, device_id)
      end
    end

  be create_backup(backup: KeyBackup, receiver: KeyBackupReceiver tag) =>
    """
    Record a new key backup version and answer what it is called.

    Versions are handed out in order and never reused, so a client holding
    an old version number is told it is gone rather than handed someone
    else's backup.
    """
    _backups.push(backup)
    receiver.backup_created(_backups.size().string())

  be latest_backup(receiver: KeyBackupReceiver tag) =>
    """
    Answer the most recent backup version, if there is one.
    """
    try
      receiver.backup_found(
        _backups(_backups.size() - 1)?,
        _backups.size().string())
    else
      receiver.backup_missing()
    end

  fun _signed_if_named(
    stored: (String | None),
    key_id: String,
    uploaded: JsonObject)
    : (String | None)
  =>
    """
    Merge signatures into a cross-signing key when the upload named it.

    A cross-signing key is keyed by its own public key rather than by a
    device id, so the only way to tell which of the three an upload means
    is to look for that key inside them.
    """
    match stored
    | let content: String =>
      if KeyNamed(content, key_id) then
        return MergeSignatures(content, uploaded)
      end
      content
    else
      None
    end

  be joined(room_id: String, room: Room tag) =>
    _rooms(room_id) = room
    for device in _devices.values() do
      room.describe(device)
    end

  be departed(room_id: String) =>
    """
    This account has left a room. Every device is told, because each holds
    that room's state for its next fresh sync and would otherwise go on
    being told about a room its owner is no longer in.
    """
    try
      (_, _) = _rooms.remove(room_id)?
    end
    for device in _devices.values() do
      device.forget_room(room_id)
    end

  be ephemeral(room_id: String, current: Ephemeral) =>
    """
    Hand one room's ephemeral state to every device of this account.

    One value, however many devices: `Ephemeral` is `val`, so this shares
    rather than copies — the same reason `deliver` does.
    """
    for device in _devices.values() do
      device.ephemeral(room_id, current)
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
