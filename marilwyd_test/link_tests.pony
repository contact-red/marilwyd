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
      _feed(":irc.example.test 353 alice[marilwyd] = #pony " +
        ":@bob +carol dave erin frank alice[marilwyd]")
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
      if line.contains("NOTICE") and
        line.contains("bob") and
        line.contains("PING 12345")
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
      if event.content.contains("\"msgtype\":\"m.emote\"") and
        event.content.contains("waves")
      then
        emoted = true
      end
      if event.content.contains("\"msgtype\":\"m.notice\"") and
        event.content.contains("build is red")
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

class \nodoc\ iso _TestATransientDropRefusesSends is UnitTest
  """
  While the network is unreachable, the room stops accepting.

  A bridged room's whole content is its connection, so an event taken
  while that connection is down would be recorded, answered with an id,
  shown to its author, and never reach the channel they wrote it to. A
  client told the message failed can send it again; one told it succeeded
  cannot.
  """
  fun name(): String => "links/a dropped connection refuses sends"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkLifecycle(h, _LinkFixture.create()?, _DropsThenSends)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestAReconnectAcceptsAgain is UnitTest
  """
  And starts accepting again when the connection comes back.

  The bouncer half: a drop is not a departure, so the member keeps the
  room across a netsplit and only their sending pauses.
  """
  fun name(): String => "links/a reconnected connection accepts again"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkLifecycle(h, _LinkFixture.create()?, _DropsThenReturns)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestATerminalDeathPartsAndIsForgotten is UnitTest
  """
  A connection that will not be retried takes its member out of the room
  and has itself dropped.

  The regression this exists for: the directory kept the entry, so the
  next join was answered with the dead connection and *succeeded*. The
  user was a member of a bridged room carrying nothing in either
  direction, and every message they sent was answered `200` and
  discarded.
  """
  fun name(): String => "links/a terminal death parts and is forgotten"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkLifecycle(h, _LinkFixture.create()?, _DiesForGood)
    else
      _NoRandom(h)
    end

primitive _DropsThenSends
primitive _DropsThenReturns
primitive _DiesForGood
primitive _SendsTooMuch

type _LifecycleCase is
  (_DropsThenSends | _DropsThenReturns | _DiesForGood | _SendsTooMuch)

