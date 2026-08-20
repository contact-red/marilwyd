use "collections"
use "json"
use "time"
use irc = "irc"

primitive MaxEarlyMembers
  """
  How much of a channel's membership is held while there is no room yet.

  The window is three actor hops wide — the connection tells the handler it
  is in, the handler tells the room, the room tells the connection — so a
  real channel fits its whole name list in it many times over. The bound is
  here because the far side fills this and marilwyd does not, and anything
  a stranger fills has a limit. Past it the room learns of somebody when
  they speak, which is what used to happen to everybody.
  """
  fun apply(): USize => 1024

primitive JoinDeadline
  """
  How long a Matrix client waits while its IRC connection is opened.

  Its own deadline rather than the `irc` package's, whose connect and
  registration timeouts are thirty seconds *each* — a join inheriting both
  could wait a minute before answering. This bounds the whole attempt, so
  what a person waits is what is written here.

  Under hobby's handler watchdog, for `MaxSyncWait`'s reason and by the
  same margin. That watchdog is armed when the handler is built and this
  deadline only once a token is resolved, a room is found and a socket is
  opened — so at equal values hobby always wins, and the client gets a
  bodiless 504 instead of the refusal this exists to send.
  """
  fun apply(): U64 => 25_000_000_000

actor UserLink is (irc.IRCNotify & RoomMember)
  """
  One Matrix user's own connection to one IRC network.

  A bouncer rather than presence. The connection opens when the user joins
  the bridged room and closes when they explicitly leave, so idling in a
  channel — which is the ordinary way to be on IRC — is what membership
  means here. That is also why there is no bot: a room's traffic is carried
  by the connections of the people in it, so nothing relays on anyone's
  behalf and nothing sees its own words come back.

  It is a `RoomMember`, so a room fans out to it exactly as it does to a
  `User`. The room never learns which it is holding.
  """
  let _user_id: String
  let _network: BridgedNetwork
  let _channel: String
  let _out: (OutStream tag | None)
  let _mapping: NameMapping
  let _homeserver: Homeserver
  var _room: (Room tag | None) = None
  var _link: (irc.IRC tag | None) = None
  var _sending: (irc.IRCSend tag | None) = None
  var _waiting: (JoinReceiver tag | None) = None
  var _joined: Bool = false
  let _timers: Timers = Timers
  var _deadline: (Timer tag | None) = None
  // Who to tell when this connection is finished for good. Held because a
  // connection that has died has to be forgotten by the directory as well
  // as by the room: a directory that kept it would answer the next join
  // with it, and that join would succeed into a room carrying nothing.
  var _directory: (LinkOwner tag | None) = None
  // Who the channel says is there, recorded until there is a room to tell.
  // The server sends its name list the instant the channel is entered,
  // which is before the room has handed back its own reference — so
  // without this the list a person most wants, the one they arrive to, is
  // the one always missed.
  embed _early: Array[(String, String, Bool)] = _early.create()

  new create(
    user_id: String,
    network: BridgedNetwork,
    channel: String,
    mapping: NameMapping,
    homeserver: Homeserver,
    out: (OutStream tag | None))
  =>
    _user_id = user_id
    _network = network
    _channel = channel
    _mapping = mapping
    _homeserver = homeserver
    _out = out

  be directed_by(directory: LinkOwner tag) =>
    """
    The directory that holds this connection, and must drop it when it
    dies.
    """
    _directory = directory

  be carries(room: Room tag) =>
    """
    The room this connection reads for.

    A connection carries both directions: its owner's words out, and what
    the channel says in. With no bot there is nothing else listening, so a
    room hears the channel through the connections of the people in it —
    which is also why a room nobody has joined hears nothing, exactly as an
    IRC user who is not connected hears nothing.
    """
    _room = room
    for (ghost, shown, present) in _early.values() do
      if present then
        room.admit_ghost(ghost, shown)
      else
        room.part_ghost(ghost)
      end
    end
    _early.clear()

  be connect(link: irc.IRC tag, receiver: JoinReceiver tag) =>
    """
    Take the connection opened for this user, and answer once the channel
    is joined or the attempt runs out of time.

    The connection is built outside and handed in because an actor
    constructor cannot report a failure, and building one needs an
    `AmbientAuth` this actor has no other reason to hold.
    """
    _link = link
    _waiting = receiver

    let timer =
      Timer(_JoinDeadline(this), JoinDeadline(), 0)
    _deadline = timer
    _timers(consume timer)

  be expired() =>
    """
    The attempt ran out of time. The user is not in the room.
    """
    match _waiting
    | let receiver: JoinReceiver tag =>
      _waiting = None
      receiver.join_refused(_channel)
      _finished("gave up waiting for " + _network.name)
    end

  be relay(text: String, notice: Bool = false) =>
    """
    Say something on the channel as this user.

    Split before it is sent, because one Matrix message is not one IRC
    line — and paced by the connection, which is what stops a paragraph
    being read as a flood and the connection killed for it.

    A notice leaves as a `NOTICE`. That is not decoration: on IRC the two
    are how a person tells automated traffic from someone talking, and
    relaying a notice as an ordinary message makes a bot indistinguishable
    from a person.
    """
    match (_sending, irc.Channels(_channel))
    | (let sending: irc.IRCSend tag, let channel: irc.Channel) =>
      for line in SplitForIrc(text).values() do
        if notice then
          sending.notice(channel, line)
        else
          sending.privmsg(channel, line)
        end
      end
    else
      // `Room.send` refuses while this connection is stalled, so reaching
      // here means the connection died between that check and this
      // message. Rare, and still somebody's words going nowhere, so it is
      // said rather than dropped in silence.
      _say(_user_id + ": a message was lost as " + _network.name
        + " went away")
    end

  be part() =>
    """
    The user left the room. Leave the channel and drop the connection.
    """
    _close()

  fun ref _finished(why: String) =>
    """
    This connection is over and will not carry anything again.

    The one place a death is handled, because the ways of dying differ
    and what has to follow from them does not: say why, stop the socket,
    part the owner from a room whose whole content was this connection,
    and have the directory forget it. Leaving any of those out is how a
    dead connection went on looking alive — the room accepted messages
    nobody received, and the next join found the corpse and succeeded.
    """
    _say(_user_id + ": " + why)
    match _room
    | let room: Room tag => room.leave(_user_id, _IgnoreDeparture)
    end
    match _directory
    | let directory: LinkOwner tag =>
      directory.forget(_user_id, _network.name, _channel)
    end
    _room = None
    _close()

  fun ref _close() =>
    match _deadline
    | let timer: Timer tag =>
      _timers.cancel(timer)
      _deadline = None
    end
    match _sending
    | let sending: irc.IRCSend tag => sending.quit("left the room")
    else
      // `quit` only reaches a registered connection, and the whole window
      // the join deadline covers is before registration. Without this a
      // timed-out attempt left the socket retrying under that user's
      // nickname for the life of the process.
      match _link
      | let link: irc.IRC tag => link.disconnect()
      end
    end
    _sending = None
    _link = None
    _joined = false

  be irc_registered(irc': irc.IRCSend tag, reg: irc.Registration val) =>
    """
    Registered, so this is the first moment a send reaches the network.

    Fires again after every reconnect, which is why the channel is joined
    here rather than once at connect.
    """
    _sending = irc'
    match \exhaustive\ irc.Channels(_channel)
    | let channel: irc.Channel =>
      irc'.join(recover val [channel] end)
    | let _: irc.InvalidName =>
      // Unreachable from a configuration `ReadBridges` accepted, which
      // now checks the name against this same function. Answered rather
      // than ignored anyway, because the alternative is a connection that
      // registers, never joins, and waits out every deadline in silence.
      _finished(
        "cannot join " + _channel + ": the network would refuse the name")
    end

  be irc_message(
    irc': irc.IRCSend tag,
    m: irc.Message val,
    reg: (irc.Registration val | None))
  =>
    """
    Everything this connection hears, sorted by what it means.

    Registration and the channel's own membership are watched as closely as
    what is said: a person reading a bridged channel wants to see who is
    there before anybody speaks, and to see them come and go.
    """
    let settled =
      match reg
      | let r: irc.Registration val => r
      else
        return
      end

    if not _joined then
      _watch_for_join(m, settled)
      return
    end

    match m.command()
    | "PRIVMSG" => _heard(irc', m, settled)
    | "NOTICE" => _heard(irc', m, settled)
    | "353" => _named(m, settled)
    | "JOIN" => _arrived(m, settled)
    | "PART" => _left(m, settled)
    | "QUIT" => _left(m, settled)
    | "KICK" => _kicked(m, settled)
    | "NICK" => _renamed(m, settled)
    end

  fun ref _watch_for_join(m: irc.Message val, settled: irc.Registration val)
  =>
    """
    This connection's own JOIN, which is what says the channel was entered.

    A server may accept a JOIN and refuse it, so answering the Matrix
    client before its own JOIN comes back would report a membership that
    does not exist.
    """
    if m.command() != "JOIN" then
      return
    end

    match m.nick()
    | let who: irc.Nick =>
      if not settled.same(who, settled.me()) then
        return
      end
    else
      return
    end

    _joined = true
    match _deadline
    | let timer: Timer tag =>
      _timers.cancel(timer)
      _deadline = None
    end
    match _waiting
    | let receiver: JoinReceiver tag =>
      _waiting = None
      receiver.joined_with(_channel, this)
      return
    end

    // No one waiting means this is a reconnect rather than the first
    // entry, so the room is holding a member whose sends have been
    // refused since the drop. It is on the channel again.
    match _room
    | let room: Room tag => room.carrier_carrying(_user_id)
    end
    // Said for the same reason the drop is: an operator watching a bridge
    // flap needs both ends of it, and a recovery that is silent looks
    // from the log like an outage that never ended.
    _say(_user_id + " is back on " + _network.name + " " + _channel)

  fun ref _named(m: irc.Message val, settled: irc.Registration val) =>
    """
    The channel's membership, as the server lists it on joining.

    Everyone is admitted at once rather than when they first speak. A
    channel's member list is what a person reads to know who they are
    talking to, and a list that fills in only as people happen to talk
    shows an empty room full of people.

    Each name may carry a mode prefix — `@` for an operator, `+` for
    voice — and which byte means which is the server's choice rather than
    a constant, so the set is read from what the server announced.
    """
    let listed =
      try
        // `353` is `<me> <symbol> <channel> :<names>`, and the channel is
        // the parameter before the trailing one.
        let params = m.params()
        if not settled.same_text(params(params.size() - 2)?, _channel) then
          return
        end
        m.trailing()
      else
        return
      end

    let marks = irc.Isupport.prefixes(settled.isupport("PREFIX"))
    for name in ChannelNames(listed, marks).values() do
      match irc.Nicks(name)
      | let who: irc.Nick =>
        if not settled.same(who, settled.me()) then
          _admit(who, settled)
        end
      end
    end

  fun ref _arrived(m: irc.Message val, settled: irc.Registration val) =>
    """
    Somebody joined the channel.
    """
    match m.nick()
    | let who: irc.Nick =>
      if not settled.same(who, settled.me()) then
        _admit(who, settled)
      end
    end

  fun ref _left(m: irc.Message val, settled: irc.Registration val) =>
    """
    Somebody left the channel, or the network.

    A `QUIT` carries no channel — it means every channel they shared — so
    it is applied here without checking one. Removing somebody who was not
    a member is what `part_ghost` already ignores.
    """
    match m.nick()
    | let who: irc.Nick =>
      if not settled.same(who, settled.me()) then
        _depart(who, settled)
      end
    end

  fun ref _kicked(m: irc.Message val, settled: irc.Registration val) =>
    """
    Somebody was removed by an operator. The person removed is the
    parameter, not the sender.
    """
    let name =
      try
        m.params()(1)?
      else
        return
      end
    match irc.Nicks(name)
    | let who: irc.Nick =>
      if not settled.same(who, settled.me()) then
        _depart(who, settled)
      end
    end

  fun ref _renamed(m: irc.Message val, settled: irc.Registration val) =>
    """
    Somebody changed nickname.

    Rendered as a leave and a join rather than as a rename, because a
    ghost's Matrix id is derived from the nickname: the new name is a
    different user id, and there is nothing to carry across. A client
    shows the two events, which is what an IRC client shows too.
    """
    match (m.nick(), irc.Nicks(m.trailing()))
    | (let before: irc.Nick, let after: irc.Nick) =>
      if not settled.same(before, settled.me()) then
        _depart(before, settled)
        _admit(after, settled)
      end
    end

  fun ref _admit(who: irc.Nick, settled: irc.Registration val) =>
    match _room
    | let room: Room tag =>
      room.admit_ghost(_ghost(who, settled), ValidUtf8(who.display()))
    else
      if _early.size() < MaxEarlyMembers() then
        _early.push((_ghost(who, settled), ValidUtf8(who.display()), true))
      end
    end

  fun ref _depart(who: irc.Nick, settled: irc.Registration val) =>
    match _room
    | let room: Room tag =>
      room.part_ghost(_ghost(who, settled))
    else
      // Recorded in order rather than cancelling the join it follows: a
      // person who joined and left before the room existed was there, and
      // replaying both is what leaves the room agreeing with the channel.
      if _early.size() < MaxEarlyMembers() then
        _early.push((_ghost(who, settled), "", false))
      end
    end

  fun _ghost(who: irc.Nick, settled: irc.Registration val): String =>
    """
    The Matrix user id for a far-side participant.

    Folded under the network's own rules first, because IRC nicknames are
    case-insensitive and two spellings are one person.
    """
    _homeserver.user_id(
      _mapping.matrix_localpart(
        _network.name, GhostLocalpart(settled.key(who))))

  fun ref _heard(
    irc': irc.IRCSend tag,
    m: irc.Message val,
    settled: irc.Registration val)
  =>
    """
    Something said on the channel, or asked of this connection directly.

    A message from this connection's own owner is skipped: they said it on
    Matrix, and it reached IRC because this connection sent it. Everyone
    else's words arrive as their ghost.
    """
    let who =
      match m.nick()
      | let n: irc.Nick => n
      else
        return
      end

    // Only this connection's own nickname. Another marilwyd user is a
    // participant on the channel like anyone else, and their words reach
    // this room as their ghost — which is what a person on IRC sees of
    // somebody using a different client.
    if settled.same(who, settled.me()) then
      return
    end

    let target =
      try
        m.params()(0)?
      else
        return
      end
    let addressed = settled.same_text(target, _channel)

    match m.ctcp()
    | let embedded: irc.Ctcp val =>
      // A CTCP arriving as a NOTICE is somebody's *answer*, and answering
      // an answer is how two clients flood each other off a server.
      if m.command() != "PRIVMSG" then
        return
      end
      if _IsCtcp(embedded, "ACTION") then
        // `/me`. An emote and a message differ only in how a client renders
        // them, so this is the same relay with a different msgtype — and
        // without it a third of what is said on a channel is invisible.
        if addressed then
          _relayed(who, settled, "m.emote", embedded.argument())
        end
      else
        _answered(irc', who, embedded)
      end
      return
    end

    if not addressed then
      return
    end

    // A `NOTICE` stays a notice. The two are how a person on IRC tells
    // automated traffic from someone talking, and the distinction is the
    // same one Matrix draws — carrying it across is free.
    let kind =
      if m.command() == "NOTICE" then "m.notice" else "m.text" end
    _relayed(who, settled, kind, m.trailing())

  fun ref _relayed(
    who: irc.Nick,
    settled: irc.Registration val,
    kind: String,
    said: String)
  =>
    """
    Put one person's words into the room under their ghost.

    Admitted on the way past as well as at join, because a channel is not
    only entered at join: a netsplit heals, a name list can be missed, and
    somebody speaking is proof they are there whatever the membership says.
    """
    _admit(who, settled)
    match _room
    | let room: Room tag =>
      room.send(
        _ghost(who, settled),
        "m.room.message",
        "{\"msgtype\":\"" + kind + "\",\"body\":"
          + JsonPrinter.print(ValidUtf8(said)) + "}",
        _IgnoreRelay)
    end

  fun _answered(
    irc': irc.IRCSend tag,
    who: irc.Nick,
    asked: irc.Ctcp val)
  =>
    """
    Answer a CTCP request aimed at this connection.

    `PING` alone. It is what an IRC client sends to measure the round trip
    to somebody, and a connection that never answers reads as one that is
    not there. The argument is echoed back untouched because it is the
    asker's own timestamp — its meaning is theirs, not this server's.

    Anything else is ignored rather than refused. A client that hears
    nothing tries something else; one told a request failed shows the
    person an error for a question they did not ask.
    """
    if not _IsCtcp(asked, "PING") then
      return
    end
    match irc.Wire.ctcp_reply(who, "PING", asked.argument())
    | let line: irc.Line val => irc'.send(line)
    end

  be irc_session(irc': irc.IRCSend tag, ended: irc.SessionEnded val) =>
    """
    The connection dropped, and the library will try it again.

    Transient, so the member keeps their room: a connection that comes
    back is what a bouncer is, and parting somebody over a netsplit would
    make the Matrix room noisier than the channel it mirrors. What stops
    is sending — the room is told, so a message written while the network
    is unreachable is refused rather than accepted and lost.

    A user still waiting on the first attempt is refused now rather than
    left to the deadline: a network that has already said no has answered.
    """
    dropped(ended.string())

  be irc_stopped(irc': irc.IRCSend tag, ended: irc.SessionEnded val) =>
    """
    The connection is finished and will not be attempted again.

    Terminal, unlike `irc_session`, so the member does not keep a room
    that can never carry anything again. They are parted and the
    directory drops this connection, which is what makes a later join a
    fresh attempt rather than an instant success into a dead link.
    """
    died(ended.string())

  be dropped(why: String) =>
    """
    The connection went away and the library will try it again.

    Taken apart from `irc_session` because that behaviour speaks the
    library's vocabulary and this speaks marilwyd's — and because a
    `SessionEnded` cannot be built outside the `irc` package, so the
    whole of this path was unreachable from a test while it was one
    behaviour.

    Transient, so the member keeps their room: a connection that comes
    back is what a bouncer is, and parting somebody over a netsplit would
    make the Matrix room noisier than the channel it mirrors. What stops
    is sending — the room is told, so a message written while the network
    is unreachable is refused rather than accepted and lost.
    """
    _sending = None
    _joined = false

    match _waiting
    | let receiver: JoinReceiver tag =>
      // Still waiting on the first attempt, so this is a refusal rather
      // than a drop: a network that has already said no has answered.
      _waiting = None
      receiver.join_refused(_channel)
      _finished("could not reach " + _network.name + ": " + why)
      return
    end

    match _room
    | let room: Room tag => room.carrier_stalled(_user_id)
    end
    _say(_user_id + " lost " + _network.name + ": " + why)

  be died(why: String) =>
    """
    The connection is finished and will not be attempted again.

    Terminal, unlike `dropped`, so the member does not keep a room that
    can never carry anything again.
    """
    _sending = None
    _joined = false
    match _waiting
    | let receiver: JoinReceiver tag =>
      _waiting = None
      receiver.join_refused(_channel)
    end
    _finished(_network.name + " is gone: " + why)

  be irc_unparseable(
    irc': irc.IRCSend tag,
    raw: String val,
    why: irc.ParseFailure val)
  =>
    None

  be irc_dropped(irc': irc.IRCSend tag, what: irc.Dropped) =>
    // What a person said and the network would not carry. Reported because
    // the alternative is a message that silently never arrived.
    _say(_user_id + " had a line dropped on " + _network.name)

  be deliver(event: RoomEvent) =>
    """
    A room event, which is what this actor exists to carry outward.

    **Only its owner's own words.** This connection wears one person's
    nickname, so it can only honestly say what that person said —
    relaying somebody else's would put their words on IRC under the wrong
    name. Everyone else in the room has their own connection saying their
    own words, which is the whole of what the bouncer model buys: no bot
    speaking for anyone, and nothing to attribute.

    There is no echo to prevent. Nothing sends to this connection but its
    owner, and IRC does not repeat what a client sent — an earlier version
    skipped events from `_user_id` on the reasoning a relay bot needs, and
    that skipped everything this actor exists to send.

    Only what a person wrote: `m.text` and `m.notice`. A membership, a
    receipt or a state change is Matrix's own bookkeeping and has no
    reading on IRC.
    """
    if event.sender != _user_id then
      return
    end
    if event.kind != "m.room.message" then
      return
    end
    match _Said(event.content)
    | (let text: String, let notice: Bool) => relay(text, notice)
    end

  be joined(room_id: String, room: Room tag) => None

  be departed(room_id: String) =>
    part()

  fun _say(what: String) =>
    match _out
    | let o: OutStream tag => o.print("marilwyd: " + what)
    end

class _JoinDeadline is TimerNotify
  """
  Ends a join attempt that the far side never answered.
  """
  let _link: UserLink

  new iso create(link: UserLink) =>
    _link = link

  fun ref apply(timer: Timer, count: U64): Bool =>
    _link.expired()
    false

primitive _Said
  """
  What a room event says, when it says anything IRC can carry.

  `m.text` and `m.notice` only. A notice is what bots and bridges
  conventionally send, and relaying one as an ordinary message would make
  automated traffic indistinguishable from a person talking.
  """
  fun apply(content: String): ((String, Bool) | None) =>
    let sent =
      match JsonParser.parse(content)
      | let o: JsonObject => o
      else
        return None
      end

    let kind =
      try
        match sent("msgtype")?
        | let text: String => text
        else
          return None
        end
      else
        return None
      end

    if (kind != "m.text") and (kind != "m.notice") then
      return None
    end

    try
      match sent("body")?
      | let body: String => return (ValidUtf8(body), kind == "m.notice")
      end
    end
    None

actor _IgnoreRelay is EventReceiver
  """
  A relayed message's own answer is nobody's business: there is no client
  waiting on it, and a refusal means the ghost was not admitted, which
  `admit_ghost` has already settled.
  """
  be event_sent(id: EventId) => None
  be event_refused(why: (NotInRoom | NoEventId | BridgeDown)) => None

primitive _IsCtcp
  """
  Is this the CTCP command named?

  Case-insensitively, because the protocol does not say which case a client
  sends and they do not agree: comparing exactly answers `/me` for one
  client and silence for another.
  """
  fun apply(embedded: irc.Ctcp val, command: String): Bool =>
    let sent = embedded.command()
    if sent.size() != command.size() then
      return false
    end
    var at: USize = 0
    while at < sent.size() do
      try
        if _Upper(sent(at)?) != _Upper(command(at)?) then
          return false
        end
      else
        return false
      end
      at = at + 1
    end
    true

primitive _Upper
  fun apply(byte: U8): U8 =>
    if (byte >= 'a') and (byte <= 'z') then byte - 32 else byte end

actor \nodoc\ _IgnoreDeparture is MembershipReceiver
  """
  A connection parting its own owner has nobody to answer.

  The client is not waiting on this: it asked to join, or it asked
  nothing at all and the network went away underneath it. What it sees is
  the membership event the room fans out, which is the same thing it
  would see if the person had left by hand.
  """
  be membership_changed(room: RoomId) => None
