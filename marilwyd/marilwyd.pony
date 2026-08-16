"""
marilwyd — a very small Matrix homeserver that also delivers its own Element
web client, on one origin, from one process.

Element is served under `/element/`; the Matrix Client-Server API lives under
`/_matrix/`. The origin root belongs to marilwyd and redirects into Element.

This is a skeleton. It implements `GET /_matrix/client/versions` and both
methods of `/_matrix/client/v3/login` — enough for Element to load, validate
the server, and render a login form that legitimately refuses every
credential, because marilwyd has no accounts yet.
"""