actor \nodoc\ _LinkLifecycle is (RoomCreationReceiver & EventReceiver
  & StateReceiver & LinkOwner & irc.IRCSend & OutStream)
  """
  Drives a `UserLink` through connection failures with no socket.

  The `irc` package documents `IRCSend` as the seam for exactly this, and
  the notify half is just behaviours — so registration, a drop, a return
  and a terminal death are all reachable without a network. None of this
  path had a test before, which is why a dead connection answering the
  next join as a live one shipped.
  """
  let _h: TestHelper
  let _which: _LifecycleCase
  let _room: Room
  let _user: User
  let _link: UserLink
  let _settled: irc.Registration val
  var _forgotten: Bool = false
  var _parted: Bool = false
  var _step: USize = 0

  new create(h: TestHelper, given: _LinkFixture, which: _LifecycleCase) =>
    _h = h
    _which = which
    _user = User("@alice:example.test")
    _room = Room(given.room)
    _settled = given.settled
    _link =
      UserLink(
        "@alice:example.test",
        BridgedNetwork("net", "irc.example.test", "6697", true, [], []),
        "#pony",
        NameMapping("{localpart}[marilwyd]", "irc_{network}_{nick}"),
        given.homeserver,
        this)
    _room.created_by(
      "@alice:example.test",
      _user,
      CreateRoomRequest(None, None, false),
      this,
      _user)

  be room_created(id: RoomId) =>
    _room.carry("@alice:example.test", _link)
    _link .> carries(_room) .> directed_by(this)
    // Registered and on the channel, which is the state every case below
    // starts from.
    _link.irc_registered(this, _settled)
    _feed(":alice[marilwyd]!u@h JOIN #pony")

    // The first step. Everything after it is driven from `print`, one
    // step per line the link writes — see that behaviour for why.
    match \exhaustive\ _which
    | _DiesForGood => _link.died("the network refused to have us")
    | _SendsTooMuch =>
      // Far more lines than the bridge carries, in a body well inside
      // `MaxEventBody`: the count refuses it, not the length.
      let many =
        recover val
          let text = String(512)
          var i: USize = 0
          while i < (MaxIrcLines() * 2) do
            text.append("line\\n")
            i = i + 1
          end
          text
        end
      _room.send(
        "@alice:example.test",
        "m.room.message",
        "{\"msgtype\":\"m.text\",\"body\":\"" + many + "\"}",
        this)
    else
      None
    end

  be print(data: ByteSeq) =>
    """
    One step of the test per line the link writes.

    Nothing may be asserted straight after telling the link something.
    The link and this actor are two senders talking to one room, and
    nothing orders them: asking the room before the link's message has
    arrived asks it about a state it has not reached. Each line the link
    writes, though, is written *after* it has told the room — so a
    message sent from here on receiving one reaches the room after it.

    A counter and not a guess at how many lines there will be. An earlier
    version of this test assumed the first line it saw was the drop's; the
    channel had already been entered by then, which also writes one, so
    every step was one behind and the two tests raced their own
    assertions. They passed anyway, often enough to be committed.
    """
    _step = _step + 1
    match \exhaustive\ _which
    | _DropsThenSends =>
      // 1: entered the channel. 2: dropped.
      if _step == 1 then
        _link.dropped("connection reset")
      elseif _step == 2 then
        _room.send(
          "@alice:example.test",
          "m.room.message",
          "{\"msgtype\":\"m.text\",\"body\":\"into the void\"}",
          this)
      end
    | _DropsThenReturns =>
      // 1: entered. 2: dropped. 3: entered again after the reconnect,
      // which is why the channel is joined from `irc_registered` rather
      // than once at connect.
      if _step == 1 then
        _link.dropped("connection reset")
      elseif _step == 2 then
        _link.irc_registered(this, _settled)
        _feed(":alice[marilwyd]!u@h JOIN #pony")
      elseif _step == 3 then
        _room.send(
          "@alice:example.test",
          "m.room.message",
          "{\"msgtype\":\"m.text\",\"body\":\"back again\"}",
          this)
      end
    | _DiesForGood => None
    | _SendsTooMuch => None
    end

  be write(data: ByteSeq) => None
  be printv(data: ByteSeqIter) => None
  be writev(data: ByteSeqIter) => None
  be flush() => None

  fun ref _feed(raw: String) =>
    match irc.Parse(raw)
    | let m: irc.Message val => _link.irc_message(this, m, _settled)
    else
      _h.fail("could not parse: " + raw)
      _h.complete(false)
    end

  be event_sent(id: EventId) =>
    match _which
    | _DropsThenSends =>
      _h.fail("a message was accepted while the connection was down")
      _h.complete(false)
    | _SendsTooMuch =>
      _h.fail("a message too long for the bridge was accepted")
      _h.complete(false)
    | _DropsThenReturns => _h.complete(true)
    end

  be event_refused(why: (NotInRoom | NoEventId | BridgeDown | TooManyLines)) =>
    match _which
    | _DropsThenSends =>
      _h.assert_true(
        why is BridgeDown,
        "refused, but not because the bridge was down")
      _h.complete(true)
    | _DropsThenReturns =>
      _h.fail("a message was refused after the connection came back")
      _h.complete(false)
    | _SendsTooMuch =>
      _h.assert_true(
        why is TooManyLines,
        "refused, but not for being too long for the bridge")
      _h.complete(true)
    end

  be forget(user_id: String, network: String, channel: String) =>
    """
    The link reporting its own death — sent after it parts its owner, so
    the room has already been told by the time this arrives.
    """
    _forgotten = true
    _h.assert_eq[String]("@alice:example.test", user_id)
    _h.assert_eq[String]("#pony", channel)
    _room.members("@alice:example.test", this)

  be state_listed(events: Array[RoomEvent] val) =>
    for event in events.values() do
      if (event.kind == "m.room.member") and
        (event.state_key is None)
      then
        continue
      end
      match event.state_key
      | "@alice:example.test" =>
        if event.content.contains("\"membership\":\"leave\"") then
          _parted = true
        end
      end
    end
    _h.assert_true(_parted, "a terminal death left the member in the room")
    _h.assert_true(_forgotten, "a terminal death was not reported upward")
    _h.complete(true)

  be state_refused(why: NotInRoom) =>
    // Parted, which is what this case is checking for.
    _h.assert_true(_forgotten, "a terminal death was not reported upward")
    _h.complete(true)

  be room_refused() =>
    _h.fail("the room was not created")
    _h.complete(false)

  be alias_taken() =>
    _h.fail("an unnamed room claimed an alias")
    _h.complete(false)

  be send(line: irc.Line val) => None
  be privmsg(target: irc.Target, text: String val) => None
  be notice(target: irc.Target, text: String val) => None
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

