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
    test(_TestSyncWaitDefaultsToZero)
    test(_TestSyncWaitHonoursRequest)
    test(_TestSyncWaitClamps)
    test(_TestSyncWaitRefusesMalformed)
    test(_TestSyncWaitRefusesUndecodableQuery)
    test(_TestMaxSyncWaitIsUnderTheWatchdog)
    test(_TestSyncWithoutTokenIsUnauthorized)
    test(_TestSyncRejectsAnUnknownToken)
    test(_TestSyncAnswersAtOnceWithoutATimeout)
    test(_TestSyncHoldsForTheRequestedTimeout)
    test(_TestSyncRefusesAMalformedTimeout)
    test(_TestPushRulesRequiresAToken)
    test(_TestPushRulesServesARuleset)
    test(_TestFilterCreateReturnsAnID)
    test(_TestFilterFetchRequiresAToken)
    test(_TestNonGetUnimplementedIsJSON)

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
  let _close_server: Bool

  new create(
    auth: lori.TCPConnectAuth,
    port: String,
    request: String,
    server: hobby.Server tag,
    check: {(String)} val,
    close_server: Bool = true)
  =>
    """
    `close_server = false` leaves the listener up so a second request can
    be sent to it — see `_ServeAuthed`, where the first request is a login
    whose token the second one has to spend.
    """
    _request = request
    _server = server
    _check = check
    _close_server = close_server
    _conn = lori.TCPConnection.client(auth, _TestHost(), port, "", this, this)

  fun ref _connection(): lori.TCPConnection => _conn

  fun ref _on_connected() =>
    _conn.send(_request)

  fun ref _on_received(data: Array[U8] iso): lori.ReadAction =>
    _response.append(consume data)
    lori.KeepReading

  fun ref _on_closed() =>
    _check(_response.clone())
    if _close_server then
      _server.dispose()
    end

  fun ref _on_connection_failure(reason: lori.ConnectionFailureReason) =>
    // Always closes, whatever `_close_server` says: a failed connection
    // means no follow-up request is coming, so nothing else will.
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

    let config =
      match _TestConfig(h)
      | let c: Config => c
      else
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

primitive _TestConfig
  """
  The configuration every server-booting test runs on.

  Fails and completes the test itself on any error, so a caller that gets
  `None` back has nothing left to do but return.
  """
  fun apply(h: TestHelper): (Config | None) =>
    match \exhaustive\ Configure(
      recover val
        [ "marilwyd"; "serve"
          "--server-name"; "example.test"
          "--asset-root"; _Fixture(h)
          "--credentials"; _CredentialsFixture(h)
          "--bind-host"; _TestHost()
          "--bind-port"; "0" ]
      end, FileAuth(h.env.root))
    | let c: Config => c
    | let e: StartupError => h.fail(e.message); h.complete(false); None
    | let hr: HelpRequested => h.fail("help requested"); h.complete(false)
      None
    | let hp: HashPasswordRequested =>
      h.fail("hash-password requested"); h.complete(false)
      None
    end

primitive _ServeAuthed
  """
  Boot the real route table, log `_TestUser` in, then send one request
  carrying the token that login issued.

  Two connections against one listener, because the token has to exist
  before the second request can be built. Nothing else in the suite spends
  a real token over HTTP — every other token test either fabricates one or
  goes at `SessionRegistry` directly — so no authenticated route's success
  path was reachable from a test before this.

  `build` receives the access token and returns the raw request to send.
  """
  fun apply(
    h: TestHelper,
    build: {(String): String} val,
    check: {(String)} val)
  =>
    h.long_test(10_000_000_000)

    let config =
      match _TestConfig(h)
      | let c: Config => c
      else
        return
      end

    match \exhaustive\ Routes(config, SessionRegistry)
    | let built: hobby.BuiltApplication =>
      let connect_auth = lori.TCPConnectAuth(h.env.root)
      let notify =
        _TestNotify(
          {(port, server)(connect_auth, build, check, h) =>
            _TestClient(
              connect_auth,
              port,
              _Post(
                "/_matrix/client/v3/login",
                _PasswordLogin(_TestUser.password())),
              server,
              {(login)(connect_auth, port, build, check, h, server) =>
                match _TokenFrom(login)
                | let token: String =>
                  _TestClient(
                    connect_auth,
                    port,
                    build(token),
                    server,
                    {(resp)(check, h) => check(resp); h.complete(true) } val)
                else
                  h.fail("login did not yield an access token: " + login)
                  h.complete(false)
                  server.dispose()
                end
              } val
              where close_server = false)
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

primitive _TokenFrom
  """
  Pull `access_token` out of a raw login response.

  A substring scan rather than a parse: the response is a whole HTTP
  message, and the tests that care whether the body is well-formed JSON
  assert that separately.
  """
  fun apply(response: String): (String | None) =>
    let key = "\"access_token\":\""
    try
      let start = response.find(key)? + key.size().isize()
      let finish = response.find("\"", start)?
      response.substring(start, finish)
    else
      None
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
