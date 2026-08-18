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

  The depth half is `_JSONDeeperThan`, which every body-reading endpoint
  now shares. The document is walked twice as a result, which costs
  microseconds against a login's 380 ms key derivation.

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
