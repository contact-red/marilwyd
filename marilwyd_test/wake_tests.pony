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
      device.sync(USize(0), 25_000, _ExpectWoken(h, "\"body\":\"hello\""))
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

      let room = Room(_AnyRoomId()?, "example.test")
      room.created_by("@alice:example.test", alice, None)

      device.sync(USize(0), 25_000, _ExpectWoken(h, "hello from a room"))
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
      let alice_room = Room(_AnyRoomId()?, "example.test")
      alice_room.created_by("@alice:example.test", alice, None)

      let bob_device = Device(_AnyDeviceId()?, epoch)
      let bob = User("@bob:example.test")
      bob.attach("laptop", bob_device)
      let bob_room = Room(_AnyRoomId()?, "example.test")
      bob_room.created_by("@bob:example.test", bob, None)

      bob_device.sync(USize(0), 25_000, _ExpectWoken(h, "for bob only"))

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
  Asserts a sync was answered, and that what arrived contains `expected`
  and nothing from another room.
  """
  let _h: TestHelper
  let _expected: String

  new create(h: TestHelper, expected: String) =>
    _h = h
    _expected = expected

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_true(
      rendered.contains(_expected),
      "woken without the event: " + rendered)
    _h.assert_false(
      rendered.contains("for alice only"),
      "woken with another room's event: " + rendered)
    _h.complete(true)

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
  be event_refused(why: (NotInRoom | NoEventId)) => None

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
        Room(_AnyRoomId()?, "example.test")
          .> created_by("@alice:example.test", alice, None)

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
        Room(_AnyRoomId()?, "example.test")
          .> created_by("@alice:example.test", alice, None)

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

  be event_refused(why: (NotInRoom | NoEventId)) =>
    match \exhaustive\ why
    | NotInRoom => _h.complete(true)
    | NoEventId =>
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

  be event_refused(why: (NotInRoom | NoEventId)) =>
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
      device.room_state(recover val [named] end)
      device.sync(USize(0), 25_000, _ExpectNoState(h))
      device.deliver(_Message(room, "@alice:example.test", 1)?)
    else
      _NoRandom(h)
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
