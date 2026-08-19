use "collections"
use "json"
use irc = "irc"

actor IrcBridge is irc.IRCNotify
  """
  One IRC network, and the rooms its channels are.

  Inbound only, for now: what is said on a channel reaches the Matrix room,
  and nothing goes the other way. That is the half with no injection
  surface — marilwyd sends the network nothing a person wrote — and it is
  worth having on its own, because reading a channel from a phone is most
  of what a bridge is for.

  It is not a `RoomMember`. It receives nothing from the rooms it feeds, so
  it holds their tags and they do not hold its. When the outbound half
  lands that changes, and the room will fan out to it like any member.
  """
  let _network: BridgedNetwork
  let _mapping: NameMapping
  let _homeserver: Homeserver
  let _out: (OutStream | None)
  // Keyed by the channel as configured. A room is attached once its
  // declaration has been answered, so a message arriving before that is
  // dropped rather than queued: it belongs to a channel this process is
  // not yet carrying.
  embed _rooms: Map[String, Room tag] = _rooms.create()
  // The last server timestamp acted on, per channel. A bouncer replays its
  // buffer to every attaching client and this package reconnects on its
  // own, so without this every reconnect would relay the same lines into
  // the room again. The `irc` package's own docstring names the hazard.
  embed _seen: Map[String, I64] = _seen.create()

  new create(
    network: BridgedNetwork,
    mapping: NameMapping,
    homeserver: Homeserver,
    out: (OutStream | None))
  =>
    _network = network
    _mapping = mapping
    _homeserver = homeserver
    _out = out

  be carries(channel: String, room: Room tag) =>
    """
    Attach the room one channel's traffic belongs in.
    """
    _rooms(channel.clone()) = room

  be irc_registered(irc': irc.IRCSend tag, reg: irc.Registration val) =>
    """
    Join every configured channel.

    Here rather than at connect, and again after every reconnect, because
    this is the first moment a send reaches the network and the package
    reconnects on its own.
    """
    let wanted = recover iso Array[irc.Channel] end
    for channel in _network.channels.values() do
      match irc.Channels(channel.channel)
      | let c: irc.Channel => wanted.push(c)
      end
    end
    irc'.join(consume wanted)
    _say("joined " + _network.name)

  be irc_message(
    irc': irc.IRCSend tag,
    m: irc.Message val,
    reg: (irc.Registration val | None))
  =>
    """
    Relay one channel message into its room.

    Everything else the server says is ignored rather than logged: this is
    the inbound half of a bridge, not a client.
    """
    if m.command() != "PRIVMSG" then
      return
    end

    // A CTCP is not a message a room can render — an ACTION is `/me` and
    // the rest are client-to-client requests nobody here can answer.
    match m.ctcp()
    | let _: irc.Ctcp val => return
    end

    let target =
      try
        m.params()(0)?
      else
        return
      end

    let room =
      try
        _rooms(target)?
      else
        return
      end

    let settled =
      match reg
      | let r: irc.Registration val => r
      else
        return
      end

    // Its own words coming back. Nothing is sent yet, so this cannot fire
    // today — it is here because the day it can, silence is the wrong
    // failure and this is where it would have to be added anyway.
    match m.nick()
    | let who: irc.Nick =>
      if settled.same(who, settled.me()) then
        return
      end

      // A bouncer replays; the package reconnects. Both mean a line can
      // arrive twice, and a relayed duplicate is a message a person reads
      // twice with no way to tell.
      match m.at()
      | let when: I64 =>
        if when <= _seen.get_or_else(target, I64(0)) then
          return
        end
        _seen(target.clone()) = when
      end

      // `key` is the folded form the package hands out for exactly this —
      // its docstring says never to show it to a person, which is why the
      // display name below comes from `display` instead.
      let ghost: String =
        _homeserver.user_id(
          _mapping.matrix_localpart(
            _network.name, GhostLocalpart(settled.key(who))))

      // Cloned and made valid before anything downstream sees it: the
      // parameters are views into the line, and IRC carries bytes rather
      // than text.
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

  be irc_unparseable(
    irc': irc.IRCSend tag,
    raw: String val,
    why: irc.ParseFailure val)
  =>
    None

  be irc_dropped(irc': irc.IRCSend tag, what: irc.Dropped) =>
    // Nothing is sent yet, so nothing can be dropped. Reported rather than
    // ignored because the interface has no defaults on purpose.
    _say("a send was dropped on " + _network.name)

  be irc_session(irc': irc.IRCSend tag, ended: irc.SessionEnded val) =>
    _say(_network.name + " ended: " + ended.string())

  be irc_stopped(irc': irc.IRCSend tag, ended: irc.SessionEnded val) =>
    _say(_network.name + " stopped: " + ended.string())

  fun _say(what: String) =>
    match _out
    | let o: OutStream => o.print("marilwyd: " + what)
    end

actor _IgnoreRelay is EventReceiver
  """
  A relayed message's own answer is nobody's business: there is no client
  waiting on it, and a refusal means the ghost was not admitted, which
  `admit_ghost` has already settled.
  """
  be event_sent(id: EventId) => None
  be event_refused(why: (NotInRoom | NoEventId)) => None
