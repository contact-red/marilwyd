use "collections"
use "files"
use "ssl/crypto"
use "yaml"

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

  Parsing and shape are the `yaml` package's; what a value has to *be* is
  marilwyd's, and stays here. The split is deliberate — the library reports
  a missing key or a number that will not fit a `U32` better than hand
  -written code did, and has no opinion on what an iteration count is for.
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

    // Bounded well below the defaults. This document is a flat list of
    // five-field entries, so nothing legitimate approaches either figure,
    // and the file is read before anything else runs.
    let raw =
      match \exhaustive\ YamlLoad[Array[_RawEntry] val](
        consume text,
        {(c) => c("users").sequence[_RawEntry](_RawEntryOf) }
        where max_depth = 8, max_nodes = 100_000)
      | let entries: Array[_RawEntry] val => entries
      | let f: YamlFailure =>
        // Safe to render: no node type in `yaml` is `Stringable` and its
        // errors carry no document bytes, so this cannot spill a hash into
        // a startup message.
        return StartupError(
          "credentials-malformed", path.path + ": " + f.string())
      end

    let users = recover trn Map[String, Credential] end
    for (i, entry) in raw.pairs() do
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
        path.path + " defines no users, so no one could" +
          " ever log in")
    end

    Credentials._create(consume users)

class val _RawEntry
  """
  One entry as the file spells it, before marilwyd decides whether it is a
  credential.

  Every field is the text or number that was there. Nothing here is
  validated, which is the point: binding and judging are separate passes so
  a shape problem and a value problem cannot be reported as each other.
  """
  let localpart: String
  let algorithm: String
  let iterations: U32
  let salt: String
  let hash: String

  new val create(
    localpart': String,
    algorithm': String,
    iterations': U32,
    salt': String,
    hash': String)
  =>
    localpart = localpart'
    algorithm = algorithm'
    iterations = iterations'
    salt = salt'
    hash = hash'

primitive _RawEntryOf
  """
  Bind one `users` element.

  `int[U32]` rather than a number widened by hand: a count that will not fit
  is a problem the library reports, where narrowing it here would wrap and
  quietly unstretch the entry.
  """
  fun apply(c: YamlView ref): _RawEntry =>
    _RawEntry(
      c("localpart").text(),
      c("algorithm").text(),
      c("iterations").int[U32](),
      c("salt").text(),
      c("hash").text())

primitive _Entry
  """
  Decide whether one bound entry is a credential.
  """
  fun apply(entry: _RawEntry, where': String): (Credential | StartupError) =>
    match Localpart.check(entry.localpart)
    | let e: String =>
      return StartupError("credentials-localpart", where' + ": " + e)
    end

    // Named in the file so a future entry can carry a different one and be
    // rejected rather than verified with the wrong primitive.
    if entry.algorithm != "pbkdf2-sha256" then
      return StartupError(
        "credentials-algorithm",
        where' + ": unsupported algorithm " + entry.algorithm)
    end

    if entry.iterations < Pbkdf2MinIterations() then
      return StartupError(
        "credentials-iterations",
        where' + ": iterations must be at least " +
          Pbkdf2MinIterations().string() + ", not " +
          entry.iterations.string())
    end

    let salt =
      match _FromHex(entry.salt)
      | let b: Array[U8] val => b
      else
        return StartupError(
          "credentials-malformed", where' + ": salt is not hex")
      end

    if salt.size() < Pbkdf2SaltLength() then
      return StartupError(
        "credentials-salt-length",
        where' + ": salt must be at least " + Pbkdf2SaltLength().string() +
          " bytes, not " + salt.size().string())
    end

    let hash =
      match _FromHex(entry.hash)
      | let b: Array[U8] val => b
      else
        return StartupError(
          "credentials-malformed", where' + ": hash is not hex")
      end

    // The length matters, not just the encoding. A short hash is not a
    // rejected credential — `verify` would compare only that many bytes, so
    // a truncated paste silently becomes a prefix check and an empty one
    // matches every password.
    if hash.size() != Pbkdf2KeyLength() then
      return StartupError(
        "credentials-hash-length",
        where' + ": hash must be exactly " + Pbkdf2KeyLength().string() +
          " bytes, not " + hash.size().string() +
          " — was it truncated?")
    end

    Credential(
      entry.localpart,
      entry.iterations
      where salt' = salt, hash' = hash)

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
