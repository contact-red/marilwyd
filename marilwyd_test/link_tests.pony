use "pony_test"
use irc = "irc"
use "../marilwyd"

class \nodoc\ iso _TestChannelMembershipIsMirrored is UnitTest
  """
  The room's member list is the channel's, from the moment it is entered.

  Every one of these arrived as a bug report from a live channel. Ghosts
  used to be admitted only when they spoke, so a person joining a busy
  channel saw an empty room and watched it fill as people happened to
  talk — and nobody ever left it.
  """
  fun name(): String => "links/the channel's members become the room's"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkUnderTest(h, _LinkFixture.create()?, _MirrorsMembership)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestActionsAndNoticesAreCarried is UnitTest
  """
  `/me` and `/notice` reach the room, as the Matrix types that mean the
  same thing.

  Both used to be dropped: an action because every CTCP was discarded
  unread, a notice because only `PRIVMSG` was read at all. A third of what
  is said on a channel is one or the other, and it was invisible.
  """
  fun name(): String => "links/an action and a notice reach the room"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkUnderTest(h, _LinkFixture.create()?, _CarriesActions)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestCtcpPingIsAnswered is UnitTest
  """
  A CTCP `PING` is answered, with the asker's own argument echoed back.

  It has to be a `NOTICE`: answering a CTCP request with a `PRIVMSG`
  invites the other end to answer back, and two clients doing that flood
  each other off the server.
  """
  fun name(): String => "links/a CTCP ping is answered"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkUnderTest(h, _LinkFixture.create()?, _AnswersPing)
    else
      _NoRandom(h)
    end

primitive _MirrorsMembership
primitive _CarriesActions
primitive _AnswersPing

type _LinkCase is (_MirrorsMembership | _CarriesActions | _AnswersPing)

