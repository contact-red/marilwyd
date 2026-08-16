use "pony_test"
use "files"
use "json"
use "../marilwyd"

// ------------------------------------------------------------- route table
class \nodoc\ iso _TestRootRedirectsIntoElement is UnitTest
  fun name(): String => "routes/GET / redirects into the element subpath"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 302 Found\r\n"), r)
        // Lowercase: stallion's `Headers.set` lowercases every name.
        h.assert_true(r.contains("\r\nlocation: /element/index.html\r\n"), r)
      } val)

class \nodoc\ iso _TestElementMountRootRedirects is UnitTest
  fun name(): String => "routes/GET /element answers its own mount point"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 302 Found\r\n"), r)
        h.assert_true(r.contains("\r\nlocation: /element/index.html\r\n"), r)
      } val)

class \nodoc\ iso _TestElementIndexServes is UnitTest
  """
  Canary for the `*filepath` wildcard name on the shell mount. A wrong name
  compiles and builds, then returns 500 at request time.
  """
  fun name(): String => "routes/GET /element/index.html is 200"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/index.html"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("fixture"), r)
      } val)

class \nodoc\ iso _TestBundlesAreImmutable is UnitTest
  """
  Canary for the `*filepath` wildcard name on the bundles mount, and for that
  mount being rooted at `<asset_root>/bundles` rather than `<asset_root>`.
  """
  fun name(): String => "routes/bundles are served immutable"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/bundles/app.js"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(
          r.contains("\r\ncache-control: public, max-age=31536000, immutable"),
          r)
      } val)

class \nodoc\ iso _TestShellIsNoCache is UnitTest
  """
  `no-cache`, never an absent header: with no `Cache-Control` a browser
  invents a freshness lifetime from the file's age, and an Element upgrade
  goes unseen by a returning user.
  """
  fun name(): String => "routes/the element shell is no-cache"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/index.html"),
      {(r) =>
        h.assert_true(r.contains("\r\ncache-control: no-cache\r\n"), r)
      } val)

class \nodoc\ iso _TestGeneratedConfigCarriesBaseURL is UnitTest
  fun name(): String => "routes/generated config.json carries base_url"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/config.json"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("http://example.test"), r)
      } val)

class \nodoc\ iso _TestUnrecognizedEndpointIsJSON is UnitTest
  """
  The status is 404 whether or not the catch-all is wired: without it the
  request falls through to the static handler and gets a plain-text 404. The
  parse is the test, not the status.
  """
  fun name(): String => "routes/unimplemented _matrix path is M_UNRECOGNIZED"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/capabilities"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)

class \nodoc\ iso _TestMatrixNamespaceRootIsJSON is UnitTest
  fun name(): String => "routes/GET /_matrix answers in Matrix's vocabulary"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)

class \nodoc\ iso _TestLoginFlowsAreServed is UnitTest
  fun name(): String => "routes/GET login advertises the password flow"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/login"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("m.login.password"), r)
      } val)

class \nodoc\ iso _TestLoginPostRefusesInMatrixVocabulary is UnitTest
  """
  Every refusal from this endpoint has to be a Matrix error. A 405 or a bare
  status carries no `errcode`, and matrix-js-sdk keys its error path on one,
  so the client throws instead of showing the person what went wrong.
  """
  fun name(): String => "routes/POST login refuses in Matrix's vocabulary"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_PARAM")
      } val)

primitive _AssertErrcode
  fun apply(h: TestHelper, response: String, expected: String) =>
    """
    Assert the response body parses as JSON and carries `expected`.
    """
    try
      let body = response.substring(response.find("\r\n\r\n")? + 4)
      match JsonParser.parse(consume body)
      | let o: JsonObject =>
        h.assert_eq[String](expected, o("errcode")? as String)
      | let e: JsonParseError =>
        h.fail("body is not JSON: " + response)
      else
        h.fail("body is not a JSON object: " + response)
      end
    else
      h.fail("no body, or errcode missing: " + response)
    end

// ---------------------------------------------------------------- identity
class \nodoc\ iso _TestServerNameRejectsURL is UnitTest
  fun name(): String => "identity/--server-name rejects a URL"

  fun apply(h: TestHelper) =>
    match \exhaustive\ MakeHomeserver.http("https://example.test")
    | let e: StartupError => h.assert_eq[String]("server-name", e.cause)
    | let hs: Homeserver => h.fail("accepted a URL as --server-name")
    end

class \nodoc\ iso _TestServerNameRejectsBadPort is UnitTest
  """
  Without this check `localhost:http` is advertised verbatim while the bind
  port silently falls back to the default.
  """
  fun name(): String => "identity/--server-name rejects a non-numeric port"

  fun apply(h: TestHelper) =>
    match \exhaustive\ MakeHomeserver.http("localhost:http")
    | let e: StartupError => h.assert_eq[String]("server-name", e.cause)
    | let hs: Homeserver => h.fail("accepted a non-numeric port")
    end

// --------------------------------------------------------------- bind port
//
// The resolver itself is package-private, so these go through `Configure`,
// which is the real path anyway. `Configure` resolves the bind port before it
// validates the asset root, so a rejection is reachable without a fixture.
class \nodoc\ iso _TestBindPortDerivedFromServerName is UnitTest
  fun name(): String => "bind-port/derives from the port in --server-name"

  fun apply(h: TestHelper) =>
    match \exhaustive\ _Configure(
      h, "localhost:8443", _Fixture(h), None, _CredentialsFixture(h))
    | let c: Config => h.assert_eq[String]("8443", c.bind_port)
    | let e: StartupError => h.fail(e.message)
    end

class \nodoc\ iso _TestBindPortRefusesPrivilegedDerived is UnitTest
  """
  `contact.red:443` is legal Matrix. Deriving a privileged bind from an
  identity flag would surface only as hobby's opaque listener failure.
  """
  fun name(): String => "bind-port/refuses a derived port below 1024"

  fun apply(h: TestHelper) =>
    match \exhaustive\ _Configure(h, "contact.red:443", "/nonexistent", None)
    | let c: Config => h.fail("derived a privileged port: " + c.bind_port)
    | let e: StartupError => h.assert_eq[String]("bind-port", e.cause)
    end

class \nodoc\ iso _TestBindPortExplicitOverrides is UnitTest
  fun name(): String =>
    "bind-port/an explicit --bind-port wins, even privileged"

  fun apply(h: TestHelper) =>
    match \exhaustive\ _Configure(
      h, "localhost:8448", _Fixture(h), "443", _CredentialsFixture(h))
    | let c: Config => h.assert_eq[String]("443", c.bind_port)
    | let e: StartupError => h.fail(e.message)
    end

primitive _Configure
  fun apply(
    h: TestHelper,
    server_name: String,
    asset_root: String,
    bind_port: (String | None),
    credentials: String = "build/test-credentials.json")
    : (Config | StartupError)
  =>
    """
    Run `Configure` with the two required flags, and optionally
    `--bind-port`.
    """
    let args =
      recover val
        let a =
          [ "marilwyd"; "serve"
            "--server-name"; server_name
            "--asset-root"; asset_root
            "--credentials"; credentials ]
        match bind_port
        | let p: String => a .> push("--bind-port") .> push(p)
        end
        a
      end

    match \exhaustive\ Configure(args, FileAuth(h.env.root))
    | let c: Config => c
    | let e: StartupError => e
    | let hr: HelpRequested => StartupError("help", "unexpected help request")
    | let hp: HashPasswordRequested =>
      StartupError("hash-password", "unexpected hash-password request")
    end
