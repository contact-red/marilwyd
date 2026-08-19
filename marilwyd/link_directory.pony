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
    let localpart: String = _Localpart(user_id)
    let wanted: String = _mapping.irc_nick(localpart)
    let nicks =
      recover val [wanted; wanted + "_"; wanted + "__"] end

    match \exhaustive\ _Connect(_env, network, link where nicks' = nicks)
    | let opened: irc.IRC =>
      _links(key) = link
      // The room before the connection, so a line arriving the instant
      // after registration has somewhere to go.
      link .> carries(room) .> connect(opened, receiver)
    | let e: StartupError =>
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

  fun _key(user_id: String, network: String, channel: String): String =>
    user_id + " " + network + " " + channel

primitive _Localpart
  """
  The local part of a Matrix user id, which is what a nickname is made
  from.
  """
  fun apply(user_id: String): String =>
    let colon =
      try
        user_id.find(":")?
      else
        return user_id
      end
    user_id.substring(1, colon)
