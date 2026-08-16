use hobby = "hobby"
use stallion = "stallion"

primitive Routes
  """
  The whole server, in one table. Every row states its own full path.

  Registration order does not matter — hobby resolves a request by
  specificity, static beating parameter beating wildcard, structurally in a
  trie. The rows are grouped by namespace because that is how they read.

  Three rows are marked `hobby#1`. hobby's router does not consult a node's
  wildcard entries once the request's path segments are exhausted, so a
  wildcard mount cannot answer its own mount point. A companion route is
  needed wherever a declared namespace root must answer in that namespace's
  own vocabulary — `/`, `/element` and `/_matrix` — and nowhere else.
  `/element/bundles` also 404s plain-text, and no client asks for it.
  """
  fun apply(config: Config): hobby.BuildResult =>
    """
    Build the route table, or report the configuration error that stops it.
    """
    let hs = config.homeserver
    let element_config = _ServeJSON(ElementConfig(hs))
    let unrecognized =
      _ServeJSON(UnrecognizedRequest(), stallion.StatusNotFound)
    let to_element = _Redirect("/element/index.html")

    (hobby.Application
      // The origin root is marilwyd's, not Element's. Mounting Element here
      // would serve its `apple-app-site-association` and
      // `.well-known/assetlinks.json`, which delegate universal-link handling
      // and iOS keychain credential sharing for this domain to Element's
      // published mobile apps.
      .> get("/", to_element)                                      // hobby#1

      .> get("/element", to_element)                               // hobby#1
      .> get("/element/config.json", element_config)
      // Element probes this before `config.json`. The host is fixed at
      // startup from `--server-name`, so this only shadows when the browser
      // reaches marilwyd under that name; any other name 404s and Element
      // falls through to `config.json`, which is also correct.
      .> get("/element/config." + hs.host() + ".json", element_config)
      .> get(
        "/element/bundles/*filepath",
        hobby.ServeFiles(
          config.bundles_root
          where cache_control = "public, max-age=31536000, immutable"))
      // `no-cache`, never `None`. Omitting the header entirely lets the
      // browser invent a freshness lifetime from the file's age, and an
      // Element upgrade then goes unseen by a returning user.
      .> get(
        "/element/*filepath",
        hobby.ServeFiles(
          config.asset_root
          where cache_control = "no-cache"))

      .> get("/_matrix", unrecognized)                             // hobby#1
      .> get("/_matrix/client/versions", _ServeJSON(ClientVersions()))
      .> get("/_matrix/client/v3/login", _ServeJSON(LoginFlows()))
      .> post(
        "/_matrix/client/v3/login",
        _ServeJSON(LoginForbidden(), stallion.StatusForbidden))
      .> get("/_matrix/*endpoint", unrecognized)
    ).build()

class val _ServeJSON
  """
  Respond to every request with one JSON document, rendered once at startup.

  `no-store` because every document marilwyd generates is derived from its
  configuration; a copy cached in a browser would outlive a configuration
  change.
  """
  let _headers: stallion.Headers val
  let _body: String
  let _status: stallion.Status

  new val create(body: String, status: stallion.Status = stallion.StatusOK) =>
    _headers =
      recover val
        stallion.Headers
          .> set("Content-Type", "application/json")
          .> set("Cache-Control", "no-store")
      end
    _body = body
    _status = status

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    hobby.RequestHandler(consume ctx)
      .respond_with_headers(_status, _headers, _body)
    None

class val _Redirect
  """
  Respond to every request with a temporary redirect to a fixed location.

  Temporary rather than permanent: browsers cache a 301 hard, and this one
  marks a namespace boundary that may move.
  """
  let _headers: stallion.Headers val

  new val create(location: String) =>
    _headers =
      recover val
        stallion.Headers .> set("Location", location)
      end

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    hobby.RequestHandler(consume ctx)
      .respond_with_headers(stallion.StatusFound, _headers, "")
    None
