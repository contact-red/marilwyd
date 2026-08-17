use "ssl/crypto"

class val AccessToken
  """
  A Matrix access token.

  Deliberately not `Stringable`, and with no `string()`: a token cannot reach
  a log line, an error message, or a string concatenation by accident,
  because none of those compile. `reveal` is the one way out.

  Build one with `MakeAccessToken`.
  """
  let _value: String

  new val _create(value: String) =>
    _value = value

  fun val reveal(): String =>
    """
    Hand the token to something that must transmit it. Every call is a
    disclosure, which is what makes grepping for this method worth doing.
    """
    _value

  fun val matches(supplied: String): Bool =>
    """
    Compare against a token a caller supplied, in time independent of where
    the two first differ.
    """
    ConstantTimeCompare(_value, supplied)

primitive MakeAccessToken
  """
  Mint an access token from the CSPRNG.
  """
  fun apply(): (AccessToken | NoSecureRandom) =>
    """
    256 bits of hex. `RandBytes` fails rather than returning weak output when
    the CSPRNG cannot produce secure bytes, so this reports that instead of
    minting a guessable token.
    """
    try
      AccessToken._create(ToHexString(RandBytes(32)?))
    else
      NoSecureRandom
    end

primitive NoSecureRandom
  """
  The CSPRNG could not produce secure bytes. Every caller must fail closed:
  there is no acceptable fallback for a credential.
  """
  fun string(): String =>
    "the system CSPRNG is unavailable, so no token could be issued"
