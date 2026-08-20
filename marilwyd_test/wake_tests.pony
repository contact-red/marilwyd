use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestAnEventWakesAParkedDevice is UnitTest
  """
  The whole increment in one test: a device holding a sync is answered the
  moment an event arrives, not when its deadline runs out.

  Driven at the actor rather than over HTTP, because parking needs a
  position and a position needs a sync to have already happened — and
  because one sender to one actor is causally ordered, so the park is
  guaranteed to precede the delivery with no sleep and no flake.
  """
  fun name(): String => "wake/an event answers a parked sync at once"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let room = _AnyRoom()?
      // A position, so this parks rather than answering as a first sync.
      // `_Message` carries this body; asserting on it rather than on the
      // event's presence is what makes the test fail if the wrong event
      // were delivered.
      device.sync(
        USize(0), 25_000, _ExpectWoken(h, "\"body\":\"hello\"", device))
      device.deliver(_Message(room, "@alice:example.test", 0)?)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestAParkedDeviceWaitsForItsEvent is UnitTest
  """
  The counterpart: without an event, a parked device is not answered.

  Expressed as a positive — the deadline arrives and *then* it answers —
  because `pony_test` records a result the moment any receiver completes
  one, so "must never happen" is a race rather than an assertion.
  """
  fun name(): String => "wake/a parked sync is not answered early"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let receiver = _ExpectEmpty(h)
      device.sync(USize(0), 25_000, receiver)
      // Nothing is delivered. The only thing that can answer is the
      // expiry, and the view it produces must carry no events.
      device.expired(receiver)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestRoomReachesItsMembersDevices is UnitTest
  """
  A message sent to a room reaches a member's device, through the `User`
  actor that stands between them.
  """
  fun name(): String => "wake/a room's event reaches a member's device"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let alice = User("@alice:example.test")
      alice.attach("laptop", device)

      let room = Room(_AnyRoomId()?)
      room.created_by(
          "@alice:example.test",
          alice,
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)

      device.sync(
        USize(0), 25_000, _ExpectWoken(h, "hello from a room", device))
      room.send(
        "@alice:example.test",
        "m.room.message",
        "{\"body\":\"hello from a room\"}",
        _IgnoreEvent)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestRoomReachesNobodyOutsideIt is UnitTest
  """
  The negative that makes the positive mean anything, written so both
  parties report rather than one asserting an absence.

  Bob is in his own room; alice sends to hers. Bob's device is woken by
  *his* room's event, and what arrives must be his and not hers — which
  fails just as loudly if the fan-out reached everyone.
  """
  fun name(): String => "wake/an event reaches only its own room"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let epoch = _AnyEpoch()?

      let alice = User("@alice:example.test")
      let alice_room = Room(_AnyRoomId()?)
      alice_room.created_by(
          "@alice:example.test",
          alice,
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)

      let bob_device = Device(_AnyDeviceId()?, epoch)
      let bob = User("@bob:example.test")
      bob.attach("laptop", bob_device)
      let bob_room = Room(_AnyRoomId()?)
      bob_room.created_by(
          "@bob:example.test",
          bob,
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)

      bob_device.sync(
        USize(0), 25_000, _ExpectWoken(h, "for bob only", bob_device))

      // Alice's room must not reach bob; bob's must.
      alice_room.send(
        "@alice:example.test",
        "m.room.message",
        "{\"body\":\"for alice only\"}",
        _IgnoreEvent)
      bob_room.send(
        "@bob:example.test",
        "m.room.message",
        "{\"body\":\"for bob only\"}",
        _IgnoreEvent)
    else
      _NoRandom(h)
    end

