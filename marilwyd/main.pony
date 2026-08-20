use "files"
use "ssl/net"
use hobby = "hobby"
use irc = "irc"
use lori = "lori"
use stallion = "stallion"

primitive MaxRequestBody
  """
  The largest request body marilwyd's transport will accept at all.

  The ceiling every per-endpoint limit sits under. A limit above this one
  cannot fire: the body is refused by stallion before routing, as a
  bodiless `413` with no `errcode`, which is the unreadable answer a typed
  per-endpoint refusal exists to give instead.

  Named rather than written into `ServerLimits`, so that a limit somewhere
  else can be read against it.
  """
  fun apply(): USize => 65_536

primitive ServerLimits
  """
  The parser limits marilwyd runs under, stated rather than inherited.

  Public so the test harness boots the same server the binary does: a
  limit the suite cannot reach is a limit the suite cannot check.

  Only `max_body_size` differs from the defaults, at `MaxRequestBody()`
  against 1 MB. Every body marilwyd reads is a small JSON document, and a
  held `/sync` pins its request body for the whole wait, so the limit
  bounds resident memory and not just peak parse cost.

  A body over the limit is refused by stallion's parser, before routing, as
  a bodiless `413` carrying no `errcode`. That is the same unreadable
  answer the four-method catch-all exists to prevent, so lowering the limit
  makes it reachable sooner rather than later; 64 kB is chosen to sit above
  every body marilwyd reads today while bounding the login parser's
  allocation, which `SECURITY.md` measures. Every per-endpoint limit sits
  under it, because one above it can never fire — `MaxKeysBody` and
  `MaxToDeviceBody` both did, at two and four times the cap. Media upload
  will need this revisited, and Matrix's own event ceiling is 65,536
  bytes, so there is no headroom above a single maximal event.

  The host and port here are ignored by hobby — it binds from its own
  parameters — and are passed as the real ones so this cannot be misread
  as a second, conflicting address.
  """
  fun apply(host: String, port: String): stallion.ServerConfig =>
    stallion.ServerConfig(
      host,
      port
      where max_body_size' = MaxRequestBody())

actor Main is (hobby.ServerNotify & DeclaredChannelReceiver)
  """
  Startup, and the only place marilwyd writes to stdout or stderr.
  """
  let _env: Env

  new create(env: Env) =>
    _env = env

    let config =
      match \exhaustive\ Configure(env.args, FileAuth(env.root))
      | let c: Config => c
      | let h: HelpRequested =>
        env.out.print(h.text)
        return
      | let hp: HashPasswordRequested =>
        HashPassword(env, hp.localpart)
        return
      | let e: StartupError =>
        env.err.print("marilwyd: " + e.message)
        env.exitcode(1)
        return
      end

    // Printed here, beside the inputs that produced it, rather than from
    // `listening`. What clients are told to connect to and where the socket
    // actually is come from different flags; only the deployment knows
    // whether they agree, and nothing at startup can check it. Printing in
    // `create` also means a failed bind still shows what would have been
    // advertised, and keeps `_env` as this actor's only field.
    env.out.print(
      "marilwyd: clients are told to use " + config.homeserver.base_url())

    let log = if config.log_requests then env.out else None end

    // Minted here, where a CSPRNG failure can still stop the process: an
    // actor constructor cannot report one.
    let epoch =
      match MakeStreamEpoch()
      | let e: StreamEpoch => e
      else
        env.err.print("marilwyd: " + NoSecureRandom.string())
        env.exitcode(1)
        return
      end

    let rooms = RoomDirectory(config.homeserver)
    // The mapping is only meaningful with a bridge configured; without one
    // no link is ever opened, so what it holds does not matter.
    let links =
      LinkDirectory(
        env,
        config.homeserver,
        match config.bridges
        | let bridges: Bridges => bridges.mapping
        else
          NameMapping("{localpart}", "{nick}")
        end)

    // Declaring makes no room. A channel is something a person can get a
    // room for, and each person gets their own the first time they enter
    // — so what happens here is that the alias becomes enterable, and
    // nothing else.
    match config.bridges
    | let bridges: Bridges =>
      for network in bridges.networks.values() do
        for channel in network.channels.values() do
          rooms.declare(channel, network, this)
        end
      end
    end

    match \exhaustive\
      Routes(config, SessionRegistry(epoch), rooms, links, epoch, log)
    | let built: hobby.BuiltApplication =>
      hobby.Server(
        lori.TCPListenAuth(env.root),
        built,
        this
        where host = config.bind_host, port = config.bind_port,
              config = ServerLimits(config.bind_host, config.bind_port))
    | let e: hobby.ConfigError =>
      env.err.print("marilwyd: route table rejected: " + e.message)
      env.exitcode(1)
    end

  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    """
    Printed so an operator can see what was declared and under what name.

    No room id, because there is no room: a bridged channel is something
    people get their own room for, and the alias is the handle they use.
    """
    _env.out.print(
      "marilwyd: " + channel.channel + " is " + channel.alias.string())

  be declaration_refused(channel: String) =>
    """
    A declared channel could not be recorded, which is a configuration
    marilwyd cannot honour.

    `ReadBridges` rejects a repeated alias across the whole file, so this
    is only reachable if a channel's alias collides with something else in
    the directory — nothing at startup, today. It is still answered
    rather than assumed impossible, because the check it duplicates lives
    in another file.

    `exitcode` records a status and stops nothing: a bound listener goes
    on serving. Refusing to bind at all is what the other startup failures
    do, and this one arrives too late for that, so it says plainly that
    the channel is missing rather than implying the process is going down.
    """
    _env.err.print(
      "marilwyd: " + channel + " was not declared; its alias is already in"
        + " use, so that channel is not bridged and the rest of this"
        + " server is running without it")
    _env.exitcode(1)

  be listening(server: hobby.Server, host: String, service: String) =>
    // `host` is hobby's `local_address().name()`, which resolves rather than
    // echoing `--bind-host`: with `--bind-host 0.0.0.0` this reports
    // 127.0.0.1 while the socket is on 0.0.0.0. The port is trustworthy, and
    // is the only place `--bind-port 0` reports the one it actually got.
    _env.out.print("marilwyd: listening on " + host + ":" + service)

  be listen_failed(server: hobby.Server, reason: String) =>
    // Not optional. `hobby.ServerNotify`'s behaviours all have no-op default
    // bodies, and `hobby.Server`'s constructor returns an actor whether or
    // not the bind succeeded — so a `Main` implementing only `listening`
    // would bind nothing, print nothing, and exit 0.
    _env.err.print("marilwyd: " + reason)
    _env.exitcode(1)
