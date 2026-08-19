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
