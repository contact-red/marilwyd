use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestClaimWithoutATokenIsRefused is UnitTest
  fun name(): String => "todevice/claiming without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/keys/claim", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestSendToDeviceWithoutATokenIsRefused is UnitTest
  fun name(): String => "todevice/sending without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send(
        "PUT",
        "/_matrix/client/v3/sendToDevice/m.room.encrypted/1",
        "{\"messages\":{}}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestAClaimFindsAnUploadedKey is UnitTest
  """
  Upload then claim, over real sockets. The pool one endpoint fills is the
  pool the other drains, and nothing else in the suite crosses that seam
  through the registry.
  """
  fun name(): String => "todevice/a claim answers with an uploaded key"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/upload",
          "{\"one_time_keys\":{\"signed_curve25519:aaa\":" +
            "{\"key\":\"secret\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first) =>
        // Its own device: the only one a single-token test can name, and
        // the case a client actually exercises when it talks to itself.
        _Post(
          "/_matrix/client/v3/keys/claim",
          "{\"one_time_keys\":{\"@" + _TestUser.localpart() +
            ":example.test\":{\"" + _DeviceFrom(login) + "\":" +
            "\"signed_curve25519\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"signed_curve25519:aaa\""), r)
        h.assert_true(r.contains("secret"), r)
      } val)

class \nodoc\ iso _TestAClaimForAnUnknownDeviceIsEmpty is UnitTest
  fun name(): String => "todevice/claiming an unknown device answers empty"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/claim",
          "{\"one_time_keys\":{\"@" + _TestUser.localpart() +
            ":example.test\":{\"NOSUCHDEVICE\":\"signed_curve25519\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"one_time_keys\":{}"), r)
      } val)

class \nodoc\ iso _TestAClaimForAnUnknownAccountIsEmpty is UnitTest
  """
  Unlike `keys/query`, which must name every account it was asked about, a
  claim leaves out what it could not find. A claim is about devices, and
  there is nothing to say about a device that does not exist.
  """
  fun name(): String => "todevice/claiming an unknown account answers empty"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/claim",
          "{\"one_time_keys\":{\"@nobody:example.test\":" +
            "{\"AAA\":\"signed_curve25519\"}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"one_time_keys\":{}"), r)
      } val)

class \nodoc\ iso _TestASentMessageReachesTheNextSync is UnitTest
  """
  The whole channel over HTTP: a device sends to itself and reads it back
  out of `/sync`, which is the only place a to-device message is ever
  delivered.
  """
  fun name(): String => "todevice/a sent message comes back from sync"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Send(
          "PUT",
          "/_matrix/client/v3/sendToDevice/m.room.encrypted/txn1",
          "{\"messages\":{\"@" + _TestUser.localpart() + ":example.test\":" +
            "{\"*\":{\"ciphertext\":\"opaque\"}}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first) =>
        _Send(
          "GET",
          "/_matrix/client/v3/sync?timeout=0",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"to_device\":{\"events\":["), r)
        h.assert_true(r.contains("m.room.encrypted"), r)
        h.assert_true(r.contains("opaque"), r)
      } val)

class \nodoc\ iso _TestSendingToNobodyIsAccepted is UnitTest
  """
  Naming an account marilwyd has never seen is not an error and is not
  reported. Saying which of the names a sender guessed exist would let
  anyone enumerate accounts.
  """
  fun name(): String => "todevice/sending to an unknown account is accepted"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Send(
          "PUT",
          "/_matrix/client/v3/sendToDevice/m.room.encrypted/txn9",
          "{\"messages\":{\"@nobody:example.test\":{\"AAA\":{\"a\":1}}}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_false(r.contains("errcode"), r)
      } val)
