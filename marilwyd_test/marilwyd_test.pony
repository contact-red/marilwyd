"""
Tests for marilwyd.

A sibling package, because marilwyd is a program: `actor Main` is already
taken next door. Nothing `_`-private in `marilwyd` is reachable from here, so
anything carrying a rule these tests must check is public over there.

The route tests go over a real socket. `Routes` returns an opaque
`BuiltApplication`, so a unit test can only ask whether it built — which
covers none of the invariants the table actually depends on. Several of its
failure modes also share a status code with success, so the assertions look
at the whole response rather than the status line.
"""
