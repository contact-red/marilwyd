primitive IrcLineBudget
  """
  How many bytes of message text one IRC line carries.

  Below the protocol's 512 because that budget includes the command, the
  target and the sender prefix the server prepends — which marilwyd cannot
  see and cannot measure. 425 leaves room for a long nickname, a long
  channel name and the `PRIVMSG` around them.
  """
  fun apply(): USize => 425

primitive SplitForIrc
  """
  Break a Matrix message into IRC lines, preferring somewhere a reader
  would have paused.

  A Matrix message is one thing a person wrote; an IRC line is a fixed
  budget of bytes. Cutting at the budget produces a break mid-word, and
  half a sentence arriving as its own line reads as two thoughts rather
  than one — so the break walks back to a sentence end, then a word end,
  and only cuts blind when the text offers neither.

  Newlines split first and always, whatever the length. That is not
  cosmetic: a bare `\\n` in text sent to IRC would end the command and let
  what follows be read as another, so it has to become a line boundary
  rather than travel inside one. The `irc` package's own `privmsg` does
  this too — this happens first so that a paragraph is split where its
  author split it, and the budget applies within each piece.
  """
  fun apply(text: String, budget: USize = IrcLineBudget()): Array[String] val =>
    let out = recover iso Array[String] end
    for line in _Lines(text).values() do
      for piece in _Sized(line, budget).values() do
        out.push(piece)
      end
    end
    consume out

primitive _Lines
  """
  Split on CR and LF, dropping what is empty.

  An empty piece costs a line and a pacing slot to say nothing, and a
  paragraph written with blank lines between it would otherwise spend most
  of its budget on them.
  """
  fun apply(text: String): Array[String] val =>
    let out = recover iso Array[String] end
    let current = String(text.size())
    for c in text.values() do
      if (c == '\n') or (c == '\r') then
        if current.size() > 0 then
          out.push(current.clone())
          current.clear()
        end
      else
        current.push(c)
      end
    end
    if current.size() > 0 then
      out.push(current.clone())
    end
    consume out

primitive _Sized
  """
  Break one line into pieces no longer than the budget.

  Three places to break, in order of how little the reader notices: after a
  sentence, after a word, and anywhere. Each is looked for only within the
  budget, so the search never runs past the byte it is trying to stay
  under.
  """
  fun apply(line: String, budget: USize): Array[String] val =>
    let out = recover iso Array[String] end
    var rest: String = line

    while rest.size() > budget do
      let at = _Break(rest, budget)
      let piece: String = rest.substring(0, at.isize())
      out.push(_Trimmed(piece))
      let remainder: String = rest.substring(at.isize())
      rest = _Untrimmed(remainder)
    end

    if rest.size() > 0 then
      out.push(rest)
    end
    consume out

primitive _Break
  """
  Where to cut a line that is over budget.

  A period or comma first, then a space, then the budget itself. The
  sentence break is taken only when it leaves a piece worth sending —
  breaking after the third character of a four-hundred-byte line would
  honour the rule and produce nonsense — so a break in the first quarter is
  ignored in favour of the next rule down.
  """
  fun apply(line: String, budget: USize): USize =>
    let floor' = budget / 4

    var i = budget
    while i > floor' do
      let c = try line(i - 1)? else 0 end
      if (c == '.') or (c == ',') then
        return i
      end
      i = i - 1
    end

    i = budget
    while i > floor' do
      let c = try line(i - 1)? else 0 end
      if c == ' ' then
        return i
      end
      i = i - 1
    end

    // Nowhere sensible. Back off a UTF-8 continuation byte so a character
    // is not cut in half — a split that produces mojibake is worse than
    // one that produces a short line.
    var stop = budget
    var backed: USize = 0
    while (stop > 0) and (backed < 3) do
      let at = try line(stop)? else 0 end
      if (at and 0xc0) != 0x80 then
        break
      end
      stop = stop - 1
      backed = backed + 1
    end
    if stop == 0 then budget else stop end

primitive _Trimmed
  """
  A piece without the trailing space a word break leaves on it.
  """
  fun apply(piece: String): String =>
    if piece.size() == 0 then
      return piece
    end
    let last = try piece(piece.size() - 1)? else 0 end
    if last == ' ' then
      piece.substring(0, piece.size().isize() - 1)
    else
      piece
    end

primitive _Untrimmed
  """
  The remainder without the space a word break left at its start.
  """
  fun apply(rest: String): String =>
    if rest.size() == 0 then
      return rest
    end
    let first = try rest(0)? else 0 end
    if first == ' ' then
      rest.substring(1)
    else
      rest
    end
