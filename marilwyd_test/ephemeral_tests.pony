use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestNothingEphemeralRendersEmpty is UnitTest
  fun name(): String => "ephemeral/a room with nothing renders no events"

  fun apply(h: TestHelper) =>
    h.assert_eq[String](
      "[]",
      EphemeralEvents(
        Ephemeral(
          recover val Array[Receipt] end, recover val Array[String] end)))

class \nodoc\ iso _TestReceiptsGroupByEvent is UnitTest
  """
  One `m.receipt` event whose content maps an event id to the people who
  have read that far — the shape a client reads. An event each would be a
  document the client has to merge itself.
  """
  fun name(): String => "ephemeral/receipts group under the event they name"

  fun apply(h: TestHelper) =>
    let rendered =
      EphemeralEvents(
        Ephemeral(
          recover val
            [ Receipt("@alice:x", "$one", 1000)
              Receipt("@bob:x", "$one", 2000) ]
          end,
          recover val Array[String] end))
    h.assert_eq[USize](1, _Occurrences(rendered, "m.receipt"))
    h.assert_eq[USize](1, _Occurrences(rendered, "$one"))
    h.assert_true(rendered.contains("@alice:x"), rendered)
    h.assert_true(rendered.contains("@bob:x"), rendered)
    h.assert_true(rendered.contains("\"ts\":1000"), rendered)

class \nodoc\ iso _TestTypingRendersWhoIsTyping is UnitTest
  fun name(): String => "ephemeral/typing names who is typing"

  fun apply(h: TestHelper) =>
    let rendered =
      EphemeralEvents(
        Ephemeral(
          recover val Array[Receipt] end,
          recover val ["@alice:x"; "@bob:x"] end))
    h.assert_true(
      rendered.contains("\"type\":\"m.typing\""), rendered)
    h.assert_true(rendered.contains("@alice:x"), rendered)
    h.assert_true(rendered.contains("@bob:x"), rendered)

