use "pony_test"
use "time"
use "../marilwyd"
use hobby = "hobby"

// ------------------------------------------------------------- the rule
// `SyncWait` is public so these can call it. The clamp is what keeps a 504
// off the wire, and proving it over HTTP would need a 25-second test.

class \nodoc\ iso _TestSyncWaitDefaultsToZero is UnitTest
  """
  Zero is the specification's default, and it is what Element sends on its
  first sync and while reconnecting.
  """
  fun name(): String => "sync/an absent timeout is zero"

  fun apply(h: TestHelper) =>
    h.assert_eq[U64](0, _Waited(h, None))
    h.assert_eq[U64](0, _Waited(h, ""))
    h.assert_eq[U64](0, _Waited(h, "since=s0"))

class \nodoc\ iso _TestSyncWaitHonoursRequest is UnitTest
  fun name(): String => "sync/a timeout under the cap is honoured"

  fun apply(h: TestHelper) =>
    h.assert_eq[U64](1000, _Waited(h, "timeout=1000"))
    h.assert_eq[U64](0, _Waited(h, "timeout=0"))
    h.assert_eq[U64](
      MaxSyncWait(), _Waited(h, "timeout=" + MaxSyncWait().string()))

class \nodoc\ iso _TestSyncWaitClamps is UnitTest
  """
  Element asks for 30,000 and must not get it.
  """
  fun name(): String => "sync/a timeout over the cap is clamped"

  fun apply(h: TestHelper) =>
    h.assert_eq[U64](MaxSyncWait(), _Waited(h, "timeout=30000"))
    h.assert_eq[U64](MaxSyncWait(), _Waited(h, "timeout=99999999"))
    h.assert_eq[U64](
      MaxSyncWait(), _Waited(h, "timeout=18446744073709551615"))

class \nodoc\ iso _TestSyncWaitRefusesMalformed is UnitTest
  """
  Refused rather than defaulted: zero is the one value that makes a client
  re-ask at once, so defaulting turns a bad parameter into a request flood.
  """
  fun name(): String => "sync/a malformed timeout is refused"

  fun apply(h: TestHelper) =>
    for query in
      [ "timeout=abc"; "timeout=-5"; "timeout=0.5"; "timeout=+3000"
        "timeout=30000abc"; "timeout=0x10"; "timeout="
        "timeout=18446744073709551616" ].values()
    do
      match \exhaustive\ SyncWait(query)
      | let ms: U64 => h.fail(query + " gave " + ms.string())
      | MalformedSyncTimeout => None
      | UndecodableQuery => h.fail(query + " blamed the query string")
      end
    end

class \nodoc\ iso _TestSyncWaitRefusesUndecodableQuery is UnitTest
  """
  A query string decodes whole or not at all, so one bad escape anywhere
  loses `timeout` too. Silently reading that as zero would let an unrelated
  malformed parameter trigger the request flood.
  """
  fun name(): String => "sync/an undecodable query string is refused"

  fun apply(h: TestHelper) =>
    match \exhaustive\ SyncWait("timeout=25000&filter=%ZZ")
    | let ms: U64 => h.fail("gave " + ms.string())
    | UndecodableQuery => None
    | MalformedSyncTimeout =>
      h.fail("blamed timeout, which was well formed")
    end

class \nodoc\ iso _TestMaxSyncWaitIsUnderTheWatchdog is UnitTest
  """
  The whole design rests on this ordering, and nothing in either type
  system enforces it. Asserting it here costs microseconds and fires if
  either side moves — a raised cap, or a hobby release that lowers its
  default.
  """
  fun name(): String => "sync/the cap stays under hobby's handler timeout"

  fun apply(h: TestHelper) =>
    match hobby.DefaultHandlerTimeout()
    | let watchdog: hobby.HandlerTimeout =>
      h.assert_true(
        MaxSyncWait() < watchdog(),
        "cap " + MaxSyncWait().string() +
          " must stay under hobby's " + watchdog().string())
    else
      h.fail("hobby has no default handler timeout to compare against")
    end

primitive _Waited
  """
  `SyncWait` where the caller has already decided the value is well formed.
  """
  fun apply(h: TestHelper, query: (String | None)): U64 =>
    match \exhaustive\ SyncWait(query)
    | let ms: U64 => ms
    | MalformedSyncTimeout | UndecodableQuery =>
      h.fail("refused a well-formed query")
      U64.max_value()
    end

// ------------------------------------------------------------ the route
class \nodoc\ iso _TestSyncWithoutTokenIsUnauthorized is UnitTest
  fun name(): String => "sync/no token is M_MISSING_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/sync"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestSyncRejectsAnUnknownToken is UnitTest
  fun name(): String => "sync/an unknown token is M_UNKNOWN_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get(
        "/_matrix/client/v3/sync",
        "Authorization: Bearer nosuchtoken\r\n"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_UNKNOWN_TOKEN")
        h.assert_true(r.contains("soft_logout"), r)
      } val)

