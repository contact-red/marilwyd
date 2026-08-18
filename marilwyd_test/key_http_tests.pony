use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestKeyUploadWithoutATokenIsRefused is UnitTest
  fun name(): String => "keys/uploading without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/keys/upload", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestKeyQueryWithoutATokenIsRefused is UnitTest
  """
  The one endpoint where a wrong answer costs a request storm rather than
  an error, so the refusal has to be a refusal rather than an empty answer.
  """
  fun name(): String => "keys/querying without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/keys/query", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestKeyUploadAnswersACount is UnitTest
  fun name(): String => "keys/an upload answers how many keys are held"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/upload",
          "{\"device_keys\":{\"algorithms\":[\"m.olm.v1\"],"
            + "\"keys\":{\"ed25519:AAA\":\"k\"}},"
            + "\"one_time_keys\":{\"signed_curve25519:a\":{\"key\":\"1\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(
          r.contains("\"one_time_key_counts\":{\"signed_curve25519\":1}"), r)
      } val)

class \nodoc\ iso _TestAQueryFindsAnUploadedKey is UnitTest
  """
  The two endpoints as one path, which is the only way either is worth
  anything: what a device publishes is what a query answers.
  """
  fun name(): String => "keys/a query answers with an uploaded device key"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/upload",
          "{\"device_keys\":{\"algorithms\":[\"m.olm.v1\"],"
            + "\"keys\":{\"ed25519:AAA\":\"published\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first) =>
        _Post(
          "/_matrix/client/v3/keys/query",
          "{\"device_keys\":{}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("published"), r)
        // The account that asked, even though the body named nobody.
        h.assert_true(r.contains("@" + _TestUser.localpart() + ":"), r)
      } val)

class \nodoc\ iso _TestAQueryAnswersAnUnknownAccount is UnitTest
  """
  Naming an account marilwyd has never seen answers with no devices for it,
  not with a missing entry.
  """
  fun name(): String => "keys/a query answers about an account it lacks"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/query",
          "{\"device_keys\":{\"@nobody:example.test\":[]}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"@nobody:example.test\":{}"), r)
      } val)

class \nodoc\ iso _TestCrossSigningUploadIsAccepted is UnitTest
  """
  Without user-interactive authentication, deliberately: marilwyd has no
  second factor to ask for, so a `401` here would be a form a client fills
  in with the password that minted the token it already sent.
  """
  fun name(): String => "keys/cross-signing keys upload without a challenge"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/device_signing/upload",
          "{\"master_key\":{\"keys\":{\"ed25519:M\":\"M\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_false(r.contains("M_FORBIDDEN"), r)
      } val)

class \nodoc\ iso _TestSignatureUploadIsAccepted is UnitTest
  """
  Removing this endpoint was measured to end a session at "Unable to set up
  keys" before it ever reached the backup step, so its presence is the
  assertion.
  """
  fun name(): String => "keys/a signature upload is accepted"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/signatures/upload",
          "{\"@" + _TestUser.localpart() + ":example.test\":{\"AAA\":"
            + "{\"signatures\":{\"@a:x\":{\"ed25519:M\":\"s\"}}}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"failures\":{}"), r)
      } val)

class \nodoc\ iso _TestNoBackupIsNotFound is UnitTest
  """
  Before a client makes one. `M_NOT_FOUND` rather than an empty version:
  an empty answer would tell a client a backup already exists.
  """
  fun name(): String => "keys/asking for a backup before one exists"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Send(
          "GET",
          "/_matrix/client/v3/room_keys/version",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_NOT_FOUND")
      } val)

class \nodoc\ iso _TestABackupCanBeMadeAndRead is UnitTest
  """
  Not encryption itself, but the step a client stops at: with this
  answering `M_UNRECOGNIZED`, Element ends at "Unable to set up keys" and
  never reaches the app.
  """
  fun name(): String => "keys/a backup version is made and then answered"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/room_keys/version",
          "{\"algorithm\":\"m.megolm_backup.v1.curve25519-aes-sha2\","
            + "\"auth_data\":{\"public_key\":\"pk\"}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first) =>
        _Send(
          "GET",
          "/_matrix/client/v3/room_keys/version",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"version\":\"1\""), r)
        h.assert_true(r.contains("\"public_key\":\"pk\""), r)
        h.assert_true(r.contains("m.megolm_backup.v1"), r)
      } val)

class \nodoc\ iso _TestABackupNeedsAnAlgorithm is UnitTest
  fun name(): String => "keys/a backup without an algorithm is refused"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/room_keys/version",
          "{\"auth_data\":{\"public_key\":\"pk\"}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_INVALID_PARAM")
      } val)
