"""
marilwyd — a very small Matrix homeserver that also delivers its own Element
web client, on one origin, from one process.

Element is served under `/element/`; the Matrix Client-Server API lives under
`/_matrix/`. The origin root belongs to marilwyd and redirects into Element.

This is a skeleton. It implements enough of the Matrix Client-Server API for
Element to load, sign a local user in, spend the token it is given, and
settle into a working sync loop: version negotiation, both methods of
`/_matrix/client/v3/login`, `/_matrix/client/v3/account/whoami`, an always
`/_matrix/client/v3/sync` that long-polls and answers the moment an event
arrives, the push-rule and filter endpoints matrix-js-sdk waits on before
it will start syncing, logout for a session or for one of its owner's other
devices, and rooms.

A room knows who is in it and what its state says, and keeps no messages —
each event is fanned out as it arrives to the members' devices, which hold
what has not been acknowledged. That is what makes a room's cost
proportional to its membership rather than to its traffic, and it is the
shape a bridged IRC channel wants: a channel has no scrollback either, and
the thing that holds messages for a disconnected user is a per-user
buffer.

One account can hold several sessions at once, one per client, each with its
own device id and token, and each with its own queue of what it has not yet
been told. A client that signs back in naming the device id it stored finds
that queue again.

Element does not become usable at this point, and the reason is not
`/sync`. It clears its "Syncing…" screen only when a first sync **and** a
cross-signing key query have both completed, and marilwyd implements no
crypto endpoints — so a signed-in client sits on that screen with a healthy
sync loop underneath it. Crypto is the next piece of work.

Accounts are provisioned from a file of password hashes; there is no
registration endpoint. Sessions live in memory, so a restart ends all of
them.
"""
