# Completion

What Element asks marilwyd for, and what marilwyd answers.

Two lists, because they answer different questions. **Observed** is what
Element 1.12.25 actually requested in a driven session — the version the
Makefile pins, signed in as a local user, with `--log-requests` on. That is
the list that decides what to build next. **Defined** is every endpoint
matrix-js-sdk can reach; most of it is unreachable until rooms exist, and
some of it Element never calls at all.

The observed list is a floor, not a ceiling. Element now reaches the app,
but a driven session still only *signs in* — it does not create a room or
send a message — so nothing in the `/rooms/` family appears below even
though marilwyd answers five of those endpoints. Driving the client through
those actions is what would move them up; the method is in
[next-increment.md](next-increment.md).

## What a settled session looks like

A signed-in client now reaches the app rather than a gate. The whole
encryption handshake, from one real run with `--log-requests` timestamps in
seconds since startup:

```text
[23.261] --> POST /keys/query                    [23.261] <-- 200
[23.277] --> GET  /sync                          [23.277] <-- 200
[23.301] --> POST /keys/upload                   [23.302] <-- 200
[23.315] --> POST /keys/query                    [23.315] <-- 200
[23.316] --> GET  /sync                                    (held)
[23.349] --> POST /keys/device_signing/upload    [23.350] <-- 200
[23.353] --> GET  /room_keys/version             [23.354] <-- 404
[23.363] --> POST /keys/signatures/upload        [23.363] <-- 200
[23.377] --> POST /room_keys/version             [23.377] <-- 200
```

Four things to read out of that. The whole handshake takes **116
milliseconds** and happens once. The two `keys/query` calls bracket
`keys/upload` — the first finds nothing, the second finds the device that
just published, and it is the second that lets the client proceed. The 404
on `room_keys/version` is correct rather than a gap: there is no backup
until the `POST` two lines later makes one. And the `/sync` at 23.316 has no
`<--` at all, because it is being held — the healthy resting state, and why
the log carries timestamps.

Over the following seventy seconds the client makes **five** syncs and
**one** further `keys/query`. The comparison worth keeping is the stub that
answered `keys/query` with empty key maps: 10,325 requests in seventy
seconds, against five syncs. An endpoint that answers syntactically is not
the same as one that answers usefully, and the difference showed up as a
request storm rather than as an error.

The endpoints marilwyd still refuses retry **slowly**, roughly eight to ten
seconds apart, and none of them stops the client working.

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
| POST | `keys/query` | done |
| POST | `keys/upload` | done |
| POST | `keys/device_signing/upload` | done |
| POST | `keys/signatures/upload` | done |
| GET | `room_keys/version` | done |
| POST | `room_keys/version` | done |
| PUT | `user/{userId}/account_data/{type}` | done |
| GET | `capabilities` | not started |
| GET | `profile/{userId}` | not started |
| GET | `voip/turnServer` | not started |
| GET | `thirdparty/protocols` | not started |
| POST | `register` | out of scope |
| GET | `unstable/org.matrix.msc2965/auth_metadata` | not started |
| GET | `unstable/org.matrix.msc3814.v1/dehydrated_device` | not started |
| GET | `unstable/org.matrix.msc4143/rtc/transports` | not started |

Nothing on that list blocks a session any more. Element signs in, finishes
setting up keys and renders the app; what is left unanswered it retries
slowly or does without.

The five encryption rows were one gate rather than five items, and each was
verified by removing it and driving the client again. Dropping
`keys/signatures/upload` alone ends a session at "Unable to set up keys"
before it reaches the backup step; dropping `POST room_keys/version` ends it
at the same screen one step later. Two things that look like they belong on
that list are not: `device_one_time_keys_count` and `device_lists` in the
sync response change nothing when omitted, measured the same way.

`/register` is out of scope permanently: accounts come from a credentials
file and there is no registration endpoint.

`account_data` is sent **twice within a millisecond** — a duplicate from the
client rather than a retry after failure, which is the same shape `txnId`
exists to resolve and worth remembering when idempotency comes up. It is
also the endpoint that showed the sync response is not optional: a client
reads account data back from its local store, which only `/sync` fills.

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
| POST | `keys/claim` | no second device has claimed one yet |
| PUT | `sendToDevice/{type}/{txn}` | Element sends none with one device |

`keys/claim` and `sendToDevice` are here for a specific reason. A single
signed-in device has nothing to talk to, so Element never calls either in a
one-client session — they are exercised by the test suite and by two
devices driven over curl. Element's own two-device verification was not
reached: with neither device verified, its UI offers only "Remove this
device", and the path that would send an `m.key.verification.request` opens
after a device has been verified by a recovery key. So these two rows are
verified at the protocol level rather than by a completed verification, and
that distinction is the whole reason this table separates observed from
implemented.

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

**Encryption beyond signing in** — `GET /keys/changes`,
`PUT`/`DELETE /room_keys/version/{version}`, and `GET`/`PUT`/`DELETE
/room_keys/keys`. A backup that actually holds keys needs the last of
those; nothing marilwyd serves needs any of them today.

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
