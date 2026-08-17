use "time"
use hobby = "hobby"
use stallion = "stallion"
use uri = "uri"

primitive MaxSyncWait
  """
  The longest marilwyd will hold a `/sync` open, in milliseconds.

  Five seconds under `hobby.DefaultHandlerTimeout()`. hobby answers **504
  Gateway Timeout** and disposes the handler once one has been idle that
  long, and a 504 carries no `errcode`, so a client cannot tell it from a
  transport failure — measured against Element 1.12.25, a server that lets
  the watchdog win puts the client into a permanent
  `SYNCING`/`RECONNECTING` flap.

  Answering early is free and raising hobby's timeout is not: that setting
  is `Server`-level and shared with `ServeFiles`, where it is the only
  thing that closes a connection whose client has stopped reading.

  Element asks for 30,000. It gets 25,000 and re-asks; measured at 25.001 s
  per cycle across a real session. The margin is also the whole latency
  budget for `SessionRegistry.resolve`, because hobby starts its watchdog
  at dispatch while this deadline starts only after the token resolves.
  """
  fun apply(): U64 => 25_000

primitive MalformedSyncTimeout
  """
  A `timeout` query parameter that is not a whole number of milliseconds.
  """
  fun message(): String =>
    "timeout must be a whole number of milliseconds"

primitive UndecodableQuery
  """
  A query string that is not valid percent-encoding.

  Separate from `MalformedSyncTimeout` because the two reach a client for
  different reasons and only one of them is about `timeout`: a query
  decodes whole or not at all, so `?timeout=25000&filter=%ZZ` fails here
  with a perfectly good `timeout`.
  """
  fun message(): String =>
    "query string is not valid percent-encoding"

primitive SyncWait
  """
  How long to hold a `/sync` open, from the request's query string.

  Absent means zero — the specification's default, and what Element sends
  on its first sync and on every sync while it is reconnecting.

  A malformed value is refused rather than defaulted. Defaulting looks
  harmless and is not: zero is the one value that makes a client re-ask
  immediately, so a silent fallback turns one bad parameter into a request
  flood. `?timeout=25000&filter=%ZZ` is enough, because a query string
  either decodes whole or not at all.
  """
  fun apply(query: (String | None))
    : (U64 | MalformedSyncTimeout | UndecodableQuery)
  =>
    let params =
      match query
      | let q: String =>
        match \exhaustive\ uri.ParseQueryParameters(q)
        | let p: uri.QueryParams val => p
        | let _: uri.InvalidPercentEncoding val => return UndecodableQuery
        end
      else
        return 0
      end

    match params.get("timeout")
    | let requested: String =>
      try
        // Base 10 explicitly: the default auto-detects prefixes, and
        // `0x1e` is not a number of milliseconds anyone meant to send.
        // Underscore separators are still accepted (`1_000` is 1000),
        // which is harmless for a duration.
        let ms = requested.u64(10)?
        // Clamped before any caller multiplies it out to nanoseconds, so
        // that multiply cannot overflow.
        ms.min(MaxSyncWait())
      else
        MalformedSyncTimeout
      end
    else
      0
    end

class val _Sync
  """
  `GET /_matrix/client/v3/sync`.

  There are no rooms and no events, so every answer is the same document.
  What the endpoint does instead is hold the request open for as long as
  the client asked, which is the only thing that stops a client re-asking
  the instant it is answered — measured at 36 syncs a second against
  Element 1.12.25 when the answer is immediate.

  One `Timers` per `_Sync`, and `Routes` builds one `_Sync` per call — so
  one per server, not one per process, and nothing disposes it. hobby's own
  `Server` keeps a second wheel for its handler watchdog, so a held sync is
  timed by two independent ones.
  """
  let _sessions: SessionRegistry tag
  let _timers: Timers tag = Timers

  new val create(sessions: SessionRegistry tag) =>
    _sessions = sessions

  fun apply(ctx: hobby.HandlerContext iso)
    : (hobby.HandlerReceiver tag | None)
  =>
    _SyncHandler(consume ctx, _sessions, _timers)

