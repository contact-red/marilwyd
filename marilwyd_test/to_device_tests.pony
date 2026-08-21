use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestAToDeviceEventRenders is UnitTest
  fun name(): String => "todevice/an event renders sender, type and content"

  fun apply(h: TestHelper) =>
    let rendered =
      ToDeviceEvent("@alice:x", "m.room.encrypted", "{\"c\":1}").render()
    h.assert_eq[String](
      "{\"sender\":\"@alice:x\",\"type\":\"m.room.encrypted\"" +
        ",\"content\":{\"c\":1}}",
      rendered)

class \nodoc\ iso _TestNoKeysClaimedRendersEmpty is UnitTest
  """
  A claim that found nothing is an answer, not an error. The client learns
  that the device it named has no key left and opens no session.
  """
  fun name(): String => "todevice/claiming nothing renders an empty answer"

  fun apply(h: TestHelper) =>
    h.assert_eq[String](
      "{\"one_time_keys\":{},\"failures\":{}}",
      KeysClaimed(recover val Array[ClaimedKey] end))

class \nodoc\ iso _TestClaimedKeysGroupByAccount is UnitTest
  """
  Two devices of one account share one entry. Rendering them as two would
  be a repeated key in a JSON object, which a client may read either way.
  """
  fun name(): String => "todevice/claimed keys group under their account"

  fun apply(h: TestHelper) =>
    let claimed =
      recover val
        [ ClaimedKey("@alice:x", "AAA", "signed_curve25519:1", "{\"k\":1}")
          ClaimedKey("@alice:x", "BBB", "signed_curve25519:2", "{\"k\":2}") ]
      end
    let rendered = KeysClaimed(claimed)
    h.assert_eq[USize](1, _Occurrences(rendered, "@alice:x"))
    h.assert_true(
      rendered.contains("\"AAA\":{\"signed_curve25519:1\""), rendered)
    h.assert_true(
      rendered.contains("\"BBB\":{\"signed_curve25519:2\""), rendered)

primitive \nodoc\ _Occurrences
  fun apply(haystack: String, needle: String): USize =>
    var found: USize = 0
    var from: ISize = 0
    while true do
      try
        let at = haystack.find(needle, from)?
        found = found + 1
        from = at + 1
      else
        return found
      end
    end
    found

class \nodoc\ iso _TestAOneTimeKeyIsSpent is UnitTest
  """
  The property the whole endpoint rests on: a key is handed out once.

  Two claims must produce two different keys and the third must produce
  none. Offering one key twice would let two devices each open a session
  believing it is the only one.
  """
  fun name(): String => "todevice/a one-time key is handed out once"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> take_one_time_keys(
          recover val [("a", "{\"k\":\"a\"}"); ("b", "{\"k\":\"b\"}")] end,
          _IgnoreKeyCount)
        .> claim_one_time_key("@alice:x", _ClaimTwice(h, device))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ClaimTwice is OneTimeKeyClaimReceiver
  """
  Claims three times over, asserting the pool empties exactly once per key.
  """
  let _h: TestHelper
  let _device: Device
  embed _seen: Array[String] = _seen.create()

  new create(h: TestHelper, device: Device) =>
    _h = h
    _device = device

  be one_time_key_claimed(
    user_id: String,
    device_id: String,
    key_id: String,
    content: String)
  =>
    for already in _seen.values() do
      if already == key_id then
        _h.fail("the same one-time key was handed out twice: " + key_id)
        _h.complete(false)
        return
      end
    end
    _seen.push(key_id.clone())
    _device.claim_one_time_key(user_id, this)

  be one_time_key_missing(user_id: String, device_id: String) =>
    _h.assert_eq[USize](
      2, _seen.size(), "the pool ran out after the wrong number of claims")
    _h.complete(true)

class \nodoc\ iso _TestAnUnknownDeviceIsReportedMissing is UnitTest
  """
  A caller counts replies to know when a claim is answered, so a device an
  account does not have has to answer rather than stay silent.
  """
  fun name(): String => "todevice/claiming from an unknown device answers"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    User("@alice:example.test")
      .> claim_keys(recover val ["NOSUCHDEVICE"] end, _ExpectMissing(h))