class \nodoc\ iso _TestOnlyTextAndNoticeLeave is UnitTest
  """
  `Said` is the whole of "messages plus notices, and nothing else".

  Every other msgtype a client may send — an image, a file, a location —
  carries a `body` that reads as ordinary text, so a relay that did not
  check would put "photo.jpg" on the channel as though somebody had typed
  it. Nothing downstream checks again.
  """
  fun name(): String => "links/only text and notices are carried out"

  fun apply(h: TestHelper) =>
    match Said("{\"msgtype\":\"m.text\",\"body\":\"hello\"}")
    | (let text: String, let notice: Bool) =>
      h.assert_eq[String]("hello", text)
      h.assert_false(notice, "a message was carried as a notice")
    else
      h.fail("a plain message was not carried")
    end

    match Said("{\"msgtype\":\"m.notice\",\"body\":\"beep\"}")
    | (let text: String, let notice: Bool) =>
      h.assert_eq[String]("beep", text)
      h.assert_true(notice, "a notice was carried as a message")
    else
      h.fail("a notice was not carried")
    end

    // A notice must stay a notice. On IRC the two are how a person tells
    // automated traffic from somebody talking, and relaying a notice as
    // an ordinary message makes a bot indistinguishable from a person.
    for unwanted in
      [ "{\"msgtype\":\"m.image\",\"body\":\"photo.jpg\"}"
        "{\"msgtype\":\"m.file\",\"body\":\"accounts.xlsx\"}"
        "{\"msgtype\":\"m.location\",\"body\":\"home\"}"
        "{\"msgtype\":\"m.emote\",\"body\":\"waves\"}"
        "{\"body\":\"no msgtype at all\"}"
        "{\"msgtype\":\"m.text\"}"
        "not json" ].values()
    do
      match Said(unwanted)
      | (let text: String, _) =>
        h.fail("carried something that is not a message: " + unwanted)
      end
    end

class \nodoc\ iso _TestCtcpCommandsCompareWithoutCase is UnitTest
  """
  A CTCP command is compared without regard to case.

  The protocol does not say which case a client sends and they do not
  agree, so comparing exactly answers `/me` for one client and silence for
  another.
  """
  fun name(): String => "links/a CTCP command compares without case"

  fun apply(h: TestHelper) =>
    for spelling in ["ACTION"; "action"; "AcTiOn"].values() do
      match irc.Parse(":bob!u@h PRIVMSG #pony :\x01" + spelling + " waves\x01")
      | let m: irc.Message val =>
        match m.ctcp()
        | let embedded: irc.Ctcp val =>
          h.assert_true(
            IsCtcp(embedded, "ACTION"),
            "did not recognise ACTION spelled " + spelling)
          h.assert_false(
            IsCtcp(embedded, "PING"),
            "recognised " + spelling + " as PING")
        else
          h.fail("no CTCP parsed from " + spelling)
        end
      else
        h.fail("could not parse a CTCP with " + spelling)
      end
    end

class \nodoc\ iso _TestANicknameComesFromTheLocalpart is UnitTest
  """
  `LocalpartOf` takes an id apart; `Localpart` says whether one is usable.
  Two neighbouring names for two different questions.
  """
  fun name(): String => "links/a nickname is made from the local part"

  fun apply(h: TestHelper) =>
    h.assert_eq[String]("alice", LocalpartOf("@alice:example.test"))
    h.assert_eq[String]("alice", LocalpartOf("@alice:example.test:8008"))
    // No colon: there is nothing else the id could mean.
    h.assert_eq[String]("@alice", LocalpartOf("@alice"))
    h.assert_eq[String]("", LocalpartOf(""))

