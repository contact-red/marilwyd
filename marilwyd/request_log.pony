use hobby = "hobby"
use stallion = "stallion"

class val _LogRequest is hobby.RequestInterceptor
  """
  Print every request as it arrives.

  Arrival and completion are logged separately, by this and by
  `_LogResponse`, because a request that never completes is exactly what a
  hang looks like: a `-->` line with no `<--` after it names the request
  that stopped.

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
