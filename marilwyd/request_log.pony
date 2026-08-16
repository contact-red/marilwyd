use hobby = "hobby"
use stallion = "stallion"

class val _LogRequest is hobby.RequestInterceptor
  """
  Print every request as it arrives.

  Arrival and completion are logged separately, by this and by
  `_LogResponse`, so that a request which never completes is visible as a
  `-->` line with no `<--` after it.

  That is no longer sufficient on its own to spot a hang. `/sync` holds a
  request open for up to `MaxSyncWait()`, so one unmatched `-->` per
  signed-in client is the healthy resting state, and a hung `/sync` looks
  exactly like a waiting one until the wait has been exceeded. Read the
  gap, not the absence: a matched pair 25 seconds apart is `/sync` working.

  The path is logged and the query string never is. Matrix permits
  `?access_token=` in a query string, and `URI` keeps the two in separate
  fields, so a token cannot reach the log by being part of the string that
  is logged.
  """
  let _out: OutStream tag

  new val create(out: OutStream tag) =>
    _out = out

  fun apply(request: stallion.Request box): hobby.InterceptResult =>
    _out.print("--> " + request.method.string() + " " + request.uri.path)
    hobby.InterceptPass

class val _LogResponse is hobby.ResponseInterceptor
  """
  Print every response as it goes to the wire.

  Runs for streamed responses too, where it can only observe — which is all
  logging needs.
  """
  let _out: OutStream tag

  new val create(out: OutStream tag) =>
    _out = out

  fun apply(ctx: hobby.ResponseContext ref) =>
    _out.print(
      "<-- " + ctx.status().code().string() + " "
        + ctx.request().method.string() + " " + ctx.request().uri.path)