class \nodoc\ iso _TestOnlyTheOwnersWordsGoOut is UnitTest
  """
  A connection relays its owner's words to the channel, and nobody else's
  — and only the kinds of thing IRC can carry.

  The whole outbound path had no test: `Room.carry` was called from
  nowhere in the suite and `UserLink.deliver` was never invoked, so
  `event.sender != _user_id` — the single structural guard against a
  bridged room amplifying itself — could be deleted with every test still
  passing.

  It is structural and not a configured check: this connection wears one
  person's nickname, so relaying anybody else's words would put them on
  IRC under the wrong name, and a ghost's words going back out is the
  loop. Everyone else in the room has their own connection saying their
  own words.
  """
  fun name(): String => "links/only the owner's own words go out"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _OutboundRelay(h, _LinkFixture.create()?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _OutboundRelay is (RoomCreationReceiver & EventReceiver
  & irc.IRCSend & OutStream)
  """
  Carries a link into a room, then sends from three senders through it.
  """
  let _h: TestHelper
  let _room: Room
  let _user: User
  let _link: UserLink
  let _settled: irc.Registration val
  embed _sent: Array[String] = _sent.create()

  new create(h: TestHelper, given: _LinkFixture) =>
    _h = h
    _user = User("@alice:example.test")
    _room = Room(given.room)
    _settled = given.settled
    _link =
      UserLink(
        "@alice:example.test",
        BridgedNetwork("net", "irc.example.test", "6697", true, [], []),
        "#pony",
        NameMapping("{localpart}[marilwyd]", "irc_{network}_{nick}"),
        given.homeserver,
        this)
    _room.created_by(
      "@alice:example.test",
      _user,
      CreateRoomRequest(None, None, false),
      this,
      _user)

  be room_created(id: RoomId) =>
    _room.carry("@alice:example.test", _link)
    _link .> carries(_room) .> irc_registered(this, _settled)
    _feed(":alice[marilwyd]!u@h JOIN #pony")

    // A ghost, so the room will accept from them.
    _room.admit_ghost("@irc_net_bob:example.test", "bob")

    // Two senders and two msgtypes, then a sentinel. Only the owner's
    // own `m.text` should reach the channel: the ghost's words came *from*
    // it, and an image is not something IRC carries.
    //
    // The sentinel goes through the room like the rest rather than
    // straight to the link. Everything here is one chain of sender pairs
    // — this actor to the room, the room to the link, the link back here
    // — so the order is guaranteed the whole way. An earlier version
    // relayed it directly and raced the fan-out.
    _send("@alice:example.test", "m.text", "mine")
    _send("@irc_net_bob:example.test", "m.text", "a ghost speaking")
    _send("@alice:example.test", "m.image", "photo.jpg")
    // Ciphertext from an encrypted room, which is a different event kind
    // rather than a different msgtype — so it is turned away one step
    // earlier than the image is, and this is the step that matters most.
    _room.send(
      "@alice:example.test",
      "m.room.encrypted",
      "{\"algorithm\":\"m.megolm.v1.aes-sha2\"," +
        "\"ciphertext\":\"AwgAEnB5cGhlcnRleHQ\"}",
      this)
    _send("@alice:example.test", "m.text", _Finished())

  fun ref _send(who: String, kind: String, body: String) =>
    _room.send(
      who,
      "m.room.message",
      "{\"msgtype\":\"" + kind + "\",\"body\":\"" + body + "\"}",
      this)

  fun ref _feed(raw: String) =>
    match irc.Parse(raw)
    | let m: irc.Message val => _link.irc_message(this, m, _settled)
    else
      _h.fail("could not parse: " + raw)
      _h.complete(false)
    end

  be event_sent(id: EventId) => None

  be event_refused(why: (NotInRoom | NoEventId | BridgeDown | TooManyLines)) =>
    _h.fail("the room refused an event it should have taken")
    _h.complete(false)

  be privmsg(target: irc.Target, text: String val) =>
    if text.contains(_Finished()) then
      _check()
      return
    end
    _sent.push(text)

  be notice(target: irc.Target, text: String val) =>
    _sent.push(text)

  fun _check() =>
    var mine = false
    for line in _sent.values() do
      if line.contains("mine") then
        mine = true
      end
      _h.assert_false(
        line.contains("a ghost speaking"),
        "a ghost's words went back out to the channel: " + line)
      _h.assert_false(
        line.contains("photo.jpg"),
        "something that is not a message was relayed: " + line)
      _h.assert_false(
        line.contains("AwgAEnB5cGhlcnRleHQ"),
        "an encrypted room's ciphertext was relayed to IRC: " + line)
    end
    _h.assert_true(mine, "the owner's own words did not reach the channel")
    _h.complete(true)

  be print(data: ByteSeq) => None
  be write(data: ByteSeq) => None
  be printv(data: ByteSeqIter) => None
  be writev(data: ByteSeqIter) => None
  be flush() => None

  be room_refused() =>
    _h.fail("the room was not created")
    _h.complete(false)

  be alias_taken() =>
    _h.fail("an unnamed room claimed an alias")
    _h.complete(false)

  be send(line: irc.Line val) => None
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

primitive \nodoc\ _Finished
  """
  Relayed last, so that seeing it go out means everything before it has.
  """
  fun apply(): String => "zzz-that-is-everything"

class \nodoc\ iso _TestALongMessageIsRefusedByABridge is UnitTest
  """
  A message longer than the bridge carries is refused, not sent in part.

  A bridged room's messages leave over a paced connection: a burst, then
  one line every couple of seconds, and past the send queue's depth the
  rest is dropped. A paragraph therefore arrives over minutes and then
  stops arriving, while the client that wrote it was told it succeeded and
  given an event id. Refusing is the only one of those two a client can
  act on.
  """
  fun name(): String => "links/a message too long for the bridge is refused"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    try
      _LinkLifecycle(h, _LinkFixture.create()?, _SendsTooMuch)
    else
      _NoRandom(h)
    end
