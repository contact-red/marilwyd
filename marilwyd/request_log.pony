use "time"
use hobby = "hobby"
use stallion = "stallion"

primitive _LogClock
  """
  Seconds since the server was built, to millisecond precision.

  A stamp on every line, because the interesting quantity in this log is
  now a duration rather than an order. `/sync` holds a request open, so
  telling a healthy hold from a hung one means measuring the gap between a
  `-->` and its `<--`, and that cannot be done from the sequence alone.

  Elapsed rather than wall-clock: it needs no date handling, it cannot go
  backwards, and it is what the numbers in `docs/next-increment.md` are.
  """
  fun stamp(start: U64): String =>
    let ms = (Time.nanos() - start) / 1_000_000
    // Annotated, because `string()` hands back an `iso` that cannot be
    // concatenated until it is aliased.
    let seconds: String = (ms / 1000).string()
    let millis: String = (ms % 1000).string()
    let pad = "000".substring(0, 3 - millis.size().isize())
    "[" + seconds + "." + consume pad + millis + "] "

class val _LogRequest is hobby.RequestInterceptor
  """
  Print every request as it arrives.

  Arrival and completion are logged separately, by this and by
  `_LogResponse`, so that a request which never completes is visible as a
  `-->` line with no `<--` after it.

  Absence alone no longer means a hang. `/sync` holds a request open for up
  to `MaxSyncWait()`, so one unmatched `-->` per signed-in client is the
  healthy resting state. Read the stamps: a pair that closes after about
  twenty-five seconds is `/sync` working, and a `-->` older than that with
  nothing after it is not. A client that disconnects mid-hold also leaves
  its `-->` unmatched forever, because nothing is sent and no response
  interceptor runs.

  The path is logged and the query string never is. Matrix permits
  `?access_token=` in a query string, and `URI` keeps the two in separate
  fields, so a token cannot reach the log by being part of the string that
  is logged.
  """
  let _out: OutStream tag
  let _start: U64

  new val create(out: OutStream tag, start: U64) =>
    _out = out
    _start = start

  fun apply(request: stallion.Request box): hobby.InterceptResult =>
    _out.print(
      _LogClock.stamp(_start) + "--> " + request.method.string() + " " +
        request.uri.path)
    hobby.InterceptPass

class val _LogResponse is hobby.ResponseInterceptor
  """
  Print every response as it goes to the wire.

  Runs for streamed responses too, where it can only observe — which is all
  logging needs. It does not run for a response stallion builds below hobby,
  so an oversized body's `413` reaches the client unlogged.
  """
  let _out: OutStream tag
  let _start: U64

  new val create(out: OutStream tag, start: U64) =>
    _out = out
    _start = start

  fun apply(ctx: hobby.ResponseContext ref) =>
    _out.print(
      _LogClock.stamp(_start) + "<-- " + ctx.status().code().string() + " " +
        ctx.request().method.string() + " " + ctx.request().uri.path)
