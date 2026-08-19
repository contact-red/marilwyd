use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestAGhostNameIsAddressable is UnitTest
  """
  Whatever comes out has to be usable as a Matrix localpart, or the bridge
  mints senders no client can render and nobody can reply to.
  """
  fun name(): String => "ghost/a mapped name is a usable localpart"

  fun apply(h: TestHelper) =>
    for nick in
      [ "dai"; "bob[m]"; "a|b"; "who\\is"; "^caret"; "{brace}"
        "with space"; "UPPER"; "=equals"; "caf\xe8" ].values()
    do
      let mapped = GhostLocalpart(nick)
      match Localpart.check(mapped)
      | let why: String =>
        h.fail(nick + " mapped to something unusable: " + mapped
          + " (" + why + ")")
      end
    end

class \nodoc\ iso _TestGhostNamesAreInjective is UnitTest
  """
  The property that matters, and the reason `=` is itself escaped: two
  distinct IRC nicknames must never become one Matrix user. A collision is
  one stranger able to speak as another.
  """
  fun name(): String => "ghost/two nicknames never become one user"

  fun apply(h: TestHelper) =>
    // The pair that actually collides when `=` passes through: `[` is
    // 0x5b, so `a[b` escapes to `a=5bb` — which is exactly what the
    // literal nickname `a=5bb` becomes if its `=` is left alone. Two
    // people on one channel, one Matrix user.
    h.assert_ne[String](GhostLocalpart("a[b"), GhostLocalpart("a=5bb"))
    h.assert_ne[String](GhostLocalpart("bob[m]"), GhostLocalpart("bob{m}"))
    h.assert_ne[String](GhostLocalpart("a|b"), GhostLocalpart("a\\b"))

class \nodoc\ iso _TestAPlainNameIsUnchanged is UnitTest
  """
  A nickname already inside the grammar passes through, so the common case
  reads as itself in a room.
  """
  fun name(): String => "ghost/an ordinary nickname is left alone"

  fun apply(h: TestHelper) =>
    h.assert_eq[String]("dai", GhostLocalpart("dai"))
    h.assert_eq[String]("dai_ap-rhys", GhostLocalpart("dai_ap-rhys"))

primitive \nodoc\ _Bytes
  """
  A string of exact bytes.

  Pony's `\\x` escape in a source literal is a *code point*, so writing
  `"\\xe8"` yields well-formed UTF-8 for U+00E8 rather than the malformed
  byte the test means. These have to be pushed one at a time.
  """
  fun apply(raw: Array[U8] val): String =>
    let out = String(raw.size())
    for b in raw.values() do
      out.push(b)
    end
    out.clone()

class \nodoc\ iso _TestValidUtf8PassesGoodText is UnitTest
  fun name(): String => "ghost/well-formed text is not altered"

  fun apply(h: TestHelper) =>
    // Plain ASCII, two bytes, three bytes, four bytes, and nothing.
    for good in
      [ _Bytes([0x62; 0x6f; 0x72; 0x65])
        _Bytes([0x63; 0x61; 0x66; 0xc3; 0xa9])
        _Bytes([0xe2; 0x82; 0xac])
        _Bytes([0xf0; 0x9f; 0x8f; 0xb4])
        _Bytes([]) ].values()
    do
      h.assert_eq[String](good, ValidUtf8(good))
    end

class \nodoc\ iso _TestValidUtf8ReplacesBadBytes is UnitTest
  """
  IRC carries bytes; Matrix carries JSON, which must be UTF-8. Without this
  one person on a channel could emit a document every client in the room
  refuses — a worse outcome than losing a character.
  """
  fun name(): String => "ghost/malformed bytes become a replacement"

  fun apply(h: TestHelper) =>
    let replacement = _Bytes([0xef; 0xbf; 0xbd])
    // A lone continuation byte.
    h.assert_eq[String](replacement, ValidUtf8(_Bytes([0x80])))
    // A truncated two-byte sequence.
    h.assert_eq[String](replacement, ValidUtf8(_Bytes([0xc3])))
    // A high byte in the middle of ordinary text, which is what a Latin-1
    // client on a channel actually sends.
    h.assert_eq[String](
      _Bytes([0x63; 0x61; 0x66; 0xef; 0xbf; 0xbd; 0x20; 0x61]),
      ValidUtf8(_Bytes([0x63; 0x61; 0x66; 0xe8; 0x20; 0x61])))

class \nodoc\ iso _TestValidUtf8RefusesOverlongAndSurrogates is UnitTest
  """
  Overlong encodings and surrogates are malformed even though their shape
  is right. A decoder that accepts them gives the same text two spellings,
  which is how a filter is walked past.
  """
  fun name(): String => "ghost/overlong and surrogate forms are refused"

  fun apply(h: TestHelper) =>
    // An overlong `/`: the shape of a two-byte sequence for a byte that
    // needs one. It must not come back as a slash.
    h.assert_false(ValidUtf8(_Bytes([0xc0; 0xaf])).contains("/"))
    // A surrogate, U+D800, which UTF-8 may not encode.
    h.assert_false(ValidUtf8(_Bytes([0xed; 0xa0; 0x80])).contains(
      _Bytes([0xed; 0xa0; 0x80])))
    // Above U+10FFFF.
    h.assert_false(ValidUtf8(_Bytes([0xf5; 0x80; 0x80; 0x80])).contains(
      _Bytes([0xf5])))
