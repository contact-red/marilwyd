use "collections"
use "files"
use irc = "irc"

actor LinkDirectory
  """
  Every Matrix user's own IRC connection, and the one place they are made.

  One per (user, channel), because that pairing is what a connection is
  for: entering a bridged room opens one, leaving closes it, and holding
  one is what membership of that room means.

  It exists at all because an actor constructor cannot fail and building a
  connection needs an `AmbientAuth` no room or handler has any other reason
  to hold. Keeping them here also means a user who joins the same room
  twice does not open a second connection under the same nickname, which a
  network would refuse.
  """
  let _env: Env
  let _homeserver: Homeserver
  let _mapping: NameMapping
  embed _links: Map[String, UserLink tag] = _links.create()

  new create(env: Env, homeserver: Homeserver, mapping: NameMapping) =>
    _env = env
    _homeserver = homeserver
    _mapping = mapping

  be open(
    user_id: String,
    channel: BridgedChannel,
    network: BridgedNetwork,
    room: Room tag,
    receiver: JoinReceiver tag)
  =>
    """
    Open this user's connection for one channel, or answer that it could
    not be opened.

    A connection that already exists is answered at once. That is what
    makes joining a room you are already in cheap rather than a second
    registration the network would reject.
    """
    let key: String = _key(user_id, network.name, channel.channel)
    try
      let existing = _links(key)?
      // Already connected, so nothing to open — but the room still has to
      // be told which connection carries this member, because a rejoin
      // reaches a room that may have forgotten.
      receiver.joined_with(channel.channel, existing)
      return
    end

    let link =
      UserLink(
        user_id, network, channel.channel, _mapping, _homeserver, _env.out)

    // The nickname a Matrix user wears on IRC, and the fallbacks the
    // network walks when it is taken. `_` rather than a number because it
    // is what an IRC client does and what a person recognises.
    let localpart: String = LocalpartOf(user_id)
    let wanted: String = _mapping.irc_nick(localpart)
    let nicks =
      recover val [wanted; wanted + "_"; wanted + "__"] end

    match \exhaustive\ Connect(_env, network, link where nicks' = nicks)
    | let opened: irc.IRC =>
      _links(key) = link
      // The room and this directory before the connection, so a line
      // arriving the instant after registration has somewhere to go and
      // a death the instant after that has somewhere to report.
      link .> carries(room) .> directed_by(this) .> connect(opened, receiver)
    | let e: StartupError =>
      // Said, not swallowed. This is the operator's only sight of a
      // bridge that cannot be built at all — a bad host, a certificate
      // store that would not load — and the client learns only that its
      // join was refused.
      _env.out.print(
        "marilwyd: " + user_id + " cannot reach " + network.name + ": "
          + e.message)
      receiver.join_refused(channel.channel)
    end

  be close(user_id: String, channel: String, network: String) =>
    """
    The user left the room, so the connection goes.
    """
    let key: String = _key(user_id, network, channel)
    try
      (_, let link: UserLink tag) = _links.remove(key)?
      link.part()
    end

  be forget(user_id: String, network: String, channel: String) =>
    """
    A connection reporting its own death, so the next join opens a fresh
    one.

    Without this the entry outlived the connection, and `open`'s fast
    path — which exists so that rejoining a room does not register a
    second time — answered the next join with a corpse. That join
    succeeded, the room accepted messages, and none of them went
    anywhere.

    No `part()` on the way out: the connection is already gone, and it is
    the caller.
    """
    try
      (_, _) = _links.remove(_key(user_id, network, channel))?
    end

  fun _key(user_id: String, network: String, channel: String): String =>
    user_id + " " + network + " " + channel

primitive LocalpartOf
  """
  The local part of a full Matrix user id — the `alice` in
  `@alice:example.org` — which is what an IRC nickname is made from.

  Extraction, not validation. `Localpart` is the neighbouring primitive
  that answers whether a local part is usable; this one takes an id apart
  and answers with whatever was in it. An id with no colon is answered
  whole, because the only thing that could be meant by one is the part
  itself.
  """
  fun apply(user_id: String): String =>
    let colon =
      try
        user_id.find(":")?
      else
        return user_id
      end
    user_id.substring(1, colon)
