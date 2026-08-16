use "collections"
use "files"
use "json"
use "ssl/crypto"

primitive Pbkdf2Iterations
  """
  The PBKDF2-HMAC-SHA256 iteration count `hash-password` writes into new
  entries. OWASP's current figure for this PRF.

  Existing entries carry their own count, so raising this does not invalidate
  them; it applies to entries minted afterwards.
  """
  fun apply(): U32 => 600000

primitive Pbkdf2KeyLength
  """
  The derived key length `hash-password` writes into new entries. Existing
  entries verify against their own hash length.
  """
  fun apply(): USize => 32

class val Credential
  """
  What marilwyd knows about one local user: enough to check a password, and
  nothing that could reconstruct one.

  The parameters travel with the entry rather than being compiled in, so a
  credentials file written today still verifies after the iteration count is
  raised.
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
      let derived = Pbkdf2Sha256(password, salt, iterations, hash.size())?
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

  new val create(users: Map[String, Credential] val) =>
    _users = users

  fun val apply(localpart: String): (Credential | None) =>
    try _users(localpart)? else None end

  fun val size(): USize =>
    _users.size()

primitive ReadCredentials
  """
  Read and validate the credentials file.

  It holds derived hashes, never passwords, so marilwyd has nothing to leak
  even if the file is read: recovering a password from an entry costs a
  PBKDF2 search.
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
          "--credentials " + path.path + " cannot be read")
      end

    let doc =
      match JsonParser.parse(consume text)
      | let d: JsonObject => d
      | let e: JsonParseError =>
        return StartupError(
          "credentials-malformed",
          "--credentials " + path.path + " is not valid JSON: "
            + e.message)
      else
        return StartupError(
          "credentials-malformed",
          "--credentials " + path.path + " is not a JSON object")
      end

    let entries =
      try
        doc("users")? as JsonArray
      else
        return StartupError(
          "credentials-malformed",
          "--credentials " + path.path + " has no \"users\" array")
      end

    let users = recover trn Map[String, Credential] end
    for (i, entry) in entries.pairs() do
      let where': String = path.path + " users[" + i.string() + "]"
      match _Entry(entry, where')
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
        "--credentials " + path.path + " defines no users, so no one could"
          + " ever log in")
    end

    Credentials(consume users)

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
      match _Field(o, "localpart", where')
      | let s: String => s
      | let e: StartupError => return e
      end

    let algorithm =
      match _Field(o, "algorithm", where')
      | let s: String => s
      | let e: StartupError => return e
      end

    // Named in the file so a future entry can carry a different one and be
    // rejected loudly rather than verified with the wrong primitive.
    if algorithm != "pbkdf2-sha256" then
      return StartupError(
        "credentials-algorithm",
        where' + ": unsupported algorithm " + algorithm)
    end

    let iterations =
      match o.get_or_else("iterations", None)
      | let n: I64 if n > 0 => n.u32()
      else
        return StartupError(
          "credentials-malformed", where' + ": iterations must be a positive"
            + " number")
      end

    let salt =
      match _HexField(o, "salt", where')
      | let b: Array[U8] val => b
      | let e: StartupError => return e
      end

    let hash =
      match _HexField(o, "hash", where')
      | let b: Array[U8] val => b
      | let e: StartupError => return e
      end

    Credential(localpart, iterations, salt, hash)

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
    match _Field(o, name, where')
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
  Decode a hex string. `ssl/crypto` encodes with `ToHexString`; nothing in the
  stdlib or in `ssl` decodes, and the credentials file is the only place
  marilwyd needs to.
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
