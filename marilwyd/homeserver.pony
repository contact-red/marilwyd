class val Homeserver
  """
  The identity of the Matrix homeserver this process serves.

  `server_name` is the Matrix `hostname[:port]` and the operator's only
  identity input. Everything a client is told about this server is computed
  from it, so nothing can disagree with it.

  Build one with `MakeHomeserver`.
  """
  let server_name: String
  let _scheme: String

  new val _create(server_name': String, scheme': String) =>
    server_name = server_name'
    _scheme = scheme'

  fun base_url(): String =>
    """
    The `m.homeserver` base URL advertised to clients.
    """
    _scheme + "://" + server_name

  fun host(): String =>
    """
    `server_name` with any port removed. IPv6 literals keep their brackets.
    """
    match _colon()
    | let i: ISize => server_name.trim(0, i.usize())
    else server_name
    end

  fun port(): (String | None) =>
    """
    The port inside `server_name`, if it has one.
    """
    match _colon()
    | let i: ISize => server_name.trim(i.usize() + 1)
    else None
    end

  fun _colon(): (ISize | None) =>
    // The port separator is the last ':', and only when it follows the last
    // ']' — so the colons inside an IPv6 literal are not mistaken for one —
    // and everything after it is a digit.
    let c = try server_name.rfind(":")? else return None end
    let b = try server_name.rfind("]")? else ISize(-1) end
    if c < b then
      return None
    end
    let rest = server_name.trim(c.usize() + 1)
    if rest.size() == 0 then
      return None
    end
    for ch in rest.values() do
      if (ch < '0') or (ch > '9') then
        return None
      end
    end
    c

primitive MakeHomeserver
  """
  The only way to build a `Homeserver`. Checks the operator's `--server-name`
  and pairs it with the scheme marilwyd advertises.
  """
  fun https(server_name: String): (Homeserver | StartupError) =>
    _make(server_name, "https")

  fun http(server_name: String): (Homeserver | StartupError) =>
    _make(server_name, "http")

  fun _make(server_name: String, scheme: String)
    : (Homeserver | StartupError)
  =>
    if server_name.size() == 0 then
      return StartupError("server-name", "--server-name must not be empty")
    end

    if server_name.contains("://") then
      return StartupError(
        "server-name",
        "--server-name is a hostname[:port], not a URL: " + server_name)
    end

    if server_name.contains("/") then
      return StartupError(
        "server-name",
        "--server-name must not contain '/': " + server_name)
    end

    for ch in server_name.values() do
      if (ch <= ' ') or (ch == 0x7f) then
        return StartupError(
          "server-name",
          "--server-name must not contain whitespace or control characters: '"
            + server_name + "'")
      end
    end

    // A trailing ':' group that is not a valid port would otherwise be
    // advertised verbatim — `localhost:http` becomes `http://localhost:http`
    // — while the bind port silently falls back to the default.
    let candidate = Homeserver._create(server_name, scheme)
    try
      let c = server_name.rfind(":")?
      let b = try server_name.rfind("]")? else ISize(-1) end
      if c > b then
        match candidate.port()
        | let p: String =>
          let n = try p.usize()? else 0 end
          if (n == 0) or (n > 65535) then
            return StartupError(
              "server-name",
              "--server-name port must be 1-65535: " + server_name)
          end
        else
          return StartupError(
            "server-name",
            "--server-name has a ':' but no numeric port: " + server_name)
        end
      end
    end

    if candidate.host().size() == 0 then
      return StartupError(
        "server-name",
        "--server-name has no host part: " + server_name)
    end

    candidate