actor \nodoc\ _LinkUnderTest is (StateReceiver & RoomCreationReceiver
  & SyncReceiver & irc.IRCSend)
  """
  One `UserLink` fed raw IRC lines, with a real room behind it.

  Raw lines through `irc.Parse` rather than hand-built events, because the
  parsing is where a mistake would hide — a wrong parameter index reads
  perfectly and matches nothing. This is the shipped path from the wire to
  the room, with a stub where the socket would be.
  """
  let _h: TestHelper
  let _which: _LinkCase
  let _room: Room
  let _user: User
  let _device: Device
  let _link: UserLink
  let _settled: irc.Registration val
  let _epoch: StreamEpoch
  embed _sent: Array[String] = _sent.create()
  embed _heard: Array[RoomEvent] = _heard.create()
  var _arrived: Bool = false

  new create(h: TestHelper, given: _LinkFixture, which: _LinkCase) =>
    _h = h
    _which = which
    _user = User("@alice:example.test")
    _device = Device(given.device, given.epoch)
    _user.attach(given.device.string(), _device)
    _room = Room(given.room)
    _settled = given.settled
    _epoch = given.epoch

    _link =
      UserLink(
        "@alice:example.test",
        BridgedNetwork("net", "irc.example.test", "6697", true, [], []),
        "#pony",
        NameMapping("{localpart}[marilwyd]", "irc_{network}_{nick}"),
        given.homeserver,
        None)

    _room.created_by(
      "@alice:example.test",
      _user,
      CreateRoomRequest(None, None, false),
      this,
      _user)

  be room_created(id: RoomId) =>
    _link.carries(_room)
    // Its own JOIN first: nothing else is read until the channel is
    // entered, which is what stops a room filling from a channel the
    // connection never got into.
    _feed(":alice[marilwyd]!u@h JOIN #pony")

    match \exhaustive\ _which
    | _MirrorsMembership =>
      _feed(":irc.example.test 353 alice[marilwyd] = #pony "
        + ":@bob +carol dave erin frank alice[marilwyd]")
      _feed(":irc.example.test 366 alice[marilwyd] #pony :End of /NAMES")
      _feed(":dave!u@h PART #pony :bye")
      _feed(":carol!u@h QUIT :ping timeout")
      // The person removed is the parameter, not the sender.
      _feed(":bob!u@h KICK #pony erin :behave")
      _feed(":frank!u@h NICK :frankie")
    | _CarriesActions =>
      _feed(":bob!u@h PRIVMSG #pony :\x01ACTION waves\x01")
      _feed(":bob!u@h NOTICE #pony :the build is red")
      // A CTCP arriving as a NOTICE is somebody's answer, and answering an
      // answer is how two clients flood each other off a server.
      _feed(":bob!u@h NOTICE #pony :\x01PING 12345\x01")
    | _AnswersPing =>
      _feed(":bob!u@h PRIVMSG alice[marilwyd] :\x01PING 12345\x01")
    end

    // Nothing is asserted until this comes back through the room.
    //
    // The link and the test are two actors talking to a third, and nothing
    // orders one against the other: asking the room what it holds straight
    // after feeding a line asks it before it has been told. Waiting for a
    // line fed *after* everything else to arrive by the long way round —
    // link to room to user to device — is what makes the answer mean
    // something.
    _feed(":zeus!u@h PRIVMSG #pony :" + _Sentinel())
    // From a position rather than from nothing: a first sync answers at
    // once with whatever has arrived, which at this instant is nothing.
    // Only a sync that names where it got to will wait.
    _device.sync(USize(0), MaxSyncWait(), this)

  fun ref _feed(raw: String) =>
    match irc.Parse(raw)
    | let m: irc.Message val => _link.irc_message(this, m, _settled)
    else
      _h.fail("could not parse: " + raw)
      _h.complete(false)
    end

  be state_listed(events: Array[RoomEvent] val) =>
    _check_membership(events)

  fun _check_membership(events: Array[RoomEvent] val) =>
    var alice = false
    var bob = false
    var carol = false
    var dave = false
    var erin = false
    var frank = false
    var frankie = false
    for event in events.values() do
      if event.kind != "m.room.member" then
        continue
      end
      let joined = event.content.contains("\"membership\":\"join\"")
      match event.state_key
      | "@alice:example.test" => alice = joined
      | "@irc_net_bob:example.test" => bob = joined
      | "@irc_net_carol:example.test" => carol = joined
      | "@irc_net_dave:example.test" => dave = joined
      | "@irc_net_erin:example.test" => erin = joined
      | "@irc_net_frank:example.test" => frank = joined
      | "@irc_net_frankie:example.test" => frankie = joined
      end
    end

    _h.assert_true(alice, "the Matrix user was not in their own room")
    _h.assert_true(bob, "an operator in the name list was not admitted")
    _h.assert_false(carol, "somebody who quit was still a member")
    _h.assert_false(dave, "somebody who parted was still a member")
    _h.assert_false(erin, "somebody who was kicked was still a member")
    // A rename is a leave and a join, because a ghost's Matrix id is built
    // from the nickname: the new name is a different user, and there is
    // nothing to carry across.
    _h.assert_false(frank, "a renamed member kept their old name")
    _h.assert_true(frankie, "a renamed member did not get their new one")
    _h.complete(true)

  fun _check_ping() =>
    var answered = false
    for line in _sent.values() do
      if line.contains("NOTICE")
        and line.contains("bob")
        and line.contains("PING 12345")
      then
        answered = true
      end
      _h.assert_false(
        line.contains("PRIVMSG"),
        "a CTCP request was answered with a PRIVMSG: " + line)
    end
    _h.assert_true(answered, "a CTCP ping went unanswered")
    _h.complete(true)

  be synced(view: SyncView) =>
    // Accumulated across syncs. A device answers with what it has, which
    // need not be everything the room will send — the sentinel is what
    // says the rest has already been through.
    for event in view.events.values() do
      _heard.push(event)
      if event.content.contains(_Sentinel()) then
        _arrived = true
      end
    end

    if not _arrived then
      match ReadStreamPosition(view.next_batch, _epoch)
      | let at: USize => _device.sync(at, MaxSyncWait(), this)
      else
        _h.fail("a device answered with a position it cannot be asked for")
        _h.complete(false)
      end
      return
    end

    match \exhaustive\ _which
    | _MirrorsMembership => _room.members("@alice:example.test", this)
    | _AnswersPing => _check_ping()
    | _CarriesActions => _check_messages()
    end

  fun _check_messages() =>
    var emoted = false
    var noticed = false
    for event in _heard.values() do
      if event.sender != "@irc_net_bob:example.test" then
        continue
      end
      if event.content.contains("\"msgtype\":\"m.emote\"")
        and event.content.contains("waves")
      then
        emoted = true
      end
      if event.content.contains("\"msgtype\":\"m.notice\"")
        and event.content.contains("build is red")
      then
        noticed = true
      end
      _h.assert_false(
        event.content.contains("12345"),
        "a CTCP reply was relayed into the room")
    end

    _h.assert_true(emoted, "an action did not reach the room")
    _h.assert_true(noticed, "a notice did not reach the room")
    _h.complete(true)

  be state_refused(why: NotInRoom) =>
    _h.fail("the room would not answer its own member")
    _h.complete(false)

  be room_refused() =>
    _h.fail("the room was not created")
    _h.complete(false)

  be alias_taken() =>
    _h.fail("an unnamed room claimed an alias")
    _h.complete(false)

  // What the connection was asked to send. A stub rather than a socket,
  // which is what the `irc` package documents `IRCSend` for.
  be send(line: irc.Line val) =>
    // The wire bytes, not `string()`, which renders a summary for a log
    // rather than what goes out.
    _sent.push(String.from_array(line.bytes()))

  be privmsg(target: irc.Target, text: String val) =>
    _sent.push("PRIVMSG " + text)

  be notice(target: irc.Target, text: String val) =>
    _sent.push("NOTICE " + text)

  be action(target: irc.Target, text: String val) => None

  be join(
    channels: Array[irc.Channel] val,
    keys: Array[String val] val = [])
  =>
    None

  be part(channels: Array[irc.Channel] val, reason: String val = "") => None

  be nick(n: irc.Nick) => None

  be quit(reason: String val = "") => None

  be disconnect() => None

class \nodoc\ val _LinkFixture
  """
  Everything a link test needs that can fail to be made.

  Built here rather than in `_LinkUnderTest` because an actor constructor
  cannot be partial, and every one of these is minted by something that
  can refuse — the CSPRNG, or a validator.

  `PREFIX` is announced because a real server announces it, and the name
  lists the tests feed wear the marks it names.
  """
  let room: RoomId
  let device: DeviceId
  let epoch: StreamEpoch
  let homeserver: Homeserver
  let settled: irc.Registration val

  new val create() ? =>
    room = _AnyRoomId()?
    device = _AnyDeviceId()?
    epoch = _AnyEpoch()?
    homeserver =
      match MakeHomeserver.http("example.test")
      | let hs: Homeserver => hs
      else
        error
      end
    settled =
      irc.Registration(
        match irc.Nicks("alice[marilwyd]")
        | let n: irc.Nick => n
        else
          error
        end,
        irc.CasemapAscii,
        [("PREFIX", "(ov)@+")])

primitive \nodoc\ _Sentinel
  """
  What the tests feed last, and wait to see come back.
  """
  fun apply(): String => "that is all"
