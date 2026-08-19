use "ssl/crypto"

class val RoomId is Stringable
  """
  A Matrix room identifier — `!opaque:server_name`.

  Its own type for the reason `DeviceId` gives: a room id, an event id and
  a user id are all text, and they arrive at handlers side by side where
  nothing but parameter order would keep them apart.

  **It is also a capability.** Anyone who knows a room id can join the room
  — there are no invitations — so an id is closer to a bearer token than to
  a label, and `SECURITY.md` records what follows from that. It is
  `Stringable` regardless, because a client must be told its own room ids
  and a server that could not print one would be useless; what marilwyd
  does instead is decline to write them to the request log.
  """
  let _value: String

  new val _create(value: String) =>
    _value = value

  fun string(): String iso^ =>
    _value.clone()

  fun val matches(supplied: String): Bool =>
    """
    Compare against an identifier a caller supplied.

    Ordinary equality, not `ConstantTimeCompare`. A constant-time match
    would have to compare against every room rather than look one up, which
    is the cost the registry's whole shape exists to avoid — and the
    protection a room id offers is its 128 bits of entropy, not the
    indistinguishability of a failed comparison.
    """
    _value == supplied

primitive MakeRoomId
  """
  Mint a room identifier from the CSPRNG.

  Sixteen bytes rather than `MakeDeviceId`'s five. A device id labels a
  session within an account that is already authenticated; a room id is the
  entire barrier between one room's traffic and a stranger guessing at it,
  so it is sized like the secret it functions as.
  """
  fun apply(server_name: String): (RoomId | NoSecureRandom) =>
    try
      RoomId._create("!" + ToHexString(RandBytes(16)?) + ":" + server_name)
    else
      NoSecureRandom
    end

primitive RoomIds
  """
  Read a room id an operator declared, or say it is not one.

  Only the shape marilwyd itself mints — `!` then 32 hex characters, then
  this server's name. Narrower than Matrix allows, and deliberately: a
  declared id that this server could not have produced names a room that
  cannot exist here, and accepting it would mean a room whose id nothing
  else in the process agrees with.
  """
  fun apply(text: String, server_name: String): (RoomId | None) =>
    """
    The room id this text names, or `None` when it names none.
    """
    let colon =
      try
        text.find(":")?
      else
        return None
      end

    let named: String = text.substring(colon + 1)
    if named != server_name then
      return None
    end

    let opaque: String = text.substring(1, colon)
    try
      if text(0)? != '!' then
        return None
      end
    else
      return None
    end

    if opaque.size() != 32 then
      return None
    end
    for c in opaque.values() do
      let hex =
        ((c >= '0') and (c <= '9')) or ((c >= 'a') and (c <= 'f'))
      if not hex then
        return None
      end
    end

    RoomId._create(text.clone())