class \nodoc\ iso _TestSyncAnswersAtOnceWithoutATimeout is UnitTest
  """
  The path every client takes on its first sync.
  """
  fun name(): String => "sync/timeout=0 answers immediately"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/sync?timeout=0",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        // A real position now, stamped with this process's epoch, so a
        // token minted by a previous run is recognisable as stale rather
        // than mistaken for one of ours.
        h.assert_true(r.contains("\"next_batch\":\"s"), r)
        // Nothing else: a client in no rooms must see what it saw when
        // marilwyd had no rooms at all, or matrix-js-sdk stays pinned at
        // timeout=0 and re-asks in a tight loop.
        h.assert_false(r.contains("rooms"), r)
        h.assert_false(r.contains("to_device"), r)
      } val)

class \nodoc\ iso _TestFirstSyncDoesNotHold is UnitTest
  """
  A client with no position is owed everything it can see, so there is
  nothing to wait for — it is answered at once even though it asked to
  wait.

  This is why the wake is tested against a `Device` rather than over HTTP:
  parking needs a position, and a position needs a sync to have happened.
  """
  fun name(): String => "sync/a first sync answers without holding"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/sync?timeout=25000",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(
          held < 5_000, "held a first sync for " + held.string() + " ms")
      } val)

class \nodoc\ iso _TestSyncRefusesAMalformedTimeout is UnitTest
  """
  Authenticated: an unauthenticated caller learns nothing about the
  endpoint's parameters, only that its token is missing.
  """
  fun name(): String => "sync/a malformed timeout is M_INVALID_PARAM"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/sync?timeout=abc",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_INVALID_PARAM")
      } val)

// -------------------------------------------------- the gating endpoints
class \nodoc\ iso _TestPushRulesRequiresAToken is UnitTest
  fun name(): String => "pushrules/no token is M_MISSING_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/pushrules/"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestPushRulesServesARuleset is UnitTest
  """
  Sent with the trailing slash Element uses, to prove the route answers the
  spelling the client actually sends.
  """
  fun name(): String => "pushrules/a session gets an empty ruleset"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/pushrules/",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        // Every rule kind, not just one: an absent kind and an empty one
        // are not the same to the client's rules evaluator.
        for kind in
          ["content"; "override"; "room"; "sender"; "underride"].values()
        do
          h.assert_true(r.contains("\"" + kind + "\":[]"), kind + ": " + r)
        end
      } val)

class \nodoc\ iso _TestFilterCreateReturnsAnID is UnitTest
  fun name(): String => "filter/creating one returns a filter_id"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/user/%40alice%3Aexample.test/filter",
          "{}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        _AssertJSONKey(h, r, "filter_id", _TestFilterID())
      } val)

class \nodoc\ iso _TestFilterFetchRequiresAToken is UnitTest
  fun name(): String => "filter/fetching one without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/user/%40alice%3Aexample.test/filter/0"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestNonGetUnimplementedIsJSON is UnitTest
  """
  Without a row for the method, hobby answers a plain-text `Method Not
  Allowed` carrying no `errcode`, which matrix-js-sdk cannot parse. Element
  reaches this on every session — `POST .../keys/query` is the one that
  matters, and it retries forever on anything it cannot read.
  """
  fun name(): String => "routes/an unimplemented POST is M_UNRECOGNIZED"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post(_UnimplementedPath(), "{}"),
      {(r) =>
        h.assert_false(r.contains("Method Not Allowed"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)

primitive _TestFilterID
  """
  The id `FilterCreated` hands out, and the one the fetch route is asked
  for. Written once so the two tests cannot drift apart.
  """
  fun apply(): String => "0"

// --------------------------------------------- auth precedes any work
class \nodoc\ iso _TestSyncParsesNothingWithoutAToken is UnitTest
  """
  The ordering `_SyncHandler` documents and `SECURITY.md` relies on: a
  caller with no token learns nothing about the endpoint's parameters.

  A malformed `timeout` is sent deliberately. If the query were parsed
  before the token were checked, this would answer 400 `M_INVALID_PARAM`
  and disclose that `timeout` is read at all.
  """
  fun name(): String => "sync/no token outranks a malformed parameter"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/sync?timeout=abc"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestSyncParsesNothingForABadToken is UnitTest
  """
  The same ordering one step later: a token that does not resolve is
  answered before the query string is looked at.
  """
  fun name(): String => "sync/a bad token outranks a malformed parameter"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get(
        "/_matrix/client/v3/sync?timeout=abc",
        "Authorization: Bearer nosuchtoken\r\n"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_UNKNOWN_TOKEN")
      } val)

class \nodoc\ iso _TestSyncRefusesAnUndecodableQuery is UnitTest
  """
  A good `timeout` behind a bad escape elsewhere. The message has to name
  the query string rather than `timeout`, which is why the two causes are
  separate types.
  """
  fun name(): String => "sync/an undecodable query is refused by name"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/sync?timeout=1&filter=%ZZ",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_INVALID_PARAM")
        h.assert_true(r.contains("percent-encoding"), r)
      } val)

