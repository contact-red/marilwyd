use "files"
use hobby = "hobby"
use lori = "lori"

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

    match \exhaustive\ Routes(config)
    | let built: hobby.BuiltApplication =>
      hobby.Server(
        lori.TCPListenAuth(env.root),
        built,
        this
        where host = config.bind_host, port = config.bind_port)
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
