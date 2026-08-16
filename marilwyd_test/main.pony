use "pony_test"
use "files"
use "ssl/crypto"
use "../marilwyd"
use hobby = "hobby"
use lori = "lori"

actor Main is TestList
  new create(env: Env) =>
    // Written once, here, rather than by each test that needs them.
    // PonyTest runs tests concurrently and they share these paths, so a
    // test that wrote its own fixture would truncate a file another test
    // was in the middle of reading.
    _WriteFixtures(env)
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
    test(_TestLoginPostRefusesInMatrixVocabulary)
    test(_TestServerNameRejectsURL)
    test(_TestServerNameRejectsBadPort)
    test(_TestBindPortDerivedFromServerName)
    test(_TestBindPortRefusesPrivilegedDerived)
    test(_TestBindPortExplicitOverrides)
    test(_TestCredentialVerifies)
    test(_TestCredentialRejectsWrongPassword)
    test(_TestCredentialsRejectDuplicateLocalpart)
    test(_TestCredentialsRejectUnknownAlgorithm)
    test(_TestCredentialsRejectEmptyUserList)
    test(_TestLoginIssuesAToken)
    test(_TestLoginRejectsWrongPassword)
    test(_TestUnknownUserIsIndistinguishable)
    test(_TestWhoamiWithoutTokenIsUnauthorized)
    test(_TestWhoamiRejectsAnUnknownToken)
    test(_TestTokensAreUnguessable)
    test(_TestIssuedTokenResolves)
    test(_TestUnknownTokenDoesNotResolve)
    test(_TestDeviceIdIsNotTheAccessToken)
    test(_TestCredentialsRejectEmptyHash)
    test(_TestCredentialsRejectTruncatedHash)
    test(_TestCredentialsRejectShortSalt)
    test(_TestCredentialsRejectWeakIterations)
    test(_TestCredentialsRejectNarrowingIterations)
    test(_TestCredentialsRejectBadLocalpart)
    test(_TestUnimplementedRejectsStaleToken)
    test(_TestUnimplementedWithoutTokenIs404)

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
      match \exhaustive\ Configure(
        recover val
          [ "marilwyd"; "serve"
            "--server-name"; "example.test"
            "--asset-root"; root
            "--credentials"; _CredentialsFixture(h)
            "--bind-host"; _TestHost()
            "--bind-port"; "0" ]
        end, auth)
      | let c: Config => c
      | let e: StartupError => h.fail(e.message); h.complete(false); return
      | let hr: HelpRequested => h.fail("help requested"); h.complete(false)
        return
      | let hp: HashPasswordRequested =>
        h.fail("hash-password requested"); h.complete(false)
        return
      end

    match \exhaustive\ Routes(config, SessionRegistry)
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
  fun path(): String => "build/test-asset-root"

  fun apply(h: TestHelper): String => path()

primitive _Get
  """
  A GET request that closes the connection, so the client sees a complete
  response without needing to parse Content-Length.
  """
  fun apply(path: String, headers: String = ""): String =>
    "GET " + path + " HTTP/1.1\r\nHost: example.test\r\n" + headers
      + "Connection: close\r\n\r\n"

primitive _Post
  fun apply(path: String, body: String): String =>
    "POST " + path + " HTTP/1.1\r\nHost: example.test\r\n"
      + "Content-Length: " + body.size().string() + "\r\n"
      + "Content-Type: application/json\r\n"
      + "Connection: close\r\n\r\n" + body

primitive _TestUser
  fun localpart(): String => "alice"
  fun password(): String => "hunter2"

  fun iterations(): U32 =>
    """
    The floor, not the production figure. Entries carry their own count, so
    the suite can run at the cheapest count `_Entry` accepts.
    """
    Pbkdf2MinIterations()

primitive _CredentialsFixture
  """
  The credentials file every server-booting test uses.
  """
  fun path(): String => "build/test-credentials.json"

  fun apply(h: TestHelper): String => path()

primitive _WriteFixtures
  """
  Build every fixture the suite reads, once, before any test starts.
  """
  fun apply(env: Env) =>
    let auth = FileAuth(env.root)

    let dir = FilePath(auth, _Fixture.path())
    dir.mkdir()
    try
      let bundles = FilePath.from(dir, "bundles")?
      bundles.mkdir()
      _write(FilePath.from(dir, "index.html")?, "<html>fixture</html>")
      _write(FilePath.from(bundles, "app.js")?, "// fixture")
    end

    try
      let salt = _Hex.bytes(Pbkdf2SaltLength())
      let hash =
        Pbkdf2Sha256(
          _TestUser.password(),
          salt,
          _TestUser.iterations(),
          Pbkdf2KeyLength())?
      let body: String =
        "{\"users\":[{\"localpart\":\"" + _TestUser.localpart() + "\","
          + "\"algorithm\":\"pbkdf2-sha256\","
          + "\"iterations\":" + _TestUser.iterations().string() + ","
          + "\"salt\":\"" + ToHexString(salt) + "\","
          + "\"hash\":\"" + ToHexString(hash) + "\"}]}"
      let path = FilePath(auth, _CredentialsFixture.path())
      _write(path, body)
      // `_ReadCredentialsFile` refuses a file others can read.
      let owner_only: FileMode ref = FileMode
      owner_only.group_read = false
      owner_only.any_read = false
      path.chmod(owner_only)
    end

  fun _write(path: FilePath, body: String) =>
    File(path) .> set_length(0) .> write(body) .> dispose()
