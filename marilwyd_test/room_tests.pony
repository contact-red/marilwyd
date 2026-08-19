use "pony_test"
use "../marilwyd"

primitive _AnyRoom
  """
  A room with a real minted id.

  Partial rather than substituting a fabricated one: `RoomId._create` is
  private so that only the CSPRNG can produce an id, and a test that cannot
  get one has nothing to say. Every test here wraps its body in a single
  `try` for that reason.
  """
  fun apply(): RoomState ? =>
    match MakeRoomId("example.test")
    | let id: RoomId => RoomState(id)
    else
      error
    end

primitive _Message
  """
  One ordinary event, at a given stream position.
  """
  fun apply(room: RoomState, sender: String, position: USize)
    : RoomEvent ?
  =>
    RoomEvent(
      _AnyEventId()?,
      room.id,
      "m.room.message",
      sender,
      1_760_000_000_000,
      "{\"body\":\"hello\"}",
      None,
      position)

primitive _State
  """
  One state event, at a given stream position.
  """
  fun apply(
    room: RoomState,
    kind: String,
    key: String,
    content: String,
    position: USize)
    : RoomEvent ?
  =>
    RoomEvent(
      _AnyEventId()?,
      room.id,
      kind,
      "@alice:example.test",
      1_760_000_000_000,
      content,
      key,
      position)

primitive _AnyEventId
  fun apply(): EventId ? =>
    match MakeEventId()
    | let e: EventId => e
    else
      error
    end

primitive _NoRandom
  fun apply(h: TestHelper) =>
    h.fail("the CSPRNG is unavailable, so no id could be minted")

class \nodoc\ iso _TestRoomStateIsLastWins is UnitTest
  fun name(): String => "rooms/a state slot keeps the latest event"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      room.apply_state(
        _State(room, "m.room.name", "", "{\"name\":\"first\"}", 0)?)
      room.apply_state(
        _State(room, "m.room.name", "", "{\"name\":\"second\"}", 1)?)
      h.assert_eq[USize](1, room.state_events().size())
      h.assert_true(
        room.state_events()(0)?.content.contains("second"),
        "the older name won")
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestRoomMembershipComesAndGoes is UnitTest
  """
  Leaving matters because the wake fans out over members: without it the
  set only grows, and a bridged channel's departed ghosts would be woken
  for every message forever.
  """
  fun name(): String => "rooms/leaving removes a member"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      room.join("@alice:example.test")
      room.join("@bob:example.test")
      h.assert_eq[USize](2, room.members().size())
      room.leave("@bob:example.test")
      h.assert_eq[USize](1, room.members().size())
      h.assert_true(room.is_member("@alice:example.test"))
      h.assert_false(room.is_member("@bob:example.test"))
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestPendingKeepsOnlyItsLimit is UnitTest
  """
  The bound that matters: a device nobody is reading accumulates, and this
  is what stops it accumulating forever.
  """
  fun name(): String => "pending/a queue keeps only its limit"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      var queue = Pending[RoomEvent]
      var i: USize = 0
      while i < 10 do
        queue = queue.push(i + 1, _Message(room, "@alice:example.test", i)?, 3)
        i = i + 1
      end
      h.assert_eq[USize](3, queue.size())
      h.assert_eq[USize](7, queue.dropped())
      // The three kept are the newest.
      h.assert_eq[USize](7, queue.events()(0)?.position)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestPendingRemembersItDropped is UnitTest
  """
  A gap is a fact about the device that outlives the events that revealed
  it. Nothing in marilwyd can fill one, so a device that has one should be
  able to find out rather than silently believe it saw everything.
  """
  fun name(): String => "pending/a delivered queue remembers its gap"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      var queue = Pending[RoomEvent]
      var i: USize = 0
      while i < 5 do
        queue = queue.push(i + 1, _Message(room, "@alice:example.test", i)?, 2)
        i = i + 1
      end
      h.assert_eq[USize](3, queue.dropped())

      // Acknowledging the last position is how a client confirms it
      // received everything, and is what drains the queue.
      let drained = queue.acknowledged(USize(5))
      h.assert_eq[USize](0, drained.size())
      h.assert_eq[USize](3, drained.dropped(), "the gap was forgotten")
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestPendingSharesItsEvents is UnitTest
  """
  Two devices owed the same event hold the same event.

  Not an optimisation to verify but a property to pin: `RoomEvent` is `val`
  and ORCA traces one copy, which is what makes a queue per device
  affordable rather than a multiplier on memory.
  """
  fun name(): String => "pending/two devices share one event"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      let event = _Message(room, "@alice:example.test", 0)?
      let laptop = Pending[RoomEvent].push(1, event)
      let phone = Pending[RoomEvent].push(1, event)

      h.assert_eq[USize](1, laptop.size())
      h.assert_eq[USize](1, phone.size())
      h.assert_true(
        laptop.events()(0)? is phone.events()(0)?,
        "the two queues hold different objects")
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestPendingVersionsAreIndependent is UnitTest
  """
  Pushing returns a new queue and leaves the old one alone, which is what
  lets a device answer a sync from the version it had while a room appends
  to the version it will have.
  """
  fun name(): String => "pending/pushing leaves the earlier version intact"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      let first = Pending[RoomEvent].push(1, _Message(room, "@alice:example.test", 0)?)
      let second = first.push(2, _Message(room, "@alice:example.test", 1)?)
      h.assert_eq[USize](1, first.size(), "the earlier version grew")
      h.assert_eq[USize](2, second.size())
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestPendingHandlesAnImpossiblePosition is UnitTest
  """
  A position ahead of anything this device has held is as unusable as one
  behind what it still holds, and answered the same way.

  Each entry carries the position it was queued at, so a `since` is
  compared against those rather than turned into an index — which is what
  lets a device's position advance for things that are not events, such as
  a change to its account's data.
  """
  fun name(): String => "pending/a slice is taken by position, not index"

  fun apply(h: TestHelper) =>
    try
      let room = _AnyRoom()?
      var queue = Pending[RoomEvent]
      var i: USize = 0
      while i < 3 do
        queue = queue.push(i + 1, _Message(room, "@alice:example.test", i)?)
        i = i + 1
      end
      // Far ahead of anything this device has seen: every entry's own
      // position is at or below it, so nothing is newer.
      h.assert_eq[USize](0, queue.since(USize(99)).size())
      // From the start, everything.
      h.assert_eq[USize](3, queue.since(USize(0)).size())
      // From the middle, the rest.
      h.assert_eq[USize](1, queue.since(USize(2)).size())
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestGhostsComeAndGo is UnitTest
  """
  A far-side participant leaves the room when they leave the channel.

  The half that used to be missing. Ghosts were admitted when they first
  spoke and never removed, so a room's member list was everyone who had
  ever said anything rather than everyone who is there — and a person
  reading a bridged channel could not tell who was still listening.
  """
  fun name(): String => "rooms/a ghost leaves when the channel says so"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)
    match MakeRoomId("example.test")
    | let id: RoomId => _GhostMembership(h, id)
    else
      _NoRandom(h)
    end

