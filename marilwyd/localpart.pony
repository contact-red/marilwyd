primitive Localpart
  """
  The local part of a Matrix user ID — the `alice` in `@alice:example.org`.

  marilwyd checks it in two places, because it arrives by two routes:
  `hash-password` takes one from the command line, and the credentials file
  carries one per entry. Both reach the same identity, so both get the same
  rule.
  """
  fun check(localpart: String): (String | None) =>
    """
    Say what is wrong with `localpart`, or `None` if nothing is.

    The grammar is the historical one from the Matrix specification:
    lowercase letters, digits, and `._=/+-`. Anything outside it either
    cannot be addressed (a `:` ends the local part, so the rest is read as a
    server name) or cannot be written into the credentials file without
    escaping.
    """
    if localpart.size() == 0 then
      return "a localpart must not be empty"
    end

    for c in localpart.values() do
      let ok =
        ((c >= 'a') and (c <= 'z'))
          or ((c >= '0') and (c <= '9'))
          or (c == '.') or (c == '_') or (c == '=')
          or (c == '/') or (c == '+') or (c == '-')
      if not ok then
        return "a localpart may hold only a-z, 0-9 and ._=/+- : '"
          + localpart + "'"
      end
    end

    None
