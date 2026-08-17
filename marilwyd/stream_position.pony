use "ssl/crypto"

class val StreamEpoch is Stringable
  """
  Distinguishes this process's stream positions from a previous process's.

  Clients keep `next_batch` in durable storage and send it back as `since`.
  Nothing marilwyd holds survives a restart, so a position minted before
  one names events that no longer exist. Carrying the epoch makes that
  recognisable rather than indistinguishable from a position in this run —
  the difference between a client correctly resyncing and a client silently
  blind to every room.

  Random rather than a counter, for `MakeDeviceId`'s reason: nothing
  survives a restart to count from.
  """
  let _value: String

  new val _create(value: String) =>
    _value = value

  fun string(): String iso^ =>
    _value.clone()

  fun val matches(supplied: String): Bool =>
    _value == supplied

primitive MakeStreamEpoch
  """
  Mint the epoch this process stamps into every stream position.

  Minted once at startup, where a CSPRNG failure can still stop the
  process — an actor constructor cannot report one.
  """
  fun apply(): (StreamEpoch | NoSecureRandom) =>
    try
      StreamEpoch._create(ToHexString(RandBytes(8)?))
    else
      NoSecureRandom
    end

primitive StreamPositionText
  """
  Render a position as a client sees it: `s<epoch>_<index>`.

  The index counts events appended since this process started, across every
  room, so a client's position can move with nothing to show for it — the
  events were in rooms it is not in. That is ordinary Matrix, and it is why
  a position is one number rather than one per room.
  """
  fun apply(epoch: StreamEpoch, index: USize): String =>
    "s" + epoch.string() + "_" + index.string()

primitive ReadStreamPosition
  """
  The index a client's `since` names in this run, or `None` if it names
  none.

  `None` covers five cases a client cannot tell apart and which all need
  the same answer:

  * no `since` at all — a first sync;
  * one minted by a previous process, including the literal `"s0"` earlier
    marilwyd builds handed out;
  * text that is not a position;
  * an index this process has not reached, or has already discarded —
    both of which the device answers by sending what it still holds.

  Each means the client's position is unusable, and the honest reply to an
  unusable position is everything the client can currently see. There is
  deliberately no refusal: a `400` from `/sync` is a client recovery path
  marilwyd cannot drive today to check, and an initial sync is one every
  client takes on its first request anyway.
  """
  fun apply(supplied: (String | None), epoch: StreamEpoch)
    : (USize | None)
  =>
    let text =
      match supplied
      | let s: String => s
      else
        return None
      end

    // One `try` around the whole parse. Every failure inside it is a
    // position this process cannot honour, and they all get the same
    // answer, so distinguishing them would be work with no consumer.
    let index =
      try
        if text(0)? != 's' then
          return None
        end
        let body = text.substring(1)
        let split = body.find("_")?
        if not epoch.matches(body.substring(0, split)) then
          return None
        end
        body.substring(split + 1).usize(10)?
      else
        return None
      end

    index
