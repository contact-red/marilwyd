use "collections"
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
      _Users(_Entry("alice") + _Entry("alice")),
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
      _Users(_EntryWith("a", "md5", "1", "00", "00")),
      "credentials-algorithm")

class \nodoc\ iso _TestCredentialsRejectEmptyHash is UnitTest
  """
  An empty hash made `verify` derive nothing and compare nothing, so every
  password matched. The stored value must never choose the width of its own
  comparison.
  """
  fun name(): String => "credentials/an empty hash is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "empty-hash",
      _Users(
        _EntryWith(
          "a",
          "pbkdf2-sha256",
          "600000",
          _Hex(Pbkdf2SaltLength()),
          "")),
      "credentials-hash-length")

class \nodoc\ iso _TestCredentialsRejectTruncatedHash is UnitTest
  """
  A short hash is the likely form of the same defect: a truncated paste used
  to become a prefix check rather than a refusal.
  """
  fun name(): String => "credentials/a truncated hash is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "short-hash",
      _Users(
        _EntryWith(
          "a",
          "pbkdf2-sha256",
          "600000",
          _Hex(Pbkdf2SaltLength()),
          _Hex(4))),
      "credentials-hash-length")

class \nodoc\ iso _TestCredentialsRejectShortSalt is UnitTest
  fun name(): String => "credentials/a short salt is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "short-salt",
      _Users(
        _EntryWith(
          "a",
          "pbkdf2-sha256",
          "600000",
          "00",
          _Hex(Pbkdf2KeyLength()))),
      "credentials-salt-length")

class \nodoc\ iso _TestCredentialsRejectWeakIterations is UnitTest
  """
  An unstretched entry is accepted by every other check in the file.
  """
  fun name(): String =>
    "credentials/an iteration count below the floor is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "weak-iterations",
      _Users(
        _EntryWith(
          "a",
          "pbkdf2-sha256",
          "1",
          _Hex(Pbkdf2SaltLength()),
          _Hex(Pbkdf2KeyLength()))),
      "credentials-iterations")

class \nodoc\ iso _TestCredentialsRejectNarrowingIterations is UnitTest
  """
  A count above 2^32 is refused where it is read, not after.

  Narrowing by hand wraps, so such a count used to become a small one and
  quietly unstretch the entry. Binding it as a `U32` makes that
  unrepresentable, which is why this is refused as malformed rather than by
  the iteration-count rule — the rule never sees a value it could be wrong
  about.
  """
  fun name(): String =>
    "credentials/an iteration count that would narrow is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "narrowing-iterations",
      _Users(
        _EntryWith(
          "a",
          "pbkdf2-sha256",
          "4294968296",
          _Hex(Pbkdf2SaltLength()),
          _Hex(Pbkdf2KeyLength()))),
      "credentials-malformed")

class \nodoc\ iso _TestCredentialsRejectBadLocalpart is UnitTest
  """
  A localpart holding a `:` can never be logged into, because the parser
  stops at the first one; an empty one is not addressable at all.
  """
  fun name(): String => "credentials/a localpart outside the grammar is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "bad-localpart",
      _Users(_Entry("@bob:elsewhere")),
      "credentials-localpart")

class \nodoc\ iso _TestCredentialsRejectEmptyUserList is UnitTest
  """
  A server nobody can log into is a configuration mistake, not a valid state.
  """
  fun name(): String => "credentials/an empty user list is refused"

  fun apply(h: TestHelper) =>
    _AssertCredentialsRefused(
      h,
      "empty",
      _Users(""),
      "credentials-empty")

primitive _Entry
  """
  A structurally valid entry. Every value is one `_Entry` accepts, so a test
  using this fails for the reason it names rather than for its fixture.
  """
  fun apply(localpart: String): String =>
    _EntryWith(
      localpart,
      "pbkdf2-sha256",
      "600000",
      _Hex(Pbkdf2SaltLength()),
      _Hex(Pbkdf2KeyLength()))

primitive _EntryWith
  """
  One `users` element with every field spelled out, so a test can make
  exactly one of them wrong.

  `iterations` is text rather than a number because some tests need a value
  no integer type holds.
  """
  fun apply(
    localpart: String,
    algorithm: String,
    iterations: String,
    salt: String,
    hash: String)
    : String
  =>
    "  - localpart: \"" + localpart + "\"\n" +
      "    algorithm: \"" + algorithm + "\"\n" +
      "    iterations: " + iterations + "\n" +
      "    salt: \"" + salt + "\"\n" +
      "    hash: \"" + hash + "\"\n"

