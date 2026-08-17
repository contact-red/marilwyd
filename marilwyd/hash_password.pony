use "ssl/crypto"

actor HashPassword
  """
  Read a password from stdin and print the credentials entry for it, as a
  YAML sequence element ready to paste under `users:`.

  The password is read from stdin rather than taken as an argument, so it
  never reaches the process table or shell history:

  ```
  read -rs PASSWORD
  printf '%s' "$PASSWORD" | marilwyd hash-password alice
  ```

  marilwyd writes only the derived hash; recovering the password from that
  output costs a PBKDF2 search. Sharing `Pbkdf2Sha256` and its parameters
  with `Credential.verify` is the reason this lives in the same binary — a
  generator that can drift from its verifier eventually will.
  """
  let _env: Env
  let _localpart: String
  var _password: String iso = recover iso String end

  new create(env: Env, localpart: String) =>
    _env = env
    _localpart = localpart

    let self: HashPassword tag = this
    env.input(
      recover iso
        object is InputNotify
          fun ref apply(data: Array[U8] iso) =>
            self.read(consume data)

          fun ref dispose() =>
            self.finish()
        end
      end,
      512)

  be read(data: Array[U8] iso) =>
    _password.append(consume data)

  be finish() =>
    """
    stdin closed: derive the hash and print the entry.
    """
    // A trailing newline is what a terminal adds, not part of the password.
    let password: String val = _password = recover iso String end
    let trimmed = _Chomp(consume password)

    if trimmed.size() == 0 then
      _env.err.print("marilwyd: empty password refused")
      _env.exitcode(1)
      return
    end

    (let salt, let hash) =
      try
        let s = RandBytes(16)?
        (s, Pbkdf2Sha256(trimmed, s, Pbkdf2Iterations(), Pbkdf2KeyLength())?)
      else
        _env.err.print("marilwyd: " + NoSecureRandom.string())
        _env.exitcode(1)
        return
      end

    // A sequence element, so the output pastes straight under `users:`
    // in a credentials file. Salt and hash are quoted: `yaml` would keep
    // an unquoted hex string as text anyway, but a reader looking at the
    // file should not have to know that to trust it.
    _env.out.print("  - localpart: " + _localpart)
    _env.out.print("    algorithm: pbkdf2-sha256")
    _env.out.print("    iterations: " + Pbkdf2Iterations().string())
    _env.out.print("    salt: \"" + ToHexString(salt) + "\"")
    _env.out.print("    hash: \"" + ToHexString(hash) + "\"")

primitive _Chomp
  """
  Drop one trailing newline, and a carriage return before it.
  """
  fun apply(s: String): String =>
    var end': USize = s.size()
    try
      if (end' > 0) and (s(end' - 1)? == '\n') then
        end' = end' - 1
        if (end' > 0) and (s(end' - 1)? == '\r') then
          end' = end' - 1
        end
      end
    end
    s.trim(0, end')
