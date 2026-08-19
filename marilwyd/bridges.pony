class val BridgedChannel
  """
  One IRC channel and the Matrix room it is.

  `alias` is the whole of how a channel is addressed, and there is no room
  id to declare beside it: every person who enters a channel gets their own
  room, so there is no single id an operator could pin. The alias is what
  survives a restart, and it is what a person types.
  """
  let channel: String
  let room_name: String
  let alias: RoomAlias

  new val create(
    channel': String,
    room_name': String,
    alias': RoomAlias)
  =>
    channel = channel'
    room_name = room_name'
    alias = alias'

class val BridgedNetwork
  """
  One IRC server marilwyd connects to, and the channels it bridges there.

  `name` is marilwyd's own label. It appears in every ghost user id, so two
  networks that both have an `alice` produce two Matrix users rather than
  one shared ghost — which would let a stranger on one network speak as
  somebody's friend on the other.
  """
  let name: String
  let host: String
  let service: String
  let tls: Bool
  let nicks: Array[String] val
  let channels: Array[BridgedChannel] val

  new val create(
    name': String,
    host': String,
    service': String,
    tls': Bool,
    nicks': Array[String] val,
    channels': Array[BridgedChannel] val)
  =>
    name = name'
    host = host'
    service = service'
    tls = tls'
    nicks = nicks'
    channels = channels'

class val NameMapping
  """
  How a name on one side of a bridge is spelled on the other.

  Two templates rather than one reversible rule, because the two directions
  are not inverses. A Matrix user's IRC nick is decoration — it marks them
  as coming from somewhere else. An IRC user's Matrix id is an identity
  this server mints and must never collide with a real account's.
  """
  let to_irc: String
  let to_matrix: String

  new val create(to_irc': String, to_matrix': String) =>
    to_irc = to_irc'
    to_matrix = to_matrix'

  fun val irc_nick(localpart: String): String =>
    """
    What a Matrix user is called on IRC.
    """
    _Substituted(to_irc, "localpart", localpart)

  fun val matrix_localpart(network: String, nick: String): String =>
    """
    What an IRC user is called on Matrix, before it is checked.

    The nick is not casefolded here — that needs the network's own rules,
    which only a live connection knows — so the caller does it and hands in
    a nick already folded.
    """
    _Substituted(
      _Substituted(to_matrix, "network", network), "nick", nick)

class val Bridges
  """
  Every bridge marilwyd was configured with.
  """
  let networks: Array[BridgedNetwork] val
  let mapping: NameMapping

  new val create(
    networks': Array[BridgedNetwork] val,
    mapping': NameMapping)
  =>
    networks = networks'
    mapping = mapping'

primitive _Substituted
  """
  Replace every `{name}` in a template.

  A template rather than a format string: an operator writing
  `{localpart}[marilwyd]` should not have to escape the brackets that are
  the point of it.
  """
  fun apply(template: String, name: String, value: String): String =>
    let token: String = "{" + name + "}"
    let out = String(template.size() + value.size())
    var from: ISize = 0
    var done = false
    while not done do
      match try template.find(token, from)? else None end
      | let at: ISize =>
        out.append(template.substring(from, at))
        out.append(value)
        from = at + token.size().isize()
      else
        out.append(template.substring(from))
        done = true
      end
    end
    out.clone()