primitive _Users
  """
  A credentials document holding `entries`.
  """
  fun apply(entries: String): String =>
    if entries.size() == 0 then
      "users: []\n"
    else
      "users:\n" + entries
    end

primitive _Hex
  """
  A fixed, well-formed value of a given length, for fixtures that need one
  and do not care which.

  Fixed rather than random on purpose: concurrent tests share fixture files,
  so the bytes written must be the same every time.
  """
  fun apply(n: USize): String =>
    let s = recover String(n * 2) end
    for _ in Range(0, n) do
      s.append("ab")
    end
    consume s

  fun bytes(n: USize): Array[U8] val =>
    recover val Array[U8].init(0xab, n) end

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
        "build/test-credentials-" + fixture + ".yaml")
    File(path) .> set_length(0) .> write(body) .> dispose()
    match \exhaustive\ ReadCredentials(path)
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
          match JSONParser.parse(consume body)
          | let o: JSONObject =>
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
      "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\"," +
        "\"user\":\"nobody\"},\"password\":\"whatever\"}"
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", body),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 403 Forbidden\r\n"), r)
        h.assert_true(r.contains("Invalid username or password"), r)
        _AssertErrcode(h, r, "M_FORBIDDEN")
      } val)

primitive _PasswordLogin
  fun apply(
    password: String,
    localpart: String = _TestUser.localpart())
    : String
  =>
    "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\"," +
      "\"user\":\"" + localpart + "\"}," +
      "\"password\":\"" + password + "\"}"

// ------------------------------------------- unimplemented matrix endpoints
class \nodoc\ iso _TestUnimplementedRejectsStaleToken is UnitTest
  """
  Element does not call whoami when it restores a session: it calls
  endpoints like /capabilities and /keys/query. If those answered a flat
  404, a client holding a token from before a restart would be told the
  endpoint is missing and never that its session is gone — so it would keep
  the token, keep showing a signed-in account, and wait for data that
  cannot come.

  The path has to be one marilwyd does not implement, or this stops
  testing `_Unrecognized` and starts testing whichever handler took it
  over — silently, because a real handler answers a stale token the same
  way.
  """
  fun name(): String =>
    "matrix/an unimplemented endpoint rejects a stale token"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get(
        "/_matrix/client/v3/capabilities",
        "Authorization: Bearer nosuchtoken\r\n"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_UNKNOWN_TOKEN")
        h.assert_true(r.contains("soft_logout"), r)
      } val)

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

class \nodoc\ iso _TestAnUpwardPathIsRefused is UnitTest
  """
  A request that walks upward out of the asset root is refused, with no
  credential involved.

  Everything under `--asset-root` is served unauthenticated, so the one
  thing worth being certain of is that nothing outside it ever is.
  `_ContainedPath` is what marilwyd asserts that with rather than
  inheriting it, and this is what holds it to it.
  """
  fun name(): String => "auth/a path walking out of the root is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/../secrets/key"),
      {(r) =>
        h.assert_true(
          r.contains("HTTP/1.1 400 Bad Request\r\n"),
          "a path with a .. segment was not refused: " + r)
      } val)

class \nodoc\ iso _TestAnOrdinaryAssetPathIsServed is UnitTest
  """
  And an ordinary path still is, so the gate is a gate rather than a wall.
  """
  fun name(): String => "auth/an ordinary asset path is served"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/index.html"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("fixture"), r)
      } val)

class \nodoc\ iso _TestADotDotFilenameIsNotRefused is UnitTest
  """
  A name that merely begins with two dots is not a walk upward.

  The check is on segments and not on the characters: a file honestly
  called `..config` goes nowhere near its parent, and refusing it would be
  a quieter bug of the same family.
  """
  fun name(): String => "auth/a filename beginning with dots is allowed"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/element/..config"),
      {(r) =>
        // Absent from the fixture, so a 404 — but reaching the file
        // server at all is what is being asserted.
        h.assert_false(
          r.contains("HTTP/1.1 400 Bad Request\r\n"),
          "an ordinary filename was refused as a traversal: " + r)
      } val)
