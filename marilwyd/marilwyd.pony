"""
marilwyd — a very small Matrix homeserver that also delivers its own Element
web client, on one origin, from one process.

Element is served under `/element/`; the Matrix Client-Server API lives under
`/_matrix/`. The origin root belongs to marilwyd and redirects into Element.

This is a skeleton. It implements enough of the Matrix Client-Server API for
Element to load, sign a local user in, and spend the token it is given:
version negotiation, both methods of `/_matrix/client/v3/login`, and
`/_matrix/client/v3/account/whoami`.

Accounts are provisioned from a file of password hashes; there is no
registration endpoint. Sessions live in memory, so a restart ends all of
them.
"""
