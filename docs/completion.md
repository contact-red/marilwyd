# Completion

What Element asks marilwyd for, and what marilwyd answers.

Two lists, because they answer different questions. **Observed** is what
Element 1.12.25 actually requested in a driven session — the version the
Makefile pins, signed in as a local user, with `--log-requests` on. That is
the list that decides what to build next. **Defined** is every endpoint
matrix-js-sdk can reach; most of it is unreachable until rooms exist, and
some of it Element never calls at all.

The observed list is a floor, not a ceiling. Every session so far has had
**no rooms**, so nothing in the `/rooms/` family has appeared. Re-drive
Element after the first room exists and this document will need a second
pass — the method is in [next-increment.md](next-increment.md).

## Observed: what Element requests today

Paths are relative to `/_matrix/client/v3/` unless marked otherwise.

| Method | Endpoint | Status |
|---|---|---|
| GET | `/_matrix/client/versions` | done |
| GET | `login` | done |
| POST | `login` | done |
| GET | `pushrules/` | done |
| POST | `user/{userId}/filter` | done |
| GET | `sync` | done |
| POST | `keys/query` | **blocking** |
| POST | `keys/upload` | **blocking** |
| POST | `keys/device_signing/upload` | **blocking** |
| PUT | `user/{userId}/account_data/{type}` | not started |
| GET | `capabilities` | not started |
| GET | `profile/{userId}` | not started |
| GET | `room_keys/version` | not started |
| GET | `voip/turnServer` | not started |
| GET | `thirdparty/protocols` | not started |
| POST | `register` | out of scope |
| GET | `unstable/org.matrix.msc2965/auth_metadata` | not started |
| GET | `unstable/org.matrix.msc3814.v1/dehydrated_device` | not started |
| GET | `unstable/org.matrix.msc4143/rtc/transports` | not started |

**blocking** means Element will not leave its "Syncing…" screen without it.
The three key endpoints are one gate, not three items: `postLoginSetup`
waits on a cross-signing key query, and answering it wrongly is worse than
not answering it — an empty key map produced 10,325 requests in seventy
seconds. See [next-increment.md](next-increment.md).

`/register` is out of scope permanently: accounts come from a credentials
file and there is no registration endpoint.

Everything not answered returns `M_UNRECOGNIZED` in JSON with a 404, on all
four methods marilwyd routes, so none of it is a parse failure to a client —
they are simply absent.

## Implemented but not observed

marilwyd answers these; Element 1.12.25 did not ask for them in any driven
session.

| Method | Endpoint | Note |
|---|---|---|
| GET | `account/whoami` | Element restores a session without it |
| GET | `user/{userId}/filter/{filterId}` | only on a reload with a cached id |
| POST | `logout` | matrix-js-sdk calls it on sign-out |
| GET | `devices` | Element's session manager lists from it |
| POST | `delete_devices` | Element's session manager signs out with it |

## Defined by matrix-js-sdk, not yet reachable

Grouped by what has to exist first. None of these has been observed, and
some Element may never call. `DELETE /devices/{deviceId}` is the caution:
it was built and then removed, because marilwyd was answering an endpoint
no client calls while the two Element does use were missing.

**Sessions and devices** — `GET /devices/{deviceId}`,
`PUT /devices/{deviceId}`, and `DELETE /devices/{deviceId}`. The last is
defined by matrix-js-sdk and never called by Element, which signs out
through `POST /delete_devices` instead.

**Rooms** — the largest family, all unreachable with no rooms:
`POST /createRoom`, `GET /joined_rooms`, `POST /join/{roomIdOrAlias}`,
and under `/rooms/{roomId}/`: `send/{eventType}/{txnId}`, `state`,
`state/{eventType}/{stateKey}`, `messages`, `event/{eventId}`,
`context/{eventId}`, `relations/{eventId}`, `threads`, `members`,
`joined_members`, `invite`, `kick`, `ban`, `unban`, `leave`, `forget`,
`typing/{userId}`, `receipt/{receiptType}/{eventId}`, `read_markers`,
`redact/{eventId}/{txnId}`, `upgrade`, `hierarchy`, `aliases`,
`initialSync`, `timestamp_to_event`, `report`.

**Account data and tags** — `GET`/`PUT /user/{userId}/account_data/{type}`,
the same scoped to a room, and `/user/{userId}/rooms/{roomId}/tags`.

**Encryption beyond the gate** — `POST /keys/claim`,
`POST /keys/signatures/upload`, `GET /keys/changes`, `POST /room_keys/version`,
`GET`/`PUT /room_keys/keys`.

**Media** — `POST /upload`, and the download and thumbnail endpoints under
the media namespace.

**Account management** — `POST /account/password`, `POST /account/deactivate`,
the `/account/3pid` family, `POST /refresh`, `POST /login/get_token`.

**Directory and search** — `GET`/`POST /publicRooms`,
`POST /user_directory/search`, `POST /search`, `GET /notifications`,
`GET`/`POST /pushers`, `GET /register/available`.

**Profile** — `PUT /profile/{userId}/{key}`, `DELETE /profile/{userId}/{key}`.

## How this list was produced

The observed rows come from marilwyd's own request log during a Marionette-
driven Element session. The defined rows come from the endpoint literals in
the shipped bundle under `build/element/bundles/`, which are the paths
matrix-js-sdk hands to `authedRequest` — they carry no prefix in the source,
so `"/devices"` there is `/_matrix/client/v3/devices` on the wire.

A literal existing in the bundle proves only that the SDK can construct the
request, never that Element makes it. Where that distinction matters, drive
the client and read the log.