actor \nodoc\ _ExpectMissing is OneTimeKeyClaimReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be one_time_key_claimed(
    user_id: String,
    device_id: String,
    key_id: String,
    content: String)
  =>
    _h.fail("a device that does not exist handed over a key")
    _h.complete(false)

  be one_time_key_missing(user_id: String, device_id: String) =>
    _h.assert_eq[String]("NOSUCHDEVICE", device_id)
    _h.complete(true)

class \nodoc\ iso _TestAToDeviceMessageReachesASync is UnitTest
  fun name(): String => "todevice/a message reaches the device's sync"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> deliver_to_device(
          ToDeviceEvent("@alice:x", "m.room.encrypted", "{\"c\":\"opaque\"}"))
        .> sync(USize(0), 0, _ExpectToDevice(h, device))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectToDevice is SyncReceiver
  """
  Asserts a message is delivered, and then that it is not delivered twice.

  The second sync carries the position the first answered with, which is
  how a client says it received what it was sent. Without that
  acknowledgement the block would never empty, and matrix-js-sdk would stay
  in its catching-up loop forever.
  """
  let _h: TestHelper
  let _device: Device
  var _first: Bool = true

  new create(h: TestHelper, device: Device) =>
    _h = h
    _device = device

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    if _first then
      _first = false
      _h.assert_eq[USize](1, view.to_device.size(), rendered)
      _h.assert_true(
        rendered.contains("\"to_device\":{\"events\":["), rendered)
      _h.assert_true(rendered.contains("m.room.encrypted"), rendered)
      // A room event would have arrived here too if to-device messages
      // were being queued as ordinary events.
      _h.assert_false(rendered.contains("rooms"), rendered)
      _device.sync(USize(1), 0, this)
    else
      _h.assert_eq[USize](
        0,
        view.to_device.size(),
        "a to-device message was delivered twice: " + rendered)
      _h.assert_false(rendered.contains("to_device"), rendered)
      _h.complete(true)
    end

class \nodoc\ iso _TestAnUnacknowledgedMessageIsSentAgain is UnitTest
  """
  A response lost in transit must not take its messages with it. Until a
  client comes back with a position past a message, it is still owed.
  """
  fun name(): String => "todevice/an unacknowledged message is sent again"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> deliver_to_device(ToDeviceEvent("@alice:x", "m.foo", "{}"))
        .> sync(USize(0), 0, _ExpectToDeviceTwice(h, device))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectToDeviceTwice is SyncReceiver
  let _h: TestHelper
  let _device: Device
  var _first: Bool = true

  new create(h: TestHelper, device: Device) =>
    _h = h
    _device = device

  be synced(view: SyncView) =>
    _h.assert_eq[USize](1, view.to_device.size(), SyncDocument(view))
    if _first then
      _first = false
      // The same position again: this client never confirmed anything.
      _device.sync(USize(0), 0, this)
    else
      _h.complete(true)
    end

class \nodoc\ iso _TestToDeviceReachesEveryDevice is UnitTest
  """
  `*` means every device of the account, which is how a client starts a
  verification without knowing which of its own devices are listening.
  """
  fun name(): String => "todevice/a wildcard reaches every device"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      _AfterFanOut(
        h,
        Device(_AnyDeviceId()?, _AnyEpoch()?),
        Device(_AnyDeviceId()?, _AnyEpoch()?),
        AllDevices(),
        true)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestToDeviceGoesOnlyToItsDevice is UnitTest
  """
  Naming one device does not reach the others. A verification message meant
  for one client is not something the rest of the account should see.
  """
  fun name(): String => "todevice/naming one device does not reach another"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      _AfterFanOut(
        h,
        Device(_AnyDeviceId()?, _AnyEpoch()?),
        Device(_AnyDeviceId()?, _AnyEpoch()?),
        "LAPTOP",
        false)
    else
      _NoRandom(h)
    end