// ------------------------------------------- the halves that were missing
class \nodoc\ iso _TestFilterCreateRequiresAToken is UnitTest
  """
  Discriminating because the catch-all answers a token-less POST with 404:
  a 401 here can only come from the filter route's own authentication.
  """
  fun name(): String => "filter/creating one without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/user/%40alice%3Aexample.test/filter", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestFilterFetchServesAnEmptyFilter is UnitTest
  fun name(): String => "filter/a session gets an empty filter back"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/user/%40alice%3Aexample.test/filter/" +
            _TestFilterID(),
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("{}"), r)
      } val)

class \nodoc\ iso _TestAuthedJSONRejectsAnUnknownToken is UnitTest
  fun name(): String => "pushrules/an unknown token is M_UNKNOWN_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get(
        "/_matrix/client/v3/pushrules/",
        "Authorization: Bearer nosuchtoken\r\n"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_UNKNOWN_TOKEN")
        h.assert_true(r.contains("soft_logout"), r)
      } val)

// ----------------------------------------- the rest of the catch-all rows
class \nodoc\ iso _TestUnimplementedPutIsJSON is UnitTest
  """
  `PUT` is the method Element sends most often to a path marilwyd does not
  implement — account data, several times a session.
  """
  fun name(): String => "routes/an unimplemented PUT is M_UNRECOGNIZED"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send("PUT", _UnimplementedPath(), "{}"),
      {(r) =>
        h.assert_false(r.contains("Method Not Allowed"), r)
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)

class \nodoc\ iso _TestUnimplementedDeleteIsJSON is UnitTest
  fun name(): String => "routes/an unimplemented DELETE is M_UNRECOGNIZED"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send("DELETE", _UnimplementedPath(), "{}"),
      {(r) =>
        h.assert_false(r.contains("Method Not Allowed"), r)
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)

class \nodoc\ iso _TestMatrixRootAnswersEveryMethod is UnitTest
  """
  `/_matrix` exactly, which the wildcard provably cannot answer — hobby
  stops consulting wildcard entries once the path segments run out, so the
  namespace root needs a companion row per method.
  """
  fun name(): String => "routes/the _matrix root answers POST in JSON"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send("POST", "/_matrix", "{}"),
      {(r) =>
        h.assert_false(r.contains("Method Not Allowed"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)

// --------------------------------------------------- devices and logout
class \nodoc\ iso _TestWhoamiReportsTheDevice is UnitTest
  """
  With several clients signed in as one account, this is the only way a
  client can find out which session its own token belongs to.
  """
  fun name(): String => "whoami/a session is told its device id"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/account/whoami",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("device_id"), r)
        _AssertJSONKey(h, r, "user_id", "@alice:example.test")
      } val)

class \nodoc\ iso _TestLogoutEndsTheSession is UnitTest
  """
  Answers `{}` and takes the token with it. That the token is really gone is
  asserted at the registry, where a second request can be made without a
  second connection — see `sessions/revoking one session spares the other`.
  """
  fun name(): String => "logout/a session can end itself"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/logout",
          "{}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("{}"), r)
      } val)

class \nodoc\ iso _TestLogoutWithoutATokenIsRefused is UnitTest
  fun name(): String => "logout/no token is M_MISSING_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/logout", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestLogoutRejectsAnUnknownToken is UnitTest
  """
  Not 200. A client that is told its logout succeeded will discard a token
  that in fact was never live, and stop being able to tell the difference.
  """
  fun name(): String => "logout/an unknown token is M_UNKNOWN_TOKEN"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post(
        "/_matrix/client/v3/logout",
        "{}",
        "Authorization: Bearer nosuchtoken\r\n"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_UNKNOWN_TOKEN")
      } val)

class \nodoc\ iso _TestDevicesRequiresAToken is UnitTest
  fun name(): String => "devices/listing without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Get("/_matrix/client/v3/devices"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestDevicesListsTheCallersDevice is UnitTest
  """
  One session, so the list holds exactly the device login handed back.
  """
  fun name(): String => "devices/a session sees its own device listed"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/devices",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("device_id"), r)
        h.assert_true(r.contains("devices"), r)
      } val)

class \nodoc\ iso _TestDeleteDevicesRequiresAToken is UnitTest
  fun name(): String => "devices/bulk delete without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/delete_devices", "{\"devices\":[]}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestDeleteDevicesAcceptsAList is UnitTest
  """
  An id nobody holds still succeeds: deleting a device that is already gone
  is the state the caller asked for.
  """
  fun name(): String => "devices/bulk delete of an absent device succeeds"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/delete_devices",
          "{\"devices\":[\"0123456789\"]}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
      } val)

class \nodoc\ iso _TestDeleteDevicesRefusesABadBody is UnitTest
  """
  The only new error vocabulary in this change, and it is reachable: a body
  with no `devices` array cannot be acted on.
  """
  fun name(): String => "devices/bulk delete refuses a body without devices"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/delete_devices",
          "{\"nope\":1}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_BAD_JSON")
      } val)
