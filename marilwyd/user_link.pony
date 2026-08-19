use "collections"
use "json"
use "time"
use irc = "irc"

primitive JoinDeadline
  """
  How long a Matrix client waits while its IRC connection is opened.

  Its own deadline rather than the `irc` package's, whose connect and
  registration timeouts are thirty seconds *each* — a join inheriting both
  could wait a minute before answering. This bounds the whole attempt, so
  what a person waits is what is written here.
  """
  fun apply(): U64 => 30_000_000_000

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
      _close()
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
    end

  be part() =>
    """
    The user left the room. Leave the channel and drop the connection.
    """
    _close()

  fun ref _close() =>
    match _deadline
    | let timer: Timer tag =>
      _timers.cancel(timer)
      _deadline = None
    end
    match _sending
    | let sending: irc.IRCSend tag => sending.quit("left the room")
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
    match irc.Channels(_channel)
    | let channel: irc.Channel =>
      irc'.join(recover val [channel] end)
    end

  be irc_message(
    irc': irc.IRCSend tag,
    m: irc.Message val,
    reg: (irc.Registration val | None))
  =>
    """
    Two jobs on one connection: notice when the channel was entered, and
    carry what is said there into the room.
    """
    let settled =
      match reg
      | let r: irc.Registration val => r
      else
        return
      end

    if _joined and (m.command() == "PRIVMSG") then
      _heard(m, settled)
      return
    end

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
    end

  fun _heard(m: irc.Message val, settled: irc.Registration val) =>
    """
    Relay one channel message into the room.

    A message from this connection's own owner is skipped: they said it on
    Matrix, and it reached IRC because this connection sent it. Everyone
    else's words arrive as their ghost.
    """
    match m.ctcp()
    | let _: irc.Ctcp val => return
    end

    let target =
      try
        m.params()(0)?
      else
        return
      end
    if not settled.same_text(target, _channel) then
      return
    end

    let room =
      match _room
      | let r: Room tag => r
      else
        return
      end

    match m.nick()
    | let who: irc.Nick =>
      // Only this connection's own nickname. Another marilwyd user is a
      // participant on the channel like anyone else, and their words
      // reach this room as their ghost — which is what a person on IRC
      // sees of somebody using a different client.
      //
      // An earlier version skipped every nickname the mapping could have
      // produced. That belonged to a design where one room had several
      // connections and each heard the others; with a room per person
      // there is no such duplication, and the wider filter silently
      // dropped every message from another Matrix user.
      if settled.same(who, settled.me()) then
        return
      end

      let ghost: String =
        _homeserver.user_id(
          _mapping.matrix_localpart(
            _network.name, GhostLocalpart(settled.key(who))))
      let said = ValidUtf8(m.trailing().clone())
      let shown = ValidUtf8(who.display())
      room
        .> admit_ghost(ghost, shown)
        .> send(
          ghost,
          "m.room.message",
          "{\"msgtype\":\"m.text\",\"body\":"
            + JsonPrinter.print(said) + "}",
          _IgnoreRelay)
    end

  be irc_session(irc': irc.IRCSend tag, ended: irc.SessionEnded val) =>
    """
    The connection ended. A user waiting on it is refused rather than left
    to the deadline: a network that said no has already answered.
    """
    _sending = None
    _joined = false
    match _waiting
    | let receiver: JoinReceiver tag =>
      _waiting = None
      receiver.join_refused(_channel)
    end
    _say(_user_id + " lost " + _network.name + ": " + ended.string())

  be irc_stopped(irc': irc.IRCSend tag, ended: irc.SessionEnded val) =>
    _sending = None
    _joined = false
    match _waiting
    | let receiver: JoinReceiver tag =>
      _waiting = None
      receiver.join_refused(_channel)
    end

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
  be event_refused(why: (NotInRoom | NoEventId)) => None
