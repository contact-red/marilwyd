use hobby = "hobby"
use stallion = "stallion"
use uri = "uri"

class val _ContainedPath is hobby.RequestInterceptor
  """
  Refuse any request whose path walks upward, before it reaches a handler.

  Belt and braces. `hobby.ServeFiles` resolves every path through
  `FilePath.from`, which contains the result inside `--asset-root` — but
  that is a property of a dependency's dependency, and marilwyd calls
  neither of them itself. A server that reads files out of a directory
  should be able to say for itself that it does not leave one.

  One interceptor rather than a check on each mount. There are two asset
  mounts today; a third would be added by somebody who had no reason to
  know about any of this, and this way there is nothing for them to
  remember.
  """
  fun apply(request: stallion.Request box): hobby.InterceptResult =>
    if _Upward(request.uri.path) then
      // 400 and not 404: the request is malformed rather than aimed at
      // something absent, and answering "not found" would invite the
      // caller to keep guessing at names.
      hobby.InterceptRespond(stallion.StatusBadRequest, "Bad Request")
    else
      hobby.InterceptPass
    end

primitive _Upward
  """
  Whether a path contains a `..` segment.

  Segments, not a substring: a file honestly named `..config` contains the
  two characters and goes nowhere near its parent, and refusing it would
  be a bug of a quieter kind. The separator is `/` because this is a URL
  path and not a filesystem one — it has not been decoded, and nothing
  between the socket and `FilePath.from` decodes it, so `%2e%2e` arrives
  as those six characters and names a directory rather than a parent.
  """
  fun apply(path: String): Bool =>
    for segment in path.split("/").values() do
      if segment == ".." then
        return true
      end
    end
    false
