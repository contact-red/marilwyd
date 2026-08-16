use "collections"
use "files"
use "json"
use "ssl/crypto"

primitive Pbkdf2Iterations
  """
  The PBKDF2-HMAC-SHA256 iteration count `hash-password` writes into new
  entries. OWASP's Password Storage Cheat Sheet gave this figure for this PRF
  as of August 2026.

  Entries carry their own count, so raising this does not invalidate them.
  """
  fun apply(): U32 => 600000

primitive Pbkdf2KeyLength
  """
  The derived key length. Every entry stores a hash of exactly this length —
  `_Entry` refuses any other — so it is also the length every comparison is
  made at.
  """
  fun apply(): USize => 32

primitive Pbkdf2MinIterations
  """
  The lowest iteration count an entry may carry.

  Entries carry their own count so the figure can be raised without
  invalidating them, which also means a low one is accepted unless something
  refuses it. An unstretched hash is a plausible typo, not a plausible
  intention.
  """
  fun apply(): U32 => 100000

primitive Pbkdf2SaltLength
  """
  The salt length `hash-password` writes, and the shortest `_Entry` accepts.
  """
  fun apply(): USize => 16

class val Credential
  """
  One local user's stored credential: enough to check a password, and nothing
  that could reconstruct one.

  The iteration count travels with the entry rather than being compiled in,
  so a file written today still verifies after the figure is raised.
  """
  let localpart: String
  let iterations: U32
  let salt: Array[U8] val
  let hash: Array[U8] val

  new val create(
    localpart': String,
    iterations': U32,
    salt': Array[U8] val,
    hash': Array[U8] val)
  =>
    localpart = localpart'
    iterations = iterations'
    salt = salt'
    hash = hash'

  fun val verify(password: String): Bool =>
    """
    Whether `password` derives this entry's hash, compared in time
    independent of where the two first differ.

    A derivation failure is a false, never an exception the caller might
    mistake for a match.
    """
    try
      // Derived at the fixed length, never at `hash.size()`: taking the
      // length from the stored value would let that value choose the width
      // of its own comparison, and an empty one would match everything.
      let derived =
        Pbkdf2Sha256(password, salt, iterations, Pbkdf2KeyLength())?
      ConstantTimeCompare(derived, hash)
    else
      false
    end

class val Credentials
  """
  Every local user, read once at startup and never changed. There is no
  registration endpoint, so this is the whole account list.
  """
  let _users: Map[String, Credential] val

  new val _create(users: Map[String, Credential] val) =>
    _users = users

  fun val apply(localpart: String): (Credential | None) =>
    """
    The credential for `localpart`, or `None` if there is no such user.

    Returning a union rather than raising lets the caller treat "no such
    user" and "wrong password" as one branch, which is what keeps the two
    responses identical.
    """
    try _users(localpart)? else None end

primitive ReadCredentials
  """
  Read and validate the credentials file.

  It holds derived hashes, never passwords. The file is still the
  offline-attack surface for every account: recovering a password from an
  entry costs a PBKDF2 search, and no more than that.
  """
  fun apply(path: FilePath): (Credentials | StartupError) =>
    """
    Parse the file, or name the entry that stopped it.
    """
    let text =
      match OpenFile(path)
      | let f: File =>
        let content = f.read_string(f.size())
        f.dispose()
        consume content
      else
        return StartupError(
          "credentials-unreadable",
          path.path + " cannot be read")
      end

    let doc =
      match JsonParser.parse(consume text)
      | let d: JsonObject => d
      | let e: JsonParseError =>
        return StartupError(
          "credentials-malformed",
          path.path + " is not valid JSON: "
            + e.message)
      else
        return StartupError(
          "credentials-malformed",
          path.path + " is not a JSON object")
      end

    let entries =
      try
        doc("users")? as JsonArray
      else
        return StartupError(
          "credentials-malformed",
          path.path + " has no \"users\" array")
      end

    let users = recover trn Map[String, Credential] end
    for (i, entry) in entries.pairs() do
      let where': String = path.path + " users[" + i.string() + "]"
      match \exhaustive\ _Entry(entry, where')
      | let c: Credential =>
        if users.contains(c.localpart) then
          return StartupError(
            "credentials-duplicate",
            where' + ": duplicate localpart " + c.localpart)
        end
        users(c.localpart) = c
      | let e: StartupError => return e
      end
    end

    if users.size() == 0 then
      return StartupError(
        "credentials-empty",
        path.path + " defines no users, so no one could"
          + " ever log in")
    end

    Credentials._create(consume users)

primitive _Entry
  """
  Turn one element of the `users` array into a `Credential`.
  """
  fun apply(entry: JsonValue, where': String): (Credential | StartupError) =>
    let o =
      match entry
      | let j: JsonObject => j
      else
        return StartupError(
          "credentials-malformed", where' + " is not an object")
      end

    let localpart =
      match \exhaustive\ _Field(o, "localpart", where')
      | let s: String => s
      | let e: StartupError => return e
      end

    match Localpart.check(localpart)
    | let e: String =>
      return StartupError("credentials-localpart", where' + ": " + e)
    end

    let algorithm =
      match \exhaustive\ _Field(o, "algorithm", where')
      | let s: String => s
      | let e: StartupError => return e
      end

    // Named in the file so a future entry can carry a different one and be
    // rejected rather than verified with the wrong primitive.
    if algorithm != "pbkdf2-sha256" then
      return StartupError(
        "credentials-algorithm",
        where' + ": unsupported algorithm " + algorithm)
    end

    // Range-checked before narrowing: `n.u32()` wraps silently, so a count
    // above 2^32 would become a small one and quietly unstretch the entry.
    let iterations =
      match o.get_or_else("iterations", None)
      | let n: I64
        if (n >= Pbkdf2MinIterations().i64())
          and (n <= I32.max_value().i64())
      =>
        n.u32()
      | let n: I64 =>
        return StartupError(
          "credentials-iterations",
          where' + ": iterations must be between "
            + Pbkdf2MinIterations().string() + " and "
            + I32.max_value().string() + ", not " + n.string())
      else
        return StartupError(
          "credentials-malformed",
          where' + ": iterations must be a number")
      end

    let salt =
      match \exhaustive\ _HexField(o, "salt", where')
      | let b: Array[U8] val => b
      | let e: StartupError => return e
      end

    if salt.size() < Pbkdf2SaltLength() then
      return StartupError(
        "credentials-salt-length",
        where' + ": salt must be at least " + Pbkdf2SaltLength().string()
          + " bytes, not " + salt.size().string())
    end

    let hash =
      match \exhaustive\ _HexField(o, "hash", where')
      | let b: Array[U8] val => b
      | let e: StartupError => return e
      end

    // The length matters, not just the encoding. A short hash is not a
    // rejected credential — `verify` would compare only that many bytes, so
    // a truncated paste silently becomes a prefix check and an empty one
    // matches every password.
    if hash.size() != Pbkdf2KeyLength() then
      return StartupError(
        "credentials-hash-length",
        where' + ": hash must be exactly " + Pbkdf2KeyLength().string()
          + " bytes, not " + hash.size().string()
          + " — was it truncated?")
    end

    Credential(
      localpart,
      iterations
      where salt' = salt, hash' = hash)

primitive _Field
  fun apply(o: JsonObject, name: String, where': String)
    : (String | StartupError)
  =>
    match o.get_or_else(name, None)
    | let s: String => s
    else
      StartupError(
        "credentials-malformed", where' + ": missing \"" + name + "\"")
    end

primitive _HexField
  fun apply(o: JsonObject, name: String, where': String)
    : (Array[U8] val | StartupError)
  =>
    match \exhaustive\ _Field(o, name, where')
    | let s: String =>
      match _FromHex(s)
      | let b: Array[U8] val => b
      else
        StartupError(
          "credentials-malformed",
          where' + ": \"" + name + "\" is not hex")
      end
    | let e: StartupError => e
    end

primitive _FromHex
  """
  Decode a hex string. `ssl/crypto` encodes with `ToHexString` and nothing
  in reach decodes.
  """
  fun apply(s: String): (Array[U8] val | None) =>
    if (s.size() % 2) != 0 then
      return None
    end
    recover val
      let out = Array[U8](s.size() / 2)
      var i: USize = 0
      while i < s.size() do
        let hi = try _nibble(s(i)?)? else return None end
        let lo = try _nibble(s(i + 1)?)? else return None end
        out.push((hi << 4) or lo)
        i = i + 2
      end
      out
    end

  fun _nibble(c: U8): U8 ? =>
    if (c >= '0') and (c <= '9') then
      c - '0'
    elseif (c >= 'a') and (c <= 'f') then
      (c - 'a') + 10
    elseif (c >= 'A') and (c <= 'F') then
      (c - 'A') + 10
    else
      error
    end
