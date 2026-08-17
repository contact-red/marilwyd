use "files"
use hobby = "hobby"
use lori = "lori"
use stallion = "stallion"

primitive ServerLimits
  """
  The parser limits marilwyd runs under, stated rather than inherited.

  Public so the test harness boots the same server the binary does: a
  limit the suite cannot reach is a limit the suite cannot check.

  Only `max_body_size` differs from the defaults, at 64 kB against 1 MB.
  Every body marilwyd reads is a small JSON document — the largest is a
  login — and a held `/sync` pins its request body for the whole wait, so
  the limit bounds resident memory and not just peak parse cost.

  A body over the limit is refused by stallion's parser, before routing, as
  a bodiless `413` carrying no `errcode`. That is the same unreadable
  answer the four-method catch-all exists to prevent, so lowering the limit
  makes it reachable sooner rather than later; 64 kB is chosen to sit above
  every body marilwyd reads today while bounding the login parser's
  allocation, which `SECURITY.md` measures. Media upload will need this
  revisited, and Matrix's own event ceiling is 65,536 bytes, so there is no
  headroom above a single maximal event.

  The host and port here are ignored by hobby — it binds from its own
  parameters — and are passed as the real ones so this cannot be misread
  as a second, conflicting address.
  """
  fun apply(host: String, port: String): stallion.ServerConfig =>
    stallion.ServerConfig(host, port where max_body_size' = 65_536)

actor Main is hobby.ServerNotify
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

    match \exhaustive\ Routes(config, SessionRegistry, log)
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