actor _ExpectWoken is SyncReceiver
  """
  Asserts that what a device is owed eventually contains `expected`, and
  never anything from another room.

  Syncs again rather than asserting on the first answer, because a device
  is owed more than one thing: joining a room now delivers the joiner's own
  membership, so a sync parked before a message can legitimately be woken
  by the join first. Asserting on the first answer made these tests
  sensitive to how many events a join produces, which is not what they are
  about.
  """
  let _h: TestHelper
  let _expected: String
  let _device: Device
  var _seen: USize = 0

  new create(h: TestHelper, expected: String, device: Device) =>
    _h = h
    _expected = expected
    _device = device

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_false(
      rendered.contains("for alice only"),
      "woken with another room's event: " + rendered)

    if rendered.contains(_expected) then
      _h.complete(true)
      return
    end

    _seen = _seen + 1
    if _seen > 4 then
      _h.fail("never woken with the event: " + rendered)
      _h.complete(false)
    else
      _device.sync(_seen, 25_000, this)
    end

actor _ExpectEmpty is SyncReceiver
  """
  Asserts a sync was answered with a position and no events.
  """
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    _h.assert_eq[USize](0, view.events.size(), "answered with events")
    let rendered = SyncDocument(view)
    _h.assert_true(rendered.contains("next_batch"), rendered)
    _h.assert_false(rendered.contains("rooms"), rendered)
    _h.complete(true)

actor _IgnoreEvent is EventReceiver
  """
  For tests driving a room where the send's own answer is not the subject.
  """
  be event_sent(id: EventId) => None
  be event_refused(why: (NotInRoom | NoEventId | BridgeDown)) => None

primitive _AnyDeviceId
  fun apply(): DeviceId ? =>
    match MakeDeviceId()
    | let d: DeviceId => d
    else
      error
    end

primitive _AnyRoomId
  fun apply(): RoomId ? =>
    match MakeRoomId("example.test")
    | let r: RoomId => r
    else
      error
    end

class \nodoc\ iso _TestSendingToARoomYouAreNotInIsRefused is UnitTest
  """
  Membership is the only thing gating who may post to a room, and a room id
  is shared freely by design — anyone holding one can join, but until they
  do they are not a member and may not send.

  Found by mutation: deleting the check left the whole suite green, so
  every room was writable by anyone who knew its id.
  """
  fun name(): String => "wake/sending to a room you are not in is refused"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let alice = User("@alice:example.test")
      let room =
        Room(_AnyRoomId()?)
          .> created_by(
          "@alice:example.test",
          alice,
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)

      room.send(
        "@bob:example.test",
        "m.room.message",
        "{\"body\":\"I should not be here\"}",
        _ExpectRefused(h))
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestAMemberMaySend is UnitTest
  """
  The other half, so the refusal above cannot pass by refusing everyone.
  """
  fun name(): String => "wake/a member may send to their room"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let alice = User("@alice:example.test")
      let room =
        Room(_AnyRoomId()?)
          .> created_by(
          "@alice:example.test",
          alice,
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)

      room.send(
        "@alice:example.test",
        "m.room.message",
        "{\"body\":\"mine\"}",
        _ExpectAccepted(h))
    else
      _NoRandom(h)
    end

actor _ExpectRefused is EventReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be event_sent(id: EventId) =>
    _h.fail("a stranger's event was accepted into the room")
    _h.complete(false)

  be event_refused(why: (NotInRoom | NoEventId | BridgeDown)) =>
    match \exhaustive\ why
    | NotInRoom => _h.complete(true)
    | NoEventId =>
      _h.fail("refused for the wrong reason")
      _h.complete(false)
    | BridgeDown =>
      _h.fail("refused for the wrong reason")
      _h.complete(false)
    end

actor _ExpectAccepted is EventReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be event_sent(id: EventId) =>
    _h.assert_true(id.string().size() > 0)
    _h.complete(true)

  be event_refused(why: (NotInRoom | NoEventId | BridgeDown)) =>
    _h.fail("a member's own event was refused")
    _h.complete(false)

