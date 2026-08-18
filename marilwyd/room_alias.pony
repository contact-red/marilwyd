class val RoomAlias is Stringable
  """
  A human-readable name for a room — `#pony:server_name`.

  **Not a second room id, and the difference is the whole of why this is
  its own type.** A room id is a bearer token: 128 bits of CSPRNG, and
  knowing one is what entitles you to join. An alias is the opposite —
  short, guessable, and meant to be shared — so publishing one for a room
  hands its id to anyone who asks for it.

  That is not a flaw in aliases; it is what they are for. It does mean an
  alias must only ever exist for a room whose owner meant it to be open,
  and `SECURITY.md` says so. Sharing a type with `RoomId` would have made
  the two interchangeable at every call site that takes one.
  """
  let _value: String

  new val _create(value: String) =>
    _value = value

  fun string(): String iso^ =>
    _value.clone()

  fun matches(supplied: String): Bool =>
    """
    Compare against an alias a caller supplied.

    Ordinary equality, unlike a room id's: an alias is public by design, so
    there is nothing about a failed comparison worth hiding.
    """
    _value == supplied

class val InvalidAlias is Stringable
  """
  Text that cannot be a room alias, and why.
  """
  let _reason: String

  new val _create(reason: String) =>
    _reason = reason

  fun string(): String iso^ =>
    _reason.clone()

primitive RoomAliases
  """
  Build a room alias, or say why the text cannot be one.

  The permitted characters are `Localpart`'s, which is narrower than Matrix
  allows. Deliberately: an alias is offered to people to type, it becomes
  an IRC channel's name on the Matrix side, and a set that is already the
  server's answer for user ids is one fewer grammar to get wrong. Widening
  it later is additive; narrowing it would break rooms already named.
  """
  fun apply(text: String, server_name: String)
    : (RoomAlias | InvalidAlias)
  =>
    """
    Read a whole alias as a client sends it — `#name:server_name`.
    """
    try
      if text(0)? != '#' then
        return InvalidAlias._create("a room alias begins with '#'")
      end
    else
      return InvalidAlias._create("a room alias cannot be empty")
    end

    let colon =
      try
        text.find(":")?
      else
        return InvalidAlias._create("a room alias names its server")
      end

    let named: String = text.substring(colon + 1)
    if named != server_name then
      // Nothing here is federated, so an alias on another server names a
      // room this process could not answer for even in principle.
      return InvalidAlias._create("that alias belongs to another server")
    end

    let local: String = text.substring(1, colon)
    make(local, server_name)

  fun make(name: String, server_name: String)
    : (RoomAlias | InvalidAlias)
  =>
    """
    Build an alias from the local part alone — what `createRoom` sends as
    `room_alias_name`, and what a bridged channel is named after.
    """
    match Localpart.check(name)
    | let why: String => return InvalidAlias._create(why)
    end
    RoomAlias._create("#" + name + ":" + server_name)
