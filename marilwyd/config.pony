use "cli"
use "files"

class val Config
  """
  Everything marilwyd needs to run, after every input has been validated.

  A `Config` can only come from `Configure`, so holding one means the checks
  in `Configure` passed.
  """
  let homeserver: Homeserver
  let asset_root: FilePath
  let bundles_root: FilePath
  let credentials: Credentials
  let bind_host: String
  let bind_port: String
  let log_requests: Bool
  let bridges: (Bridges | None)

  new val _create(
    homeserver': Homeserver,
    asset_root': FilePath,
    bundles_root': FilePath,
    credentials': Credentials,
    bind_host': String,
    bind_port': String,
    log_requests': Bool,
    bridges': (Bridges | None))
  =>
    homeserver = homeserver'
    asset_root = asset_root'
    bundles_root = bundles_root'
    credentials = credentials'
    bind_host = bind_host'
    bind_port = bind_port'
    log_requests = log_requests'
    bridges = bridges'

class val StartupError
  """
  A startup input marilwyd refused.

  `cause` names the check that failed and is stable across message rewording;
  `message` is for the operator and is not. Both are `String`, which is a
  deliberate trade: a union of cause primitives would be type-safe but is the
  error hierarchy this design does not need, and a transposed pair here both
  prints visibly wrong and fails the `cause` assertion the field exists for.
  """
  let cause: String
  let message: String

  new val create(cause': String, message': String) =>
    cause = cause'
    message = message'

class val HelpRequested
  """
  The operator asked for usage rather than a running server.
  """
  let text: String

  new val create(text': String) =>
    text = text'

class val HashPasswordRequested
  """
  The operator asked for a credentials entry rather than a running server.
  """
  let localpart: String

  new val create(localpart': String) =>
    localpart = localpart'

primitive Configure
  """
  Turns a command line into a `Config`, or explains why it cannot.

  Every check that can be made before the listener opens is made here, so
  everything downstream can trust its configuration.
  """
  fun apply(args: Array[String] val, auth: FileAuth)
    : (Config | HelpRequested | HashPasswordRequested | StartupError)
  =>
    """
    Validate a command line, or say which input was refused.
    """
    let spec =
      try
        let serve =
          CommandSpec.leaf(
            "serve",
            "Serve Element and the Matrix Client-Server API.",
            [ OptionSpec.string(
                "server-name",
                "Matrix server name, hostname[:port]. Everything clients are"
                  + " told about this server is derived from it.")
              OptionSpec.string(
                "asset-root",
                "Directory holding the unpacked Element build. Every byte"
                  + " under it is served unauthenticated.")
              OptionSpec.string(
                "credentials",
                "JSON file of password hashes, one entry per local user."
                  + " Generate entries with 'marilwyd hash-password'.")
              OptionSpec.string(
                "bridges",
                "YAML file of IRC bridges. Each declares a channel, the"
                  + " Matrix room it is, and how a name on one side is"
                  + " spelled on the other. Omitted, marilwyd bridges"
                  + " nothing."
                where default' = "")
              OptionSpec.string(
                "scheme",
                "Scheme for the advertised base_url"
                where default' = "http")
              OptionSpec.string(
                "bind-host",
                "Address to listen on"
                where default' = "127.0.0.1")
              OptionSpec.bool(
                "log-requests",
                "Print every request and response to stdout. For debugging;"
                  + " logs the path and never the query string."
                where default' = false)
              OptionSpec.i64(
                "bind-port",
                "Port to listen on. Default: the port in --server-name, or"
                  + " 8008 if it has none."
                where default' = -1)
            ])?
        let hash =
          CommandSpec.leaf(
            "hash-password",
            "Read a password and print a credentials entry for it.",
            Array[OptionSpec],
            [ ArgSpec.string("localpart", "The local part of the user ID") ])?
        let s =
          CommandSpec.parent(
            "marilwyd",
            "A very small Matrix homeserver that serves its own Element"
              + " client.",
            Array[OptionSpec],
            [ serve; hash ])?
        s .> add_help()?
        s
      else
        return StartupError("usage", "internal: bad command spec")
      end

    let cmd =
      match \exhaustive\ CommandParser(spec).parse(args)
      | let c: Command => c
      | let h: CommandHelp => return HelpRequested(h.help_string())
      | let e: SyntaxError =>
        // marilwyd took its flags directly before `hash-password` existed,
        // so a command line written against the old shape fails here with a
        // message about an unknown option and no hint that a subcommand is
        // now required.
        return StartupError(
          "usage",
          e.string() + "\nmarilwyd takes a subcommand: try 'marilwyd serve"
            + " --server-name … --asset-root … --credentials …', 'marilwyd"
            + " hash-password <localpart>', or 'marilwyd --help'.")
      end

    if cmd.spec().name() == "hash-password" then
      let localpart = cmd.arg("localpart").string()
      match Localpart.check(localpart)
      | let e: String => return StartupError("localpart", e)
      end
      return HashPasswordRequested(localpart)
    end

    let hs =
      match \exhaustive\
        match cmd.option("scheme").string()
        | "http" => MakeHomeserver.http(cmd.option("server-name").string())
        | "https" => MakeHomeserver.https(cmd.option("server-name").string())
        else
          return StartupError("scheme", "--scheme must be 'http' or 'https'")
        end
      | let h: Homeserver => h
      | let e: StartupError => return e
      end

    let bind_port =
      match \exhaustive\ _BindPort(cmd.option("bind-port").i64(), hs.port())
      | let p: String => p
      | let e: StartupError => return e
      end

    match \exhaustive\ _AssetRoot(cmd.option("asset-root").string(), auth)
    | (let root: FilePath, let bundles: FilePath) =>
      let credentials =
        match \exhaustive\
          _ReadCredentialsFile(cmd.option("credentials").string(), auth, root)
        | let c: Credentials => c
        | let e: StartupError => return e
        end
      let bridges =
        match \exhaustive\
          _ReadBridgesFile(
            cmd.option("bridges").string(), auth, root, hs.server_name)
        | let b: Bridges => b
        | None => None
        | let e: StartupError => return e
        end
      // Named arguments: `bind_host'` and `bind_port'` are adjacent strings
      // in the constructor, and this is the one place they are supplied.
      Config._create(
        hs,
        root,
        bundles,
        credentials
        where bind_host' = cmd.option("bind-host").string(),
              bind_port' = bind_port,
              log_requests' = cmd.option("log-requests").bool(),
              bridges' = bridges)
    | let e: StartupError => e
    end

primitive _ReadCredentialsFile
  fun apply(path: String, auth: FileAuth, asset_root: FilePath)
    : (Credentials | StartupError)
  =>
    """
    Resolve the credentials path with read-only capabilities and parse it.

    Refuses a file that sits inside the asset root, and one that is readable
    by anyone but its owner.
    """
    let caps =
      recover val
        FileCaps .> set(FileLookup) .> set(FileRead) .> set(FileStat)
      end

    let resolved =
      try
        FilePath(auth, path, caps).canonical()?
      else
        return StartupError(
          "credentials-missing",
          "--credentials " + path + " does not exist")
      end

    // Everything under the asset root is served unauthenticated, so a
    // credentials file placed there publishes every hash to anyone who can
    // reach the socket.
    if resolved.path.at(asset_root.path, 0) then
      return StartupError(
        "credentials-in-asset-root",
        "--credentials " + resolved.path + " is inside --asset-root "
          + asset_root.path + ", where every file is served to anyone who"
          + " can reach this socket")
    end

    // The file is the offline-attack surface for every account.
    try
      let mode = FileInfo(resolved)?.mode
      if mode.group_read or mode.any_read then
        return StartupError(
          "credentials-permissions",
          "--credentials " + resolved.path + " is readable by users other"
            + " than its owner; chmod 600 it")
      end
    end

    ReadCredentials(resolved)

primitive _ReadBridgesFile
  """
  Resolve and parse the bridges file, if one was named.

  The same posture as the credentials file, and for a related reason: this
  one holds no hashes, but it holds declared room ids, and a room id is the
  entire access control on a room. A file of them inside the asset root
  would publish them to anyone who can reach the socket.
  """
  fun apply(
    path: String,
    auth: FileAuth,
    asset_root: FilePath,
    server_name: String)
    : (Bridges | None | StartupError)
  =>
    if path.size() == 0 then
      return None
    end

    let caps =
      recover val
        FileCaps .> set(FileLookup) .> set(FileRead) .> set(FileStat)
      end

    let resolved =
      try
        FilePath(auth, path, caps).canonical()?
      else
        return StartupError(
          "bridges-missing", "--bridges " + path + " does not exist")
      end

    if resolved.path.at(asset_root.path, 0) then
      return StartupError(
        "bridges-in-asset-root",
        "--bridges " + resolved.path + " is inside --asset-root "
          + asset_root.path + ", where every file is served to anyone who"
          + " can reach this socket")
    end

    try
      let mode = FileInfo(resolved)?.mode
      if mode.group_read or mode.any_read then
        return StartupError(
          "bridges-permissions",
          "--bridges " + resolved.path + " is readable by users other than"
            + " its owner; chmod 600 it")
      end
    end

    ReadBridges(resolved, server_name)

primitive _BindPort
  """
  Resolves the one bind port from its two possible sources.

  `--bind-port` wins when supplied. `-1` is the "not supplied" sentinel the
  `cli` package forces on us: `Command` cannot report whether an option came
  from the command line or from its default, and `0` is a port a caller may
  legitimately ask for. Otherwise the port inside `server_name`. Otherwise
  8008.

  A *derived* port below 1024 is refused. `--server-name contact.red:443` is
  legal Matrix, and without this an identity flag would silently become a
  privileged bind, surfacing only as hobby's opaque "failed to start
  listener". An explicit `--bind-port 443` is honoured — that operator asked
  for it.
  """
  fun apply(explicit: I64, advertised: (String | None))
    : (String | StartupError)
  =>
    if explicit != -1 then
      if (explicit < 0) or (explicit > 65535) then
        return StartupError(
          "bind-port",
          "--bind-port must be 0-65535, not " + explicit.string())
      end
      return explicit.string()
    end

    match advertised
    | let p: String =>
      let n = try p.usize()? else 0 end
      if n < 1024 then
        return StartupError(
          "bind-port",
          "--server-name names port " + p + ", which needs privileges to"
            + " bind. Pass --bind-port to say where to listen instead.")
      end
      p
    else
      "8008"
    end

primitive _AssetRoot
  """
  Canonicalises `--asset-root` and checks the two things the route table needs
  to find inside it. Returns `(asset_root, bundles_root)`.

  Canonicalising resolves the root itself. `FilePath.from` keeps requests
  within it, but containment is textual and does not follow symlinks, so a
  symlink under the root still leads wherever it points — see SECURITY.md.
  """
  fun apply(path: String, auth: FileAuth)
    : ((FilePath, FilePath) | StartupError)
  =>
    let caps =
      recover val
        FileCaps .> set(FileLookup) .> set(FileRead) .> set(FileStat)
      end

    let root =
      try
        FilePath(auth, path, caps).canonical()?
      else
        return StartupError(
          "asset-root-missing",
          "--asset-root " + path + " does not exist")
      end

    try
      if not FileInfo(root)?.directory then error end
    else
      return StartupError(
        "asset-root-not-dir",
        "--asset-root " + path + " is not a directory")
    end

    try
      let index = FilePath.from(root, "index.html")?
      if not FileInfo(index)?.file then error end
    else
      return StartupError(
        "asset-root-no-index",
        "--asset-root " + path + " has no index.html; is that an unpacked"
          + " Element build?")
    end

    // Checked here, and never defaulted to `root`: the bundles mount carries
    // a one-year `immutable`, and pointing it at the whole tree would put
    // that on the un-hashed shell.
    let bundles =
      try
        let b = FilePath.from(root, "bundles")?
        if not FileInfo(b)?.directory then error end
        b
      else
        return StartupError(
          "asset-root-no-bundles",
          "--asset-root " + path + " has no bundles/ directory; is that an"
            + " unpacked Element build?")
      end

    (root, bundles)
