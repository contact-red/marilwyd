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
    | MalformedSyncTimeout => None
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
        "cap " + MaxSyncWait().string()
          + " must stay under hobby's " + watchdog().string())
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
    | MalformedSyncTimeout =>
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
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("next_batch"), r)
      } val)

class \nodoc\ iso _TestSyncHoldsForTheRequestedTimeout is UnitTest
  """
  The one test that proves the endpoint actually waits. A short timeout
  rather than the cap: the cap is asserted against hobby's constant in
  `_TestMaxSyncWaitIsUnderTheWatchdog`, which needs no wall-clock at all.
  """
  fun name(): String => "sync/a timeout is held before answering"

  fun apply(h: TestHelper) =>
    let started = Time.nanos()
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/sync?timeout=1500",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r)(started) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        let held = (Time.nanos() - started) / 1_000_000
        // Well under 1500 so a slow login cannot make this flap, but far
        // enough above zero to fail if the wait were skipped entirely.
        h.assert_true(
          held >= 1_200, "answered after " + held.string() + " ms")
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
      {(r) =>
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
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("underride"), r)
      } val)

class \nodoc\ iso _TestFilterCreateReturnsAnID is UnitTest
  fun name(): String => "filter/creating one returns a filter_id"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        "POST /_matrix/client/v3/user/%40alice%3Aexample.test/filter"
          + " HTTP/1.1\r\nHost: example.test\r\n"
          + "Authorization: Bearer " + token + "\r\n"
          + "Content-Length: 2\r\nContent-Type: application/json\r\n"
          + "Connection: close\r\n\r\n{}"
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("filter_id"), r)
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
      _Post("/_matrix/client/v3/keys/query", "{}"),
      {(r) =>
        h.assert_false(r.contains("Method Not Allowed"), r)
        _AssertErrcode(h, r, "M_UNRECOGNIZED")
      } val)
