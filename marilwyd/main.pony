use "files"
use hobby = "hobby"
use lori = "lori"
use stallion = "stallion"

primitive _ServerLimits
  """
  The parser limits marilwyd runs under, stated rather than inherited.

  Only `max_body_size` differs from the defaults, at 64 kB against 1 MB.
  Every body marilwyd reads is a small JSON document — the largest is a
  login — and the ones it does not read are on paths that answer
  `M_UNRECOGNIZED` anyway.

  1 MB was already reachable without a token, through `/login`. What
  changed with `/sync` is that it became sustainable: a held request keeps
  its connection in-flight for up to `MaxSyncWait()`, and requests
  pipelined behind it are parsed and buffered rather than answered, so the
  per-connection ceiling stops being a per-request one.

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
              config = _ServerLimits(config.bind_host, config.bind_port))
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
