primitive ChannelNames
  """
  The names in a channel's member list, with their status marks removed.

  A server lists a channel's members as one space-separated line, each name
  possibly wearing the marks of what that person may do there — `@` for an
  operator, `+` for voice, and more than one at a time where the server
  supports it. The marks are the server's own: which byte carries which
  mode is announced at registration, so they are read from what it said
  rather than assumed.

  A server that announced nothing still uses the two the specification
  names, and a name left wearing its mark is a different person — one who
  will never match the name that same person speaks under.
  """
  fun apply(listed: String, marks: Array[(U8, U8)] val): Array[String] val =>
    let found = recover iso Array[String] end
    for name in listed.split(" ").values() do
      let bare = _bare(consume name, marks)
      if bare.size() > 0 then
        found.push(bare)
      end
    end
    consume found

  fun _bare(name: String, marks: Array[(U8, U8)] val): String =>
    var at: USize = 0
    while at < name.size() do
      if not _marked(try name(at)? else return "" end, marks) then
        break
      end
      at = at + 1
    end
    name.substring(at.isize())

  fun _marked(byte: U8, marks: Array[(U8, U8)] val): Bool =>
    if marks.size() == 0 then
      return (byte == '@') or (byte == '+')
    end
    for (_, mark) in marks.values() do
      if byte == mark then
        return true
      end
    end
    false
