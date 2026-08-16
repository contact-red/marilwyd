use "pony_test"
use "files"
use "json"
use "ssl/crypto"
use "../marilwyd"

// ------------------------------------------------------------- credentials
class \nodoc\ iso _TestCredentialVerifies is UnitTest
  fun name(): String => "credentials/the right password verifies"

  fun apply(h: TestHelper) ? =>
    let salt = RandBytes(16)?
    let hash = Pbkdf2Sha256("hunter2", salt, 1000, Pbkdf2KeyLength())?
    let c = Credential("alice", 1000, salt, hash)
    h.assert_true(c.verify("hunter2"))

class \nodoc\ iso _TestCredentialRejectsWrongPassword is UnitTest
  """
  Also covers the derivation-failure path: a `Credential` that cannot derive
  must answer false, never raise something a caller might read as a match.
  """
  fun name(): String => "credentials/a wrong password does not verify"

  fun apply(h: TestHelper) ? =>
    let salt = RandBytes(16)?
    let hash = Pbkdf2Sha256("hunter2", salt, 1000, Pbkdf2KeyLength())?
    let c = Credential("alice", 1000, salt, hash)
    h.assert_false(c.verify("hunter3"))
    h.assert_false(c.verify(""))
    h.assert_false(Credential("alice", 0, salt, hash).verify("hunter2"))

class \nodoc\ iso _TestCredentialsRejectDuplicateLocalpart is UnitTest
  """
  Two entries for one localpart is ambiguous about which password is live.
  """
  fun name(): String => "credentials/a duplicate localpart is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "duplicate",
      "{\"users\":[" + _Entry("alice") + "," + _Entry("alice") + "]}",
      "credentials-duplicate")

class \nodoc\ iso _TestCredentialsRejectUnknownAlgorithm is UnitTest
  """
  An entry naming an algorithm marilwyd does not implement must be refused
  rather than checked with the wrong primitive.
  """
  fun name(): String => "credentials/an unknown algorithm is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "algorithm",
      "{\"users\":[{\"localpart\":\"a\",\"algorithm\":\"md5\","
        + "\"iterations\":1,\"salt\":\"00\",\"hash\":\"00\"}]}",
      "credentials-algorithm")

class \nodoc\ iso _TestCredentialsRejectEmptyUserList is UnitTest
  """
  A server nobody can log into is a configuration mistake, not a valid state.
  """
  fun name(): String => "credentials/an empty user list is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "empty",
      "{\"users\":[]}",
      "credentials-empty")

primitive _Entry
  fun apply(localpart: String): String =>
    "{\"localpart\":\"" + localpart + "\",\"algorithm\":\"pbkdf2-sha256\","
      + "\"iterations\":1,\"salt\":\"00\",\"hash\":\"00\"}"

primitive _AssertCredentialsRefused
  fun apply(
    h: TestHelper,
    fixture: String,
    body: String,
    expected_cause: String)
  =>
    // A distinct path per test: PonyTest runs these concurrently, and a
    // shared fixture file makes them clobber each other.
    let path =
      FilePath(
        FileAuth(h.env.root),
        "build/test-credentials-" + fixture + ".json")
    File(path) .> write(body) .> dispose()
    match ReadCredentials(path)
    | let c: Credentials => h.fail("accepted " + body)
    | let e: StartupError => h.assert_eq[String](expected_cause, e.cause)
    end

// -------------------------------------------------------------------- login
class \nodoc\ iso _TestLoginIssuesAToken is UnitTest
  fun name(): String => "login/a correct password yields a token"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", _PasswordLogin(_TestUser.password())),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        try
          let body = r.substring(r.find("\r\n\r\n")? + 4)
          match JsonParser.parse(consume body)
          | let o: JsonObject =>
            h.assert_eq[String](
              "@alice:example.test", o("user_id")? as String)
            // 32 random bytes, hex encoded.
            h.assert_eq[USize](64, (o("access_token")? as String).size())
          else
            h.fail("body is not a JSON object: " + r)
          end
        else
          h.fail("no usable body: " + r)
        end
      } val)

class \nodoc\ iso _TestLoginRejectsWrongPassword is UnitTest
  fun name(): String => "login/a wrong password is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", _PasswordLogin("not the password")),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 403 Forbidden\r\n"), r)
        _AssertErrcode(h, r, "M_FORBIDDEN")
      } val)

class \nodoc\ iso _TestUnknownUserIsIndistinguishable is UnitTest
  """
  An unknown user and a wrong password must produce the same answer, or the
  endpoint enumerates accounts.
  """
  fun name(): String => "login/an unknown user answers as a wrong password"

  fun apply(h: TestHelper) =>
    let body =
      "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\","
        + "\"user\":\"nobody\"},\"password\":\"whatever\"}"
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", body),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 403 Forbidden\r\n"), r)
        h.assert_true(r.contains("Invalid username or password"), r)
        _AssertErrcode(h, r, "M_FORBIDDEN")
      } val)

primitive _PasswordLogin
  fun apply(password: String): String =>
    "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\","
      + "\"user\":\"" + _TestUser.localpart() + "\"},"
      + "\"password\":\"" + password + "\"}"

// ------------------------------------------------------------------ whoami
class \nodoc\ iso _TestWhoamiWithoutTokenIsUnauthorized is UnitTest
  fun name(): String => "whoami/no token is M_MISSING_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/account/whoami"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestWhoamiRejectsAnUnknownToken is UnitTest
  fun name(): String => "whoami/an unknown token is M_UNKNOWN_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get(
        "/_matrix/client/v3/account/whoami",
        "Authorization: Bearer deadbeef\r\n"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_UNKNOWN_TOKEN")
      } val)

// ------------------------------------------------------------------ tokens
class \nodoc\ iso _TestTokensAreUnguessable is UnitTest
  """
  Two tokens minted back to back must not collide, and each must carry the
  full 256 bits. A generator that quietly produced a short or repeated token
  would still satisfy every other test in this suite.
  """
  fun name(): String => "tokens/each token is distinct and full length"

  fun apply(h: TestHelper) =>
    match (MakeAccessToken(), MakeAccessToken())
    | (let a: AccessToken, let b: AccessToken) =>
      h.assert_eq[USize](64, a.reveal().size())
      h.assert_eq[USize](64, b.reveal().size())
      h.assert_ne[String](a.reveal(), b.reveal())
      h.assert_true(a.matches(a.reveal()))
      h.assert_false(a.matches(b.reveal()))
      h.assert_false(a.matches(""))
    else
      h.fail("the CSPRNG refused to mint a token")
    end
