use "ssl/crypto"

class val DeviceId is Stringable
  """
  A Matrix device identifier — one client of one account.

  A public label, and deliberately `Stringable`: it travels in login
  responses, in `whoami`, and in the events a client sends. That is the
  opposite of `AccessToken`, which has no `string()` precisely so it cannot
  reach a log line by accident.

  What the type buys is that it cannot be confused with a user id.
  `SessionRegistry.resolve` answers with both, they are both text, and they
  arrive at every handler side by side; as plain `String`s nothing but
  parameter order would keep them apart.

  Build one with `MakeDeviceId`.
  """
  let _value: String

  new val _create(value: String) =>
    _value = value

  fun string(): String iso^ =>
    _value.clone()

  fun val matches(supplied: String): Bool =>
    """
    Compare against an identifier a caller supplied — a path parameter, or
    a device named in a request body.

    Ordinary equality, not `ConstantTimeCompare`. A device id is a public
    label, so there is nothing here for a timing difference to disclose
    that the client did not already have.
    """
    _value == supplied

primitive MakeDeviceId
  """
  Mint a device identifier from the CSPRNG.

  Random rather than sequential: a counter would tell any client how many
  sessions the server has issued, and would collide across restarts, since
  nothing about a session survives one.
  """
  fun apply(): (DeviceId | NoSecureRandom) =>
    try
      DeviceId._create(ToHexString(RandBytes(5)?))
    else
      NoSecureRandom
    end
