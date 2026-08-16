use "pony_test"
use "files"
use "../marilwyd"
use hobby = "hobby"
use lori = "lori"

actor Main is TestList
  new create(env: Env) =>
    PonyTest(env, this)

  fun tag tests(test: PonyTest) =>
    """
    Register every test in this package.
    """
    test(_TestRootRedirectsIntoElement)
    test(_TestElementMountRootRedirects)
    test(_TestElementIndexServes)
    test(_TestBundlesAreImmutable)
    test(_TestShellIsNoCache)
    test(_TestGeneratedConfigCarriesBaseURL)
    test(_TestUnrecognizedEndpointIsJSON)
    test(_TestMatrixNamespaceRootIsJSON)
    test(_TestLoginFlowsAreServed)
    test(_TestLoginPostIsForbidden)
    test(_TestServerNameRejectsURL)
    test(_TestServerNameRejectsBadPort)
    test(_TestBindPortDerivedFromServerName)
    test(_TestBindPortRefusesPrivilegedDerived)
    test(_TestBindPortExplicitOverrides)

// ---------------------------------------------------------------- harness
primitive _TestHost
  """
  hobby's own suite binds 127.0.0.2 on Linux to dodge a WSL2 issue in lori.
  """
  fun apply(): String =>
    ifdef linux then "127.0.0.2" else "localhost" end

actor _TestClient is (lori.TCPConnectionActor &
  lori.ClientLifecycleEventReceiver)
  """
  Sends one raw request and hands the whole raw response back.
  """
  var _conn: lori.TCPConnection = lori.TCPConnection.none()
  let _request: String
  let _server: hobby.Server tag
  let _check: {(String)} val
  var _response: String iso = recover iso String end

  new create(
    auth: lori.TCPConnectAuth,
    port: String,
    request: String,
    server: hobby.Server tag,
    check: {(String)} val)
  =>
    _request = request
    _server = server
    _check = check
    _conn = lori.TCPConnection.client(auth, _TestHost(), port, "", this, this)

  fun ref _connection(): lori.TCPConnection => _conn

  fun ref _on_connected() =>
    _conn.send(_request)

  fun ref _on_received(data: Array[U8] iso): lori.ReadAction =>
    _response.append(consume data)
    lori.KeepReading

  fun ref _on_closed() =>
    _check(_response.clone())
    _server.dispose()

  fun ref _on_connection_failure(reason: lori.ConnectionFailureReason) =>
    _check("")
    _server.dispose()

actor _TestNotify is hobby.ServerNotify
  let _run: {(String, hobby.Server tag)} val

  new create(run: {(String, hobby.Server tag)} val) =>
    _run = run

  be listening(server: hobby.Server, host: String, service: String) =>
    _run(service, server)

  be listen_failed(server: hobby.Server, reason: String) =>
    None

primitive _Serve
  """
  Boot marilwyd's real route table on an ephemeral port, send one raw request,
  hand the whole raw response to `check`, then shut the listener down.

  The whole response goes to the test, not a substring match: the route table
  is the thing most likely to be wrong, and several of its failure modes share
  a status code with success.
  """
  fun apply(h: TestHelper, request: String, check: {(String)} val) =>
    h.long_test(10_000_000_000)

    let auth = FileAuth(h.env.root)
    let root = _Fixture(h)

    let config =
      match Configure(
        recover val
          [ "marilwyd"
            "--server-name"; "example.test"
            "--asset-root"; root
            "--bind-host"; _TestHost()
            "--bind-port"; "0" ]
        end, auth)
      | let c: Config => c
      | let e: StartupError => h.fail(e.message); h.complete(false); return
      | let hr: HelpRequested => h.fail("help requested"); h.complete(false)
        return
      end

    match Routes(config)
    | let built: hobby.BuiltApplication =>
      let connect_auth = lori.TCPConnectAuth(h.env.root)
      let notify =
        _TestNotify(
          {(port, server)(connect_auth, request, check, h) =>
            _TestClient(
              connect_auth,
              port,
              request,
              server,
              {(resp)(check, h) => check(resp); h.complete(true) } val)
          } val)
      hobby.Server(
        lori.TCPListenAuth(h.env.root),
        built,
        notify
        where host = _TestHost(), port = config.bind_port)
    | let e: hobby.ConfigError =>
      h.fail(e.message)
      h.complete(false)
    end

primitive _Fixture
  """
  The smallest directory `_AssetRoot` accepts: `index.html` and `bundles/`.
  """
  fun apply(h: TestHelper): String =>
    let dir = FilePath(FileAuth(h.env.root), "build/test-asset-root")
    dir.mkdir()
    try
      let bundles = FilePath.from(dir, "bundles")?
      bundles.mkdir()
      _write(FilePath.from(dir, "index.html")?, "<html>fixture</html>")
      _write(FilePath.from(bundles, "app.js")?, "// fixture")
    end
    dir.path

  fun _write(path: FilePath, body: String) =>
    File(path) .> write(body) .> dispose()

primitive _Get
  """
  A GET request that closes the connection, so the client sees a complete
  response without needing to parse Content-Length.
  """
  fun apply(path: String): String =>
    "GET " + path + " HTTP/1.1\r\nHost: example.test\r\n"
      + "Connection: close\r\n\r\n"