actor \nodoc\ _AfterFanOut is (RoomListReceiver & SyncReceiver)
  """
  Sends to one device or to all of them, then reads both devices' syncs.

  The round trip through `rooms` is load-bearing. A message travels from
  this actor to the `User` and from the `User` to a `Device`, and Pony
  orders messages per sender rather than globally — so syncing a device
  straight after sending would race the delivery, and the test would fail
  or pass for reasons that have nothing to do with the routing. Asking the
  `User` something and waiting for its answer puts the fan-out behind us.
  """
  let _h: TestHelper
  let _user: User
  let _laptop: Device
  let _phone: Device
  let _reach_phone: Bool
  var _answers: USize = 0

  new create(
    h: TestHelper,
    laptop: Device,
    phone: Device,
    addressed: String,
    reach_phone: Bool)
  =>
    _h = h
    _laptop = laptop
    _phone = phone
    _reach_phone = reach_phone
    _user = User("@alice:example.test")
    _user.attach("LAPTOP", laptop)
    _user.attach("PHONE", phone)
    _user.send_to_device("@alice:example.test", "m.foo", addressed, "{}")
    _user.rooms(this)

  be rooms_listed(rooms: Array[String] val) =>
    _laptop.sync(USize(0), 0, this)

  be synced(view: SyncView) =>
    """
    The laptop first, then the phone, so each answer is attributable. Both
    devices answering one receiver at once would say how many syncs carried
    a message but not which device received it — and which device is the
    whole question.
    """
    _answers = _answers + 1
    if _answers == 1 then
      _h.assert_eq[USize](
        1,
        view.to_device.size(),
        "the addressed device was missed: " + SyncDocument(view))
      _phone.sync(USize(0), 0, this)
    else
      let owed = if _reach_phone then USize(1) else USize(0) end
      _h.assert_eq[USize](
        owed,
        view.to_device.size(),
        "the second device was reached wrongly: " + SyncDocument(view))
      _h.complete(true)
    end

class \nodoc\ iso _TestTheToDeviceQueueIsBounded is UnitTest
  """
  A device that never comes back cannot grow without bound, and one that
  has lost messages is told so — a half-finished handshake is worth
  knowing about even though nothing here can complete it.
  """
  fun name(): String => "todevice/the queue is bounded and marks its gap"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      var sent: USize = 0
      while sent <= ToDeviceLimit() do
        device.deliver_to_device(ToDeviceEvent("@alice:x", "m.foo", "{}"))
        sent = sent + 1
      end
      device.sync(USize(0), 0, _ExpectBoundedToDevice(h))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectBoundedToDevice is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    _h.assert_eq[USize](ToDeviceLimit(), view.to_device.size())
    _h.assert_true(view.gap, "dropping a message left no gap recorded")
    _h.complete(true)

class \nodoc\ iso _TestAToDeviceMessageWakesAParkedSync is UnitTest
  """
  A verification is a conversation, and each turn of it is a to-device
  message. If one only arrived when a held sync expired, every turn would
  cost the client its poll interval — a handshake of half a dozen messages
  would take minutes rather than milliseconds.
  """
  fun name(): String => "todevice/a message answers a parked sync at once"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      // A position, so this parks rather than answering as a first sync.
      device
        .> sync(USize(0), 25_000, _ExpectWokenByToDevice(h))
        .> deliver_to_device(
          ToDeviceEvent("@alice:x", "m.key.verification.start", "{}"))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectWokenByToDevice is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    _h.assert_eq[USize](1, view.to_device.size(), SyncDocument(view))
    _h.assert_true(
      SyncDocument(view).contains("m.key.verification.start"),
      SyncDocument(view))
    _h.complete(true)

class \nodoc\ iso _TestAClientKeepingUpNeverGapsToDevice is UnitTest
  """
  What acknowledgement is for, and the only way to observe it.

  A device answers a sync from the position it was given, so a message that
  was delivered is already filtered out of the next answer whether or not
  it was dropped from the queue. The difference shows only over time: a
  queue that is never drained grows until it passes its bound and starts
  discarding, and the client is told it has a gap it did not earn.

  Driven past `ToDeviceLimit()` for that reason. A shorter run passes
  either way.
  """
  fun name(): String => "todevice/a client that keeps up never sees a gap"

  fun apply(h: TestHelper) =>
    h.long_test(30_000_000_000)
    try
      _KeepUp(h, Device(_AnyDeviceId()?, _AnyEpoch()?))
    else
      _NoRandom(h)
    end