class \nodoc\ iso _TestAReadPositionIsLastWriteWins is UnitTest
  """
  A read position is where somebody is now, not a history of where they
  have been. Two receipts from one person are one entry.
  """
  fun name(): String => "ephemeral/a second receipt replaces the first"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      _ReadTwice(h, _AnyRoomId()?, _AnyDeviceId()?, _AnyEpoch()?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _ReadTwice is (SyncReceiver & MembershipReceiver)
  """
  Reads twice, then looks at what one device is told.
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
    _user.attach("laptop", _device)
    _room = Room(id)
    // The account is passed twice on purpose: as the member the room fans
    // events to, and as the account that hears its ephemeral state. A
    // bridged user's IRC connection is only ever the first.
    _room.join("@alice:example.test", _user, this, _user)

  be membership_changed(room: RoomId) =>
    _room
      .> read_up_to("@alice:example.test", "$first")
      .> read_up_to("@alice:example.test", "$second")
    // Asked after both, from the same sender, so both have landed.
    _room.members(
      "@alice:example.test", _IgnoreState(this, _device, _user))

  be membership_refused(why: NoSuchRoom) =>
    _h.fail("joining was refused")
    _h.complete(false)

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_eq[USize](1, _Occurrences(rendered, "m.read"), rendered)
    _h.assert_true(rendered.contains("$second"), rendered)
    _h.assert_false(
      rendered.contains("$first"),
      "an earlier read position was kept: " + rendered)
    _h.complete(true)

actor \nodoc\ _IgnoreState is (StateReceiver & RoomListReceiver)
  """
  Two round trips, and both are needed.

  Ephemeral state travels from the room to the `User` and from the `User`
  to the `Device`, so a sync asked after only the room has answered races
  the second hop — which is what the first version of this did, and it
  failed on an empty block rather than on the thing it was testing. Asking
  the room puts the first hop behind us and asking the user puts the
  second.
  """
  let _then: SyncReceiver tag
  let _device: Device
  let _user: User

  new create(then': SyncReceiver tag, device: Device, user: User) =>
    _then = then'
    _device = device
    _user = user

  be state_listed(events: Array[RoomEvent] val) =>
    _user.rooms(this)

  be state_refused(why: NotInRoom) => None

  be rooms_listed(rooms: Array[String] val) =>
    _device.sync(None, 0, _then)

class \nodoc\ iso _TestOnlyMembersAreHeard is UnitTest
  """
  A room id is the whole of the access control, so a stranger holding one
  could otherwise report a read position or appear to be typing in a room
  they never joined.
  """
  fun name(): String => "ephemeral/a stranger cannot type in a room"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let room = Room(_AnyRoomId()?)
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let alice = User("@alice:example.test")
      alice.attach("laptop", device)
      room
        .> created_by(
          "@alice:example.test",
          alice,
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)
        .> typing("@mallory:example.test", true)
        .> read_up_to("@mallory:example.test", "$nope")
        .> members(
          "@alice:example.test",
          _IgnoreState(_ExpectQuiet(h), device, alice))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectQuiet is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_false(
      rendered.contains("mallory"),
      "a stranger reached a room's ephemeral state: " + rendered)
    _h.complete(true)

class \nodoc\ iso _TestTypingIsBounded is UnitTest
  """
  The list is rendered into every member's sync and a bridged channel's
  membership comes from outside, so it is bounded like everything else a
  stranger can move.
  """
  fun name(): String => "ephemeral/the typing list is bounded"

  fun apply(h: TestHelper) =>
    let many = recover iso Array[String] end
    var i: USize = 0
    while i < (MaxTypists() + 10) do
      many.push("@who" + i.string() + ":x")
      i = i + 1
    end
    // The bound is the room's, not the renderer's — this asserts the
    // renderer does not add one of its own on top.
    let rendered =
      EphemeralEvents(
        Ephemeral(recover val Array[Receipt] end, consume many))
    h.assert_true(rendered.contains("m.typing"), rendered)

class \nodoc\ iso _TestAReceiptWithoutATokenIsRefused is UnitTest
  fun name(): String => "ephemeral/a receipt without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post(
        "/_matrix/client/v3/rooms/%21a%3Aexample.test/receipt/m.read/%24e",
        "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestTypingWithoutATokenIsRefused is UnitTest
  fun name(): String => "ephemeral/typing without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send(
        "PUT",
        "/_matrix/client/v3/rooms/%21a%3Aexample.test/typing/%40a%3Ax",
        "{\"typing\":true}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestTypingReachesTheRoomsSync is UnitTest
  """
  The whole path over real sockets: say you are typing, then read it back
  out of `/sync`, which is the only place ephemeral state is delivered.
  """
  fun name(): String => "ephemeral/typing comes back from sync"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        let room =
          match _RoomFrom(created)
          | let id: String => _Encoded(id)
          else
            "!missing"
          end
        _Send(
          "PUT",
          "/_matrix/client/v3/rooms/" + room + "/typing/%40"
            + _TestUser.localpart() + "%3Aexample.test",
          "{\"typing\":true,\"timeout\":30000}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
      } val)

class \nodoc\ iso _TestReadMarkersAreAccepted is UnitTest
  """
  Element's other spelling for the same thing. It carries `m.fully_read`
  as well, which marilwyd drops — a private per-room marker is room-scoped
  account data, and there is none.
  """
  fun name(): String => "ephemeral/read markers are accepted"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        let room =
          match _RoomFrom(created)
          | let id: String => _Encoded(id)
          else
            "!missing"
          end
        _Post(
          "/_matrix/client/v3/rooms/" + room + "/read_markers",
          "{\"m.fully_read\":\"$a\",\"m.read\":\"$a\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_false(r.contains("errcode"), r)
      } val)

class \nodoc\ iso _TestAReceiptForAnUnknownRoom is UnitTest
  fun name(): String => "ephemeral/a receipt for an unknown room is 404"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/rooms/%21nope%3Aexample.test/receipt/m.read/%24e",
          "{}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_NOT_FOUND")
      } val)

class \nodoc\ iso _TestEphemeralWakesAParkedSync is UnitTest
  """
  Somebody typing reaches a client holding a sync at once, rather than when
  its deadline runs out.

  A typing notice that arrives twenty-five seconds later is worse than
  none: it says somebody is typing who has long since stopped. Nothing else
  observes the wake — every other test here syncs fresh — so without this
  the mechanism rests on a coincidence.
  """
  fun name(): String => "ephemeral/typing answers a parked sync at once"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      // Parked with a position, and then told — so only the ephemeral
      // state can answer it.
      device
        .> sync(USize(0), 25_000, _ExpectTypingWoken(h))
        .> ephemeral(
          "!room:example.test",
          Ephemeral(
            recover val Array[Receipt] end,
            recover val ["@alice:example.test"] end))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectTypingWoken is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_eq[USize](
      1, view.ephemeral.size(), "woken without it: " + rendered)
    _h.assert_true(rendered.contains("m.typing"), rendered)
    _h.assert_eq[USize](
      0, view.events.size(), "woken by an event nobody sent: " + rendered)
    _h.complete(true)

class \nodoc\ iso _TestEphemeralIsNotResent is UnitTest
  """
  A client past the change is not told again, or every sync in a busy room
  would carry the whole ephemeral state forever — which for a bridged
  channel is the room's entire membership on every poll.
  """
  fun name(): String => "ephemeral/a client past the change is not told again"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> ephemeral(
          "!room:example.test",
          Ephemeral(
            recover val Array[Receipt] end,
            recover val ["@alice:example.test"] end))
        // The change lands at position 1, so a client asking for what
        // comes after 1 has already had it.
        .> sync(USize(1), 0, _ExpectNoEphemeral(h))
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestEmptyEphemeralIsNotSent is UnitTest
  """
  A room with nothing to report says nothing, rather than sending an empty
  block a client already believes. What must still arrive is the change
  *to* empty — the last person stopping typing — and that is a change from
  a non-empty state the client was told about.
  """
  fun name(): String => "ephemeral/an empty state is not sent on its own"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device
        .> ephemeral(
          "!room:example.test",
          Ephemeral(
            recover val Array[Receipt] end, recover val Array[String] end))
        .> sync(USize(0), 0, _ExpectNoEphemeral(h))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectNoEphemeral is SyncReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be synced(view: SyncView) =>
    let rendered = SyncDocument(view)
    _h.assert_eq[USize](
      0, view.ephemeral.size(), "ephemeral state was sent: " + rendered)
    _h.assert_false(rendered.contains("m.typing"), rendered)
    _h.complete(true)

class \nodoc\ iso _TestTheTypingListIsCapped is UnitTest
  """
  The room's own bound, not the renderer's. A bridged channel's membership
  is driven from outside, so the list of who is typing is something a
  stranger can grow.
  """
  fun name(): String => "ephemeral/a room caps who it reports as typing"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      _ManyTypists(h, _AnyRoomId()?, _AnyDeviceId()?, _AnyEpoch()?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _ManyTypists is
  (SyncReceiver & StateReceiver & RoomListReceiver)
  """
  Admits more people than the cap allows and has them all type.
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
    _user.attach("laptop", _device)
    _room = Room(id)
    _room.created_by(
      "@alice:example.test",
      _user,
      CreateRoomRequest(None, None, false),
      _IgnoreCreation,
      _user)

    var i: USize = 0
    while i < (MaxTypists() + 10) do
      let who: String = "@who" + i.string() + ":example.test"
      _room .> admit_ghost(who, who) .> typing(who, true)
      i = i + 1
    end
    _room.members("@alice:example.test", this)

  be state_listed(events: Array[RoomEvent] val) =>
    _user.rooms(this)

  be state_refused(why: NotInRoom) =>
    _h.fail("the creator was not a member")
    _h.complete(false)

  be rooms_listed(rooms: Array[String] val) =>
    _device.sync(None, 0, this)

  be synced(view: SyncView) =>
    for (room_id, current) in view.ephemeral.values() do
      _h.assert_eq[USize](
        MaxTypists(),
        current.typing.size(),
        "the typing list was not capped")
      _h.complete(true)
      return
    end
    _h.fail("no ephemeral state reached the device")
    _h.complete(false)
