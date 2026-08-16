use "ssl/crypto"

primitive _Decoy
  """
  A credential that belongs to nobody, derived against when the requested
  user does not exist.

  Login answers "no such user" and "wrong password" with the same bytes. That
  is only half the property: without this, the two paths also differ by the
  entire cost of the key derivation, which is the difference between a
  request that returns in under a millisecond and one that takes several
  hundred. Anyone can time that.

  The parameters match what `hash-password` writes, so the decoy costs what a
  real verification costs.
  """
  fun verify(password: String) =>
    """
    Burn a derivation and discard it.
    """
    try
      // The salt is fixed and public: a decoy has no secret to protect, and
      // its only job is to take the same time as the real thing.
      Pbkdf2Sha256(
        password,
        "marilwyd decoy salt",
        Pbkdf2Iterations(),
        Pbkdf2KeyLength())?
    end