actor \nodoc\ _KeepUp is SyncReceiver
  """
  Sends one message, syncs, and repeats — the shape of a client that is
  never behind.
  """
  let _h: TestHelper
  let _device: Device
  var _seen: USize = 0

  new create(h: TestHelper, device: Device) =>
    _h = h
    _device = device
    _send()

  fun ref _send() =>
    // Each delivery advances the device's position by exactly one, so the
    // count of messages seen is also the position of the last one.
    _device.deliver_to_device(ToDeviceEvent("@alice:x", "m.foo", "{}"))
    _device.sync(_seen, 0, this)

  be synced(view: SyncView) =>
    _h.assert_eq[USize](
      1,
      view.to_device.size(),
      "a client that is up to date was owed more than the last message")
    _h.assert_false(
      view.gap,
      "a client that acknowledged everything was told it had a gap")
    _seen = _seen + 1
    if _seen > (ToDeviceLimit() + 5) then
      _h.complete(true)
    else
      _send()
    end

class \nodoc\ iso _TestAFloodEvictsOnlyItsOwnSender is UnitTest
  """
  The reason a device keeps one to-device queue per sending account.

  Any signed-in account may send to any device it can name, so with a
  single queue a stranger could push past the bound and evict a handshake
  the device was in the middle of with someone else. Separated, the only
  messages a flood costs are the flooder's own.

  Driven well past `ToDeviceLimit()` from one account, with a single
  message from another sent first. With one shared queue that first message
  is the first thing discarded.
  """
  fun name(): String => "todevice/a flood evicts only the flooder's messages"

  fun apply(h: TestHelper) =>
    h.long_test(30_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device.deliver_to_device(
        ToDeviceEvent(
          "@bob:example.test",
          "m.key.verification.start",
          "{\"from\":\"bob\"}"))
      var sent: USize = 0
      while sent < (ToDeviceLimit() * 2) do
        device.deliver_to_device(
          ToDeviceEvent("@mallory:example.test", "m.flood", "{}"))
        sent = sent + 1
      end
      device.sync(USize(0), 0, _ExpectBobSurvived(h))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectBobSurvived is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    var from_bob: USize = 0
    var from_mallory: USize = 0
    for message in view.to_device.values() do
      if message.sender == "@bob:example.test" then
        from_bob = from_bob + 1
      else
        from_mallory = from_mallory + 1
      end
    end
    _h.assert_eq[USize](
      1, from_bob, "a flood from one account evicted another's message")
    _h.assert_eq[USize](
      ToDeviceLimit(),
      from_mallory,
      "the flooding account kept more than its own share")
    _h.complete(true)

class \nodoc\ iso _TestToDeviceKeepsTheOrderItArrived is UnitTest
  """
  Messages from two senders come back interleaved in arrival order.

  Order within one sender is what a crypto machine needs — a handshake is a
  sequence — and merging the queues on the device position preserves the
  order across senders as well.
  """
  fun name(): String => "todevice/messages keep the order they arrived in"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> deliver_to_device(ToDeviceEvent("@a:x", "m.one", "{}"))
        .> deliver_to_device(ToDeviceEvent("@b:x", "m.two", "{}"))
        .> deliver_to_device(ToDeviceEvent("@a:x", "m.three", "{}"))
        .> deliver_to_device(ToDeviceEvent("@b:x", "m.four", "{}"))
        .> sync(USize(0), 0, _ExpectArrivalOrder(h))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectArrivalOrder is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    let order = String
    for message in view.to_device.values() do
      order.append(message.kind)
      order.append(" ")
    end
    _h.assert_eq[String]("m.one m.two m.three m.four ", order.clone())
    _h.complete(true)
