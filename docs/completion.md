# Completion

What Element asks marilwyd for, and what marilwyd answers.

Two lists, because they answer different questions. **Observed** is what
Element 1.12.25 actually requested in a driven session — the version the
Makefile pins, signed in as a local user, with `--log-requests` on. That is
the list that decides what to build next. **Defined** is every endpoint
matrix-js-sdk can reach; most of it is unreachable until rooms exist, and
some of it Element never calls at all.

The observed list is a floor, not a ceiling. No driven session has yet
*created* a room through Element — it cannot reach the UI that would, being
stuck at the crypto gate — so nothing in the `/rooms/` family appears below
even though marilwyd now answers five of those endpoints. Re-drive once
Element gets past crypto and this document needs another pass; the method is
in [next-increment.md](next-increment.md).

## What a settled session looks like

Since rooms landed, a signed-in client reaches a stable state rather than a
retry loop. From a real run, with `--log-requests` timestamps in seconds
since startup:

```text
[14.390] --> GET /pushrules/          [14.390] <-- 200
[14.433] --> POST .../filter          [14.433] <-- 200
[14.474] --> GET /sync                [14.474] <-- 200
[14.542] --> GET /sync                          (held)
[22.815] --> GET /room_keys/version   [22.816] <-- 404
[24.804] --> GET /thirdparty/protocols[24.804] <-- 404
```

Three things to read out of that. `pushrules` and `filter` are each called
**once** and never again — before rooms they retried every four seconds
forever. The first `/sync` answers in under a millisecond, because a client
with no position is owed everything it can already see. And the second
`/sync` has no `<--` at all: it is being held, which is the healthy resting
state and is why the log carries timestamps — an unmatched arrow is normal
now, and only the gap distinguishes a held sync from a hung one.

The endpoints marilwyd still refuses retry **slowly**, roughly eight to ten
seconds apart, rather than storming. Element is stuck, but it is not
hammering, which is worth knowing before treating the crypto gate as
urgent.

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

`account_data` is the cheapest thing left. It is requested the moment a
client signs in, needs no key handling, and is sent **twice within a
millisecond** — a duplicate from the client rather than a retry after
failure, which is the same shape `txnId` exists to resolve and worth
remembering when idempotency comes up.

Everything not answered returns `M_UNRECOGNIZED` in JSON with a 404, on all
four methods marilwyd routes, so none of it is a parse failure to a client —
they are simply absent.

## Implemented but not observed

marilwyd answers these; Element 1.12.25 did not ask for them in any driven
session. Two different reasons, and they matter differently.

The room endpoints and the device ones are unobserved because Element
**cannot get that far** — the crypto gate stops it before any UI that would
call them renders. They are exercised by the test suite and by curl, and
they should move into the observed table the first time a driven session
reaches them. If one of them is still here after Element gets past crypto,
that is a signal it is the wrong endpoint, not that it is untested.

`whoami` and the filter fetch are different: Element genuinely does not need
them on the paths it takes.

| Method | Endpoint | Note |
|---|---|---|
| GET | `account/whoami` | Element restores a session without it |
| GET | `user/{userId}/filter/{filterId}` | only on a reload with a cached id |
| POST | `logout` | matrix-js-sdk calls it on sign-out |
| GET | `devices` | Element's session manager lists from it |
| POST | `delete_devices` | Element's session manager signs out with it |
| POST | `createRoom` | Element sends more keys than marilwyd reads |
| POST | `join/{roomIdOrAlias}` | the spelling matrix-js-sdk builds |
| POST | `rooms/{roomId}/leave` | |
| PUT | `rooms/{roomId}/send/{type}/{txn}` | `txn` is routed and not read |
| GET | `rooms/{roomId}/state` | |

`createRoom` is the one to watch. Element sends `preset`, `join_rules`,
`guest_access` and `m.room.encryption`; marilwyd reads `name` and ignores
the rest, so a room a client asked to make private and encrypted comes back
public and unencrypted. Nothing renders that yet, and it becomes a lie the
moment something does.

## Defined by matrix-js-sdk, not yet reachable

Grouped by what has to exist first. None of these has been observed, and
some Element may never call. `DELETE /devices/{deviceId}` is the caution:
it was built and then removed, because marilwyd was answering an endpoint
no client calls while the two Element does use were missing.

**Sessions and devices** — `GET /devices/{deviceId}`,
`PUT /devices/{deviceId}`, and `DELETE /devices/{deviceId}`. The last is
defined by matrix-js-sdk and never called by Element, which signs out
through `POST /delete_devices` instead.

**Rooms** — the rest of the family. `GET /joined_rooms` (a client learns
its rooms from `/sync` instead), and under `/rooms/{roomId}/`:
`state/{eventType}/{stateKey}`, `event/{eventId}`,
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

`GET /rooms/{roomId}/messages` is not on that list and will not be: a room
keeps no messages, so there is nothing for it to page through. It would
need an actor that subscribes to rooms and stores what it sees.

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
