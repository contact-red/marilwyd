primitive GhostLocalpart
  """
  Turn a far-side name into something that can be part of a Matrix user id.

  Two jobs at once, and both matter. IRC nicknames are case-insensitive, so
  `Dai` and `dai` are one person and must become one Matrix user — the
  caller folds under the network's own rule before calling this. And a
  Matrix localpart may hold only `a-z 0-9 . _ = / + -`, while a nickname may
  legally hold `[ ] \ ` ^ { } |` and bytes that are not text at all.

  Anything outside the permitted set becomes `=` and two hex digits. `=` is
  itself escaped, which is what makes the mapping injective: without it
  `a=62` and `ab` would name the same person, and two people on a channel
  would share one Matrix identity. Injectivity is the property that matters
  here — a collision is one stranger able to speak as another.
  """
  fun apply(folded: String): String =>
    let out = String(folded.size() + 8)
    for c in folded.values() do
      let plain =
        (((c >= 'a') and (c <= 'z')) or ((c >= '0') and (c <= '9'))
          or (c == '.') or (c == '_') or (c == '/') or (c == '+')
          or (c == '-'))
      if plain then
        out.push(c)
      else
        out.push('=')
        out.push(_Hexit(c >> 4))
        out.push(_Hexit(c and 0x0f))
      end
    end
    out.clone()

primitive _WellFormed
  """
  Whether the sequence at `at` is a well-formed encoding of one character.

  The continuation bytes, and the two ranges a first byte alone does not
  pin down: without them a three-byte sequence could spell a surrogate and
  a four-byte one a value above U+10FFFF, both of which are malformed.
  """
  fun apply(bytes: String, at: USize, first: U8, width: USize): Bool =>
    var j: USize = 1
    while j < width do
      let cont = try bytes(at + j)? else 0 end
      if (cont < 0x80) or (cont > 0xbf) then
        return false
      end
      j = j + 1
    end

    let second = try bytes(at + 1)? else 0 end
    if width == 3 then
      if ((first == 0xe0) and (second < 0xa0))
        or ((first == 0xed) and (second > 0x9f))
      then
        return false
      end
    end
    if width == 4 then
      if ((first == 0xf0) and (second < 0x90))
        or ((first == 0xf4) and (second > 0x8f))
      then
        return false
      end
    end
    true

primitive _Hexit
  fun apply(nibble: U8): U8 =>
    if nibble < 10 then '0' + nibble else ('a' + nibble) - 10 end

primitive ValidUtf8
  """
  Replace anything in a byte string that is not well-formed UTF-8.

  IRC is bytes, not text: a message may carry any encoding or none, and the
  `irc` package says so rather than pretending otherwise. Matrix is JSON,
  and JSON must be valid UTF-8 — so relaying a nickname or a line straight
  through would let one person on a channel emit a document that every
  client in the room refuses, which is a worse outcome than losing a
  character.

  Malformed sequences become U+FFFD, one per offending byte. Overlong
  encodings, surrogates and values above U+10FFFF are all malformed and are
  treated the same way, because a decoder that accepts them is how the same
  text gets two spellings.
  """
  fun apply(bytes: String): String =>
    """
    The same text with every malformed sequence replaced.
    """
    let out = String(bytes.size())
    var i: USize = 0
    let size = bytes.size()

    while i < size do
      let c = try bytes(i)? else 0 end
      let width =
        if c < 0x80 then USize(1)
        elseif (c >= 0xc2) and (c <= 0xdf) then USize(2)
        elseif (c >= 0xe0) and (c <= 0xef) then USize(3)
        elseif (c >= 0xf0) and (c <= 0xf4) then USize(4)
        else
          USize(0)
        end

      // One decision and one advance per pass. An earlier version left the
      // loop early with `continue`, which does not reach a Pony `while`'s
      // condition the way the shape suggests: the malformed cases spun
      // forever, and only a test that fed one a bad byte ever found out.
      let usable =
        if (width == 0) or ((i + width) > size) then
          false
        else
          _WellFormed(bytes, i, c, width)
        end

      if usable then
        var k: USize = 0
        while k < width do
          out.push(try bytes(i + k)? else 0 end)
          k = k + 1
        end
        i = i + width
      else
        out.append("\ufffd")
        i = i + 1
      end
    end

    out.clone()
