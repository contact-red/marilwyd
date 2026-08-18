use "json"

primitive _JSONDeeperThan
  """
  Whether a body nests deeper than a limit, decided before anything is
  built from it.

  A pre-pass rather than a limit on the parse itself: ponyc 0.68.0's
  `JsonParser` takes no limits, and its streaming counterpart can be
  stopped mid-document. The document is walked twice as a result, which is
  microseconds against what any of the callers go on to do.

  Malformed JSON is not this primitive's business — it answers `false` for
  anything merely unparseable and lets each caller's tree parse produce the
  refusal, so there is one place that decides what a bad document means.
  """
  fun apply(body: Array[U8] val, limit: USize): Bool =>
    let counted: _JSONDepth ref = _JSONDepth(limit)
    let parser = JsonTokenParser(counted)
    try
      parser.parse(String.from_array(body))?
    end
    counted.exceeded

class ref _JSONDepth is JsonTokenNotify
  """
  Counts how deep a document nests, and stops the parser once it is past
  the limit it was given.

  Aborting matters as much as counting: without it a body would be walked
  to its end to discover something already known at the limit, which is the
  work the limit exists to refuse.
  """
  let _limit: USize
  var _depth: USize = 0
  var exceeded: Bool = false

  new ref create(limit: USize) =>
    _limit = limit

  fun ref apply(parser: JsonTokenParser, token: JsonToken) =>
    match token
    | JsonTokenObjectStart | JsonTokenArrayStart =>
      _depth = _depth + 1
      if _depth > _limit then
        exceeded = true
        parser.abort()
      end
    | JsonTokenObjectEnd | JsonTokenArrayEnd =>
      if _depth > 0 then
        _depth = _depth - 1
      end
    end
