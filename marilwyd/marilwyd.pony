"""
marilwyd — a very small Matrix homeserver that also delivers its own Element
web client, on one origin, from one process.

Element is served under `/element/`; the Matrix Client-Server API lives under
`/_matrix/`. The origin root belongs to marilwyd and redirects into Element.

This is a skeleton. It implements enough of the Matrix Client-Server API for
Element to load, sign a local user in, spend the token it is given, and
settle into a working sync loop: version negotiation, both methods of
`/_matrix/client/v3/login`, `/_matrix/client/v3/account/whoami`, an always
empty `/_matrix/client/v3/sync` that long-polls, and the push-rule and
filter endpoints matrix-js-sdk waits on before it will start syncing.

Element does not become usable at this point, and the reason is not
`/sync`. It clears its "Syncing…" screen only when a first sync **and** a
cross-signing key query have both completed, and marilwyd implements no
crypto endpoints — so a signed-in client sits on that screen with a healthy
sync loop underneath it. Crypto is the next piece of work.

Accounts are provisioned from a file of password hashes; there is no
registration endpoint. Sessions live in memory, so a restart ends all of
them.
"""
