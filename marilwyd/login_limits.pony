use "json"

primitive MaxLoginBody
  """
  The largest login request body marilwyd will read, in bytes.

  Far below the server-wide limit, because a login body is a handful of
  short fields and nothing legitimate approaches this. It is low for a
  reason beyond tidiness: `JsonParser` allocates a container frame per
  level of nesting, so the cost of parsing a body is proportional to its
  size, and this endpoint is reachable without a credential.

  Measured on the shipped binary: 100 concurrent 64 kB nested bodies took
  RSS from 9 MB to 200 MB over three rounds. The same load at this limit
  reached 32 MB.
  """
  fun apply(): USize => 4096

primitive MaxLoginDepth
  """
  The deepest login request body marilwyd will read.

  The size limit bounds the cost of one body; this bounds its shape. A
  well-formed login nests three levels — the object, its `identifier`, and
  that object's values — so this is generous by an order of magnitude while
  making the frame count independent of how the bytes are spent.
  """
  fun apply(): USize => 16

primitive LoginBodyTooLarge
  """
  A login body longer than `MaxLoginBody()`.
  """
  fun message(): String =>
    "Request body is larger than a login can be"

primitive LoginBodyTooDeep
  """
  A login body nested deeper than `MaxLoginDepth()`, whatever its length.
  """
  fun message(): String =>
    "Request body is nested more deeply than a login can be"

primitive CheckLoginShape
  """
  Refuse a login body that is too large or too deeply nested, before the
  parser builds anything from it.

  The depth half is `_JSONDeeperThan`, which `_ObjectBody` applies to
  every other body marilwyd reads. Login does not go through
  `_ObjectBody`, because it is refused before anything is parsed at all
  and answers its own two refusals rather than one. The document is walked
  twice as a result, which costs microseconds against a login's 380 ms key
  derivation.

  Malformed JSON is not this primitive's business — it answers `None` for
  anything that is merely unparseable and lets the tree parser produce the
  refusal, so there is one place that decides what `M_NOT_JSON` means.
  """
  fun apply(body: Array[U8] val)
    : (LoginBodyTooLarge | LoginBodyTooDeep | None)
  =>
    """
    Answer what is wrong with `body`'s size or shape, or `None` when there
    is nothing wrong with either.
    """
    if body.size() > MaxLoginBody() then
      return LoginBodyTooLarge
    end

    if _JSONDeeperThan(body, MaxLoginDepth()) then
      LoginBodyTooDeep
    end

primitive MaxBodyDepth
  """
  How deeply any request body may nest, whatever else bounds it.

  A backstop rather than a per-endpoint rule: the endpoints that know
  what shape they expect state something tighter — `MaxEventDepth` and
  `MaxCreateDepth` are both eight — and this is what applies to the ones
  that only know they are reading an object.

  It exists because the byte bound is not the shape bound. Sixty-four
  kilobytes of `[[[[` is a legal document a few characters wide and
  thousands of levels deep, and it is the parser's recursion that costs,
  not the length: `SECURITY.md` measures 9 MB of that shape reaching
  200 MB resident on the one path that was checked.
  """
  fun apply(): USize => 16

primitive _ObjectBody
  """
  Read a request body as a JSON object, bounded first.

  The one place a body becomes an object, so that a new endpoint gets the
  bounds by reading its body rather than by remembering to. They were
  missed on eleven endpoints while a docstring said every one of them was
  covered — which is the kind of claim that stops the next person
  checking.

  Size before depth before parse, in that order, because each is cheaper
  than the next and the whole point is to refuse before the parser builds
  anything.

  Answers `None` for all three failures. A caller that wants to tell them
  apart — as `_EventContent` does, which is why it does not use this —
  has to, because a single message for several causes tells a client
  nothing it can act on.
  """
  fun apply(
    body: Array[U8] val,
    max_bytes: USize,
    max_depth: USize = MaxBodyDepth())
    : (JsonObject | None)
  =>
    if body.size() > max_bytes then
      return None
    end
    if _JSONDeeperThan(body, max_depth) then
      return None
    end
    match JsonParser.parse(String.from_array(body))
    | let o: JsonObject => o
    end