actor \nodoc\ _GhostMembership is (StateReceiver & RoomCreationReceiver)
  """
  Admits two ghosts, parts one, and reads back who the room says is there.

  An actor because a room is one: the answer has to come back through a
  behaviour, and asserting straight after the call would assert on a state
  the room has not reached.
  """
  let _h: TestHelper
  let _room: Room
  let _user: User

  new create(h: TestHelper, id: RoomId) =>
    _h = h
    _user = User("@alice:example.test")
    _room = Room(id)
    _room.created_by(
      "@alice:example.test",
      _user,
      CreateRoomRequest(None, None, false),
      this,
      _user)

  be room_created(id: RoomId) =>
    _room
      .> admit_ghost("@irc_net_bob:example.test", "bob")
      .> admit_ghost("@irc_net_carol:example.test", "carol")
      .> part_ghost("@irc_net_bob:example.test")
      // Nobody. Parting a stranger must not write a membership event for
      // one, which is what would happen on every `QUIT` the channel sees
      // for somebody who never joined it.
      .> part_ghost("@irc_net_dave:example.test")
      .> members("@alice:example.test", this)

  be room_refused() =>
    _h.fail("the room was not created")
    _h.complete(false)

  be alias_taken() =>
    _h.fail("an unnamed room claimed an alias")
    _h.complete(false)

  be state_refused(why: NotInRoom) =>
    _h.fail("the creator could not read the room")
    _h.complete(false)

  be state_listed(events: Array[RoomEvent] val) =>
    var alice = false
    var bob = false
    var carol = false
    var dave = false
    for event in events.values() do
      if event.kind != "m.room.member" then
        continue
      end
      let joined = event.content.contains("\"membership\":\"join\"")
      match event.state_key
      | "@alice:example.test" => alice = joined
      | "@irc_net_bob:example.test" => bob = joined
      | "@irc_net_carol:example.test" => carol = joined
      | "@irc_net_dave:example.test" => dave = true
      end
    end

    _h.assert_true(alice, "the creator was not a member")
    _h.assert_false(bob, "a parted ghost was still a member")
    _h.assert_true(carol, "a ghost that stayed was not a member")
    _h.assert_false(dave, "parting a stranger wrote a membership event")
    _h.complete(true)
