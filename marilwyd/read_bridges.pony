use "files"
use irc = "irc"
use "yaml"

primitive ReadBridges
  """
  Read and validate the bridge configuration.

  Everything a bridge needs that marilwyd cannot invent: which server,
  which channels, and what a name on one side is called on the other. It
  holds no secret today — the test network wants no password — but it does
  hold declared room ids, and a room id is the entire access control on a
  room. It is read under the credentials file's posture for that reason.

  As with the credentials file, parsing and shape are the `yaml` package's
  and what a value has to *mean* is marilwyd's. A channel with an alias
  that could never be one is refused here, at startup, rather than
  discovered when somebody tries to join it.
  """
  fun apply(path: FilePath, server_name: String)
    : (Bridges | StartupError)
  =>
    """
    Parse the file, or name the channel that stopped it.
    """
    let text =
      match OpenFile(path)
      | let f: File =>
        let content = f.read_string(f.size())
        f.dispose()
        consume content
      else
        return StartupError(
          "bridges-unreadable", path.path + " cannot be read")
      end

    let raw =
      match \exhaustive\ YamlLoad[_RawBridges](
        consume text,
        {(c) =>
          _RawBridges(
            c("networks").sequence[_RawNetwork](_RawNetworkOf),
            c("mapping")("to_irc").text(),
            c("mapping")("to_matrix").text())
        }
        where max_depth = 12, max_nodes = 100_000)
      | let b: _RawBridges => b
      | let f: YamlFailure =>
        return StartupError("bridges-malformed", path.path + ": " + f.string())
      end

    let networks = recover trn Array[BridgedNetwork] end
    let seen_alias = recover trn Array[String] end

    for (i, network) in raw.networks.pairs() do
      let where': String = path.path + " networks[" + i.string() + "]"

      match Localpart.check(network.name)
      | let why: String =>
        // The network name goes into every ghost's user id, so it has to
        // be usable in one. Refusing here beats minting user ids nothing
        // can address.
        return StartupError("bridge-network-name", where' + ": " + why)
      end

      if network.host.size() == 0 then
        return StartupError("bridge-host", where' + ": a network needs a host")
      end

      if (network.port < 1) or (network.port > 65535) then
        return StartupError(
          "bridge-port",
          where' + ": a port is 1-65535, not " + network.port.string())
      end

      if network.nicks.size() == 0 then
        return StartupError(
          "bridge-nicks", where' + ": a network needs at least one nick")
      end

      let channels = recover trn Array[BridgedChannel] end
      for (j, channel) in network.channels.pairs() do
        let at: String = where' + " channels[" + j.string() + "]"

        // Checked against the library that has to send it, not against a
        // hash somewhere in the string. A name `irc.Channels` refuses
        // means no JOIN is ever sent and every join of that room waits
        // out its deadline instead — a silent runtime loss where this is
        // a named refusal at startup.
        match irc.Channels(channel.channel)
        | let _: irc.InvalidName =>
          return StartupError(
            "bridge-channel",
            at + ": not a usable IRC channel name")
        end

        // The alias defaults to the room's name, which is what an operator
        // means by naming the room at all. Declared separately when the
        // display name is not something a person could type.
        let wanted =
          if channel.alias.size() > 0 then
            channel.alias
          else
            channel.room_name
          end

        let alias =
          match \exhaustive\ RoomAliases.make(wanted, server_name)
          | let a: RoomAlias => a
          | let why: InvalidAlias =>
            return StartupError("bridge-alias", at + ": " + why.string())
          end

        let text': String = alias.string()
        for already in seen_alias.values() do
          if already == text' then
            return StartupError(
              "bridge-alias-duplicate",
              at + ": two channels claim " + text')
          end
        end
        seen_alias.push(text')

        channels.push(
          BridgedChannel(channel.channel, channel.room_name, alias))
      end

      networks.push(
        BridgedNetwork(
          network.name,
          network.host,
          network.port.string(),
          network.tls,
          network.nicks,
          consume channels))
    end

    Bridges(
      consume networks, NameMapping(raw.to_irc, raw.to_matrix))

class val _RawBridges
  let networks: Array[_RawNetwork] val
  let to_irc: String
  let to_matrix: String

  new val create(
    networks': Array[_RawNetwork] val,
    to_irc': String,
    to_matrix': String)
  =>
    networks = networks'
    to_irc = to_irc'
    to_matrix = to_matrix'

class val _RawNetwork
  let name: String
  let host: String
  let port: I64
  let tls: Bool
  let nicks: Array[String] val
  let channels: Array[_RawChannel] val

  new val create(
    name': String,
    host': String,
    port': I64,
    tls': Bool,
    nicks': Array[String] val,
    channels': Array[_RawChannel] val)
  =>
    name = name'
    host = host'
    port = port'
    tls = tls'
    nicks = nicks'
    channels = channels'

class val _RawChannel
  let channel: String
  let room_name: String
  let alias: String

  new val create(
    channel': String,
    room_name': String,
    alias': String)
  =>
    channel = channel'
    room_name = room_name'
    alias = alias'

primitive _RawNetworkOf
  fun apply(c: YamlView ref): _RawNetwork =>
    _RawNetwork(
      c("name").text(),
      c("host").text(),
      c("port").int[I64](),
      c("tls").bool(),
      c("nicks").sequence[String]({(n) => n.text() }),
      c("channels").sequence[_RawChannel](_RawChannelOf))

primitive _RawChannelOf
  fun apply(c: YamlView ref): _RawChannel =>
    _RawChannel(
      c("channel").text(),
      c("room_name").text(),
      c("alias").optional().text_or_else(""))
