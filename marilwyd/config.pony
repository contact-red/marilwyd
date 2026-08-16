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
  let bind_host: String
  let bind_port: String

  new val _create(
    homeserver': Homeserver,
    asset_root': FilePath,
    bundles_root': FilePath,
    bind_host': String,
    bind_port': String)
  =>
    homeserver = homeserver'
    asset_root = asset_root'
    bundles_root = bundles_root'
    bind_host = bind_host'
    bind_port = bind_port'

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

primitive Configure
  """
  Turns a command line into a `Config`, or explains why it cannot.

  Every check that can be made before the listener opens is made here, so
  everything downstream can trust its configuration.
  """
  fun apply(args: Array[String] val, auth: FileAuth)
    : (Config | HelpRequested | StartupError)
  =>
    """
    Validate a command line, or say which input was refused.
    """
    let spec =
      try
        let s =
          CommandSpec.leaf(
            "marilwyd",
            "A very small Matrix homeserver that serves its own Element"
              + " client.",
            [ OptionSpec.string(
                "server-name",
                "Matrix server name, hostname[:port]. Everything clients are"
                  + " told about this server is derived from it.")
              OptionSpec.string(
                "asset-root",
                "Directory holding the unpacked Element build. Every byte"
                  + " under it is served unauthenticated.")
              OptionSpec.string(
                "scheme",
                "Scheme for the advertised base_url"
                where default' = "http")
              OptionSpec.string(
                "bind-host",
                "Address to listen on"
                where default' = "127.0.0.1")
              OptionSpec.i64(
                "bind-port",
                "Port to listen on. Default: the port in --server-name, or"
                  + " 8008 if it has none."
                where default' = -1)
            ])?
        s .> add_help()?
        s
      else
        return StartupError("usage", "internal: bad command spec")
      end

    let cmd =
      match CommandParser(spec).parse(args)
      | let c: Command => c
      | let h: CommandHelp => return HelpRequested(h.help_string())
      | let e: SyntaxError => return StartupError("usage", e.string())
      end

    let hs =
      match
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
      match _BindPort(cmd.option("bind-port").i64(), hs.port())
      | let p: String => p
      | let e: StartupError => return e
      end

    match _AssetRoot(cmd.option("asset-root").string(), auth)
    | (let root: FilePath, let bundles: FilePath) =>
      // Named arguments: `bind_host'` and `bind_port'` are adjacent strings
      // in the constructor, and this is the one place they are supplied.
      Config._create(
        hs,
        root,
        bundles
        where bind_host' = cmd.option("bind-host").string(),
              bind_port' = bind_port)
    | let e: StartupError => e
    end

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
