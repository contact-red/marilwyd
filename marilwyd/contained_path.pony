use hobby = "hobby"
use stallion = "stallion"
use uri = "uri"

class val _ContainedPath is hobby.RequestInterceptor
  """
  Refuse any request whose path walks upward, before it reaches a handler.

  `hobby.ServeFiles` hands the wildcard remainder to `FilePath.from`, whose
  whole job is to keep the result inside the root — and whose containment
  check, up to and including ponyc 0.68.0, is a bare string-prefix test
  with no separator boundary. `Path.join` resolves `..` first, so with an asset
  root of `/srv/element` a request for `/element/../element-config/x`
  produces `/srv/element-config/x`, which begins with `/srv/element` and is
  therefore accepted. Any sibling directory whose name extends the root's
  is readable by anyone who can reach the socket, with no credential.

  ponyc 0.69.1 fixes it. This stays anyway, and not only out of caution:
  the source compiles on an older ponyc, and nothing in the build refuses
  to. Whether the binary in front of you is safe would otherwise be a
  question about which compiler built it, answerable only by asking, and
  a server that reads files out of a directory should be able to say for
  itself that it does not leave one.

  One interceptor rather than a check on each mount. There are two asset
  mounts today; a third would be added by somebody who had no reason to
  know this, and this way there is nothing for them to remember.

  The bug is also in a transitive property of a dependency's dependency —
  marilwyd calls neither `ServeFiles` nor `FilePath.from` directly — which
  is the kind of thing that changes without anyone here noticing.
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