class \nodoc\ iso _TestAWokenSyncCarriesNoState is UnitTest
  """
  A woken sync continues the one that parked, so it must not re-send the
  room state its client already has.

  Found end-to-end: waking answered as though the request were fresh, so
  every message a client received arrived with the full state of its room
  attached.
  """
  fun name(): String => "wake/a woken sync does not resend state"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let room = _AnyRoom()?
      // Given state, so there is something to wrongly re-send.
      // Built outside the `recover`: `RoomState` is `ref` and so reads as
      // `tag` inside one, while a `RoomEvent` is `val` and passes freely.
      let named = _State(room, "m.room.name", "", "{\"name\":\"pony\"}", 0)?
      let id: String = room.id.string()
      _StateOnlyOnce(
        h,
        device,
        id,
        recover val [named] end,
        _Message(room, "@alice:example.test", 1)?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _StateOnlyOnce is SyncReceiver
  """
  A room's state reaches a client once and is not sent again.

  The rule this checks changed: state used to travel only on a sync with
  no position at all, which is why a client that joined a room mid-session
  was never told what it had joined. It now travels to a client whose
  position predates the description — so the property worth pinning is that
  it stops, not that it never starts.
  """
  let _h: TestHelper
  let _device: Device
  let _message: RoomEvent
  var _first: Bool = true

  new create(
    h: TestHelper,
    device: Device,
    room_id: String,
    state: Array[RoomEvent] val,
    message: RoomEvent)
  =>
    _h = h
    _device = device
    _message = message
    // Describing advances the device to position 1, so a client at 0 has
    // not been told and a client at 1 has.
    device .> room_state(room_id, state) .> sync(USize(0), 0, this)

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    if _first then
      _first = false
      _h.assert_eq[USize](
        1, view.state.size(), "a room was described to nobody: " + rendered)
      // Now past it, and an ordinary message must not drag it back.
      _device .> deliver(_message) .> sync(USize(1), 0, this)
    else
      _h.assert_eq[USize](
        0,
        view.state.size(),
        "a woken sync re-sent state the client had: " + rendered)
      _h.assert_true(
        rendered.contains("\"body\""),
        "the message that woke it was missing: " + rendered)
      _h.complete(true)
    end

actor _ExpectNoState is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    _h.assert_eq[USize](1, view.events.size(), "woken without the event")
    _h.assert_eq[USize](
      0, view.state.size(), "a woken sync re-sent the room state")
    _h.complete(true)

class \nodoc\ iso _TestAccountDataReachesADevice is UnitTest
  """
  Account data has to arrive through `/sync`, not just through its own
  endpoint: Element reads it from a local store that only sync populates,
  so a client could otherwise save settings it would never see again.
  """
  fun name(): String => "account/a change reaches a device's sync"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let alice = User("@alice:example.test")
      alice.attach("laptop", device)

      device.sync(USize(0), 25_000, _ExpectAccountData(h))
      alice.set_account_data(
        "m.push_rules_display", "{\"quiet\":true}")
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestAccountDataIsNotResent is UnitTest
  """
  A client that has already been told does not need telling again, or every
  sync would carry the whole account's data forever.

  Driven at the device rather than through the user, and that is the point
  of the test rather than a detail of it. Setting the data on the `User`
  makes the `User` send it to the `Device`, while the sync comes from here
  — two senders into one mailbox with nothing ordering them. The version
  that did so passed only when the sync won the race, and asserted the
  opposite of its own name when it lost.
  """
  fun name(): String => "account/a client past the change is not told again"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> account_data(
          recover val [AccountDatum("m.quiet", "{\"on\":true}")] end)
        // The change advances the device to position 1, so a client asking
        // for what comes after 1 has already had it.
        .> sync(USize(1), 0, _ExpectNoAccountData(h))
    else
      _NoRandom(h)
    end

actor _ExpectAccountData is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    _h.assert_eq[USize](
      1, view.account.size(), "woken without the account data")
    let rendered = SyncDocument(view)
    _h.assert_true(rendered.contains("account_data"), rendered)
    _h.assert_true(rendered.contains("m.push_rules_display"), rendered)
    _h.assert_true(rendered.contains("quiet"), rendered)
    _h.complete(true)

actor _ExpectNoAccountData is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    _h.assert_eq[USize](
      0, view.account.size(), "account data was sent again")
    _h.assert_false(SyncDocument(view).contains("account_data"))
    _h.complete(true)

class \nodoc\ iso _TestADeviceInTwoRoomsSeesBoth is UnitTest
  """
  A device holds one room's state per room, not one room's state.

  Held as a single array, whichever room described itself last replaced
  the rest, so a client signing in saw exactly one of its rooms — the
  others appeared only when someone spoke in them, untitled. Nothing
  caught it: no test put one device in two rooms, and a driven Element
  session only ever signs in.
  """
  fun name(): String => "sync/a device in two rooms is told about both"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let kitchen = _AnyRoom()?
      let garden = _AnyRoom()?
      let kitchen_id: String = kitchen.id.string()
      let garden_id: String = garden.id.string()
      // Built outside the `recover` blocks, for the reason the test above
      // records: `RoomState` is `ref` and reads as `tag` inside one.
      let in_kitchen =
        _State(kitchen, "m.room.name", "", "{\"name\":\"kitchen\"}", 0)?
      let in_garden =
        _State(garden, "m.room.name", "", "{\"name\":\"garden\"}", 0)?
      device
        .> room_state(kitchen_id, recover val [in_kitchen] end)
        .> room_state(garden_id, recover val [in_garden] end)
        // No position: a fresh sync is the only one that carries state.
        .> sync(None, 0, _ExpectBothRooms(h))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectBothRooms is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_eq[USize](2, view.state.size(), rendered)
    _h.assert_true(rendered.contains("kitchen"), rendered)
    _h.assert_true(rendered.contains("garden"), rendered)
    _h.complete(true)

class \nodoc\ iso _TestLeavingARoomStopsDescribingIt is UnitTest
  """
  The other half of keeping state per room: a room left behind would be
  described on every fresh sync for the life of the process. Holding one
  array hid this by discarding everything whenever another room spoke.

  Driven through `User.departed` rather than by calling `forget_room` on
  the device. Calling it directly tests that the method works and says
  nothing about whether anything calls it — which is what the first
  version of this test did, and mutation caught it.
  """
  fun name(): String => "sync/a device stops being told about a room it left"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let kitchen = _AnyRoom()?
      let garden = _AnyRoom()?
      _LeaveThenSync(
        h,
        Device(_AnyDeviceId()?, _AnyEpoch()?),
        kitchen.id.string(),
        garden.id.string(),
        _State(kitchen, "m.room.name", "", "{\"name\":\"kitchen\"}", 0)?,
        _State(garden, "m.room.name", "", "{\"name\":\"garden\"}", 0)?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _LeaveThenSync is (RoomListReceiver & SyncReceiver)
  """
  Describes two rooms to a device, leaves one through the `User`, and then
  reads the device's fresh sync.

  The round trip through `rooms` is load-bearing. `forget_room` travels
  from the `User` to the `Device` while this actor's sync travels from
  here, and Pony orders messages per sender rather than globally — so
  syncing straight after `departed` would race the very message the test
  exists to observe.
  """
  let _h: TestHelper
  let _device: Device
  let _user: User

  new create(
    h: TestHelper,
    device: Device,
    kitchen_id: String,
    garden_id: String,
    in_kitchen: RoomEvent,
    in_garden: RoomEvent)
  =>
    _h = h
    _device = device
    device
      .> room_state(kitchen_id, recover val [in_kitchen] end)
      .> room_state(garden_id, recover val [in_garden] end)

    _user = User("@alice:example.test")
    _user
      .> attach("DEVICE", device)
      .> departed(garden_id)
      .> rooms(this)

  be rooms_listed(rooms: Array[String] val) =>
    _device.sync(None, 0, this)

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_eq[USize](1, view.state.size(), rendered)
    _h.assert_true(rendered.contains("kitchen"), rendered)
    _h.assert_false(
      rendered.contains("garden"),
      "a room the account left was still described: " + rendered)
    _h.complete(true)

actor \nodoc\ _IgnoreCreation is RoomCreationReceiver
  """
  For tests driving a room where the creation's own answer is not the
  subject.
  """
  be room_created(room: RoomId) => None
  be alias_taken() => None
  be room_refused() => None

class \nodoc\ iso _TestJoiningWhileSyncingIsTold is UnitTest
  """
  What Element hit: a client that already holds a sync position joins a
  room from the public directory, and is never told the room exists.

  Two faults met here. `_admit` fanned the membership event out before
  adding the joiner, so everyone learned of the join except the person
  joining; and a room's state travelled only on a fresh sync, so a client
  with a position got nothing either way. The sync waited its full
  twenty-five seconds and answered with nothing, twice, which is what
  hanging looks like from the client's side.
  """
  fun name(): String => "sync/joining while syncing tells the joiner"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      _JoinWhileSyncing(h, _AnyRoomId()?, _AnyDeviceId()?, _AnyEpoch()?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _JoinWhileSyncing is (MembershipReceiver & SyncReceiver)
  """
  Parks a sync at a position, then joins the room, then reads what the
  parked sync was answered with.
  """
  let _h: TestHelper
  let _device: Device
  let _user: User
  let _room: Room

  new create(
    h: TestHelper,
    id: RoomId,
    device_id: DeviceId,
    epoch: StreamEpoch)
  =>
    _h = h
    _device = Device(device_id, epoch)
    _user = User("@alice:example.test")
    _room = Room(id)
    _user.attach("laptop", _device)
    // A position, so this is the incremental case rather than a first
    // sync — the case that was broken.
    _device.sync(USize(0), 25_000, this)
    _room.join("@alice:example.test", _user, this)

  be membership_changed(room: RoomId) => None

  be membership_refused(why: NoSuchRoom) =>
    _h.fail("joining was refused")
    _h.complete(false)

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    // The room has to appear at all, which it did not before: an empty
    // answer here is the hang.
    _h.assert_true(
      rendered.contains("\"rooms\":{\"join\":{"),
      "a client that joined was told about no room: " + rendered)

    // And the joiner's own membership has to arrive as an event, not only
    // in the room's state. Asserting on the rendered document alone could
    // not tell the two apart, and the state half is delivered whether or
    // not the joiner was added to the room before its membership event was
    // fanned out — so a test that looked at the document passed with the
    // fan-out order still wrong.
    var told = false
    for event in view.events.values() do
      if event.kind == "m.room.member" then
        told = true
      end
    end
    _h.assert_true(
      told,
      "the joiner was not sent its own membership: " + rendered)
    _h.complete(true)

class \nodoc\ iso _TestDescribingARoomWakesAParkedSync is UnitTest
  """
  A device holding a sync is told about a room as soon as the room is
  described to it, without waiting for somebody to speak.

  Today a join delivers a membership event alongside the description, so
  the sync would be woken either way — which is exactly why this is worth
  its own test. Nothing else observes the wake, so without this the
  mechanism would be held up by a coincidence, and the first path that
  describes a room without an event beside it would leave a client waiting
  out its full deadline.
  """
  fun name(): String => "sync/describing a room wakes a parked sync"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let room = _AnyRoom()?
      let named = _State(room, "m.room.name", "", "{\"name\":\"pony\"}", 0)?
      let id: String = room.id.string()
      // Parked first, with a position, and then described — and nothing
      // is delivered, so only the description can answer it.
      device
        .> sync(USize(0), 25_000, _ExpectDescribed(h))
        .> room_state(id, recover val [named] end)
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectDescribed is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_eq[USize](
      1, view.state.size(), "woken without the room: " + rendered)
    _h.assert_eq[USize](
      0, view.events.size(), "woken with an event nobody sent: " + rendered)
    _h.assert_true(rendered.contains("pony"), rendered)
    _h.complete(true)