actor _SyncHandler is (hobby.HandlerReceiver & UserReceiver)
  """
  Waits out one client's `/sync`, then answers it.

  Answering at most once is not this actor's job: `hobby.RequestHandler`
  makes `respond_with_headers` idempotent, and the connection drops a
  response whose request has already finished. So a late deadline is inert
  rather than wrong, and only one ordering needs a guard — `dispose`
  arriving before `token_resolved`, where arming a deadline would keep this
  actor, its request and its connection alive for the whole wait after the
  socket had already gone.

  The token is checked before anything else happens, so an unauthenticated
  caller can neither park a timer nor make marilwyd parse a query string.
  """
  embed _handler: hobby.RequestHandler
  let _timers: Timers tag
  let _query: (String | None)
  var _timer: (Timer tag | None) = None
  var _disposed: Bool = false

  new create(
    ctx: hobby.HandlerContext iso,
    sessions: SessionRegistry tag,
    timers: Timers tag)
  =>
    let supplied = _BearerToken(ctx.request)
    // Captured raw and parsed only after the token resolves. Parsing here
    // would let an unauthenticated caller drive a full percent-decode.
    _query = ctx.request.uri.query
    _timers = timers
    _handler = hobby.RequestHandler(consume ctx)

    match supplied
    | let t: String => sessions.resolve(t, this)
    else
      _respond(stallion.StatusUnauthorized, MissingToken())
    end

  be token_resolved(user_id: String) =>
    // `dispose` can arrive before this: a client that connects, sends, and
    // resets gets its connection torn down while the registry is still
    // being asked. Without this check the handler would arm a deadline for
    // a connection that has gone, and hold itself, its `Request` and the
    // `_Connection` actor alive for the whole wait — while lori has
    // already released the socket and the accept slot that would otherwise
    // account for it.
    if _disposed then
      return
    end

    match \exhaustive\ SyncWait(_query)
    | let ms: U64 =>
      if ms == 0 then
        _answer()
      else
        _arm(ms)
      end
    | MalformedSyncTimeout => _refuse(MalformedSyncTimeout.message())
    | UndecodableQuery => _refuse(UndecodableQuery.message())
    end

  be token_rejected() =>
    _respond(stallion.StatusUnauthorized, UnknownToken())

  be waited() =>
    _timer = None
    _answer()

  be dispose() =>
    _disposed = true
    _cancel()

  be throttled() => None
  be unthrottled() => None

  fun ref _arm(ms: U64) =>
    let timer = Timer(_SyncDeadline(this), ms * 1_000_000)
    // Aliased as `tag` before the `iso` is consumed, so the handle stays
    // usable for the cancel.
    let handle: Timer tag = timer
    _timer = handle
    _timers(consume timer)

  fun ref _answer() =>
    _handler.respond_with_headers(
      stallion.StatusOK, _JSONHeaders(), EmptySync())

  fun ref _refuse(why: String) =>
    _respond(
      stallion.StatusBadRequest, MatrixError("M_INVALID_PARAM", why))

  fun ref _respond(status: stallion.Status, body: String) =>
    _cancel()
    _handler.respond_with_headers(status, _JSONHeaders(), body)

  fun ref _cancel() =>
    // Destructive read, so cancelling twice is safe and a cancel with
    // nothing armed does nothing.
    match _timer = None
    | let t: Timer tag => _timers.cancel(t)
    end

class iso _SyncDeadline is TimerNotify
  """
  Wakes one waiting `/sync`, once.

  `apply` returns false so the deadline is never rescheduled whatever
  interval it was built with: a rescheduled deadline would be trying to
  answer a request that is already finished.
  """
  let _handler: _SyncHandler tag

  new iso create(handler: _SyncHandler tag) =>
    _handler = handler

  fun ref apply(timer: Timer, count: U64): Bool =>
    _handler.waited()
    false
