# Next increment: what Element needs after `/sync`

Everything here was measured against **Element 1.12.25** — the version the
Makefile pins — signed in as a local user, driven through headless Firefox,
with `--log-requests` on and its output timestamped.

## What is already true

`/sync` works and the sync loop is healthy. Four consecutive cycles from the
steady state, once the client has stopped catching up:

```text
--> GET /_matrix/client/v3/sync     <-- 200 after 25.001 s
--> GET /_matrix/client/v3/sync     <-- 200 after 25.001 s
--> GET /_matrix/client/v3/sync     <-- 200 after 25.000 s
--> GET /_matrix/client/v3/sync     <-- 200 after 25.001 s
```

Seven syncs in a two-minute session: a short burst of `timeout=0` syncs
while the client catches up, then the 25-second cadence above for as long as
it stays open. `/pushrules/` settled after three calls and `/filter` after
one; before this increment both were retried every few seconds, forever.

## What still blocks a usable client

Element's "Syncing…" screen is `pendingInitialSync`, and `postLoginSetup`
clears it only after **both** halves of this resolve:

```js
await Promise.all([firstSyncPromise, userHasCrossSigningKeys()])
```

`/sync` resolves the first half. The second issues
`POST /_matrix/client/v3/keys/query`, which marilwyd answers
`M_UNRECOGNIZED`; matrix-js-sdk retries it on every sync cycle and the
promise never settles. Sampled every ten seconds for ninety seconds, the
client state never moved:

```json
{"syncState":"SYNCING","hasCrypto":true,"userId":"@alice:...",
 "rooms":0,"spinner":true}
```

`syncState: SYNCING` is the proof that the sync half is done.

Two things worth knowing before starting:

- **Answering `keys/query` is not on its own enough.** With no cross-signing
  keys, `userHasCrossSigningKeys()` returns false, which routes Element into
  its `E2E_SETUP` view rather than into the app. An earlier spike that
  stubbed the crypto endpoints reached exactly that screen — "Unable to set
  up keys". The increment is the crypto flow, not an endpoint.
- **The retry is paced by the sync loop**, once per 25-second cycle, because
  the rust crypto machine flushes outgoing requests after each sync. Adding
  `/sync` fixed the request storm even for the request that still fails, so
  there is no urgency here beyond making the client usable.

## Everything Element asked for and did not get

From one two-minute session. `{userId}` is percent-encoded on the wire.

| Method | Path |
|---|---|
| POST | `/_matrix/client/v3/keys/query` |
| POST | `/_matrix/client/v3/keys/upload` |
| GET | `/_matrix/client/v3/capabilities` |
| GET | `/_matrix/client/v3/profile/{userId}` |
| GET | `/_matrix/client/v3/room_keys/version` |
| PUT | `/_matrix/client/v3/user/{userId}/account_data/{type}` |
| GET | `/_matrix/client/v3/voip/turnServer` |
| GET | `/_matrix/client/v3/thirdparty/protocols` |
| POST | `/_matrix/client/v3/register` |
| GET | `/_matrix/client/unstable/org.matrix.msc2965/auth_metadata` |
| GET | `/_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device` |
| GET | `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` |

All of these answer `M_UNRECOGNIZED` in JSON, so none of them is a parse
failure — they are simply absent. For the four non-GET rows that is new:
before the catch-all covered their methods they got a plain-text `405` with
no `errcode`, which matrix-js-sdk cannot read at all.

`account_data` is the one that is not crypto and is cheap: Element `PUT`s
notification settings once and then retries five times, because there is
nowhere to put them.

## Measured: two endpoints clear the gate, and a naive stub is worse

Stubbing `POST /keys/query` with empty key maps and `POST /keys/upload` with
an empty count **does** clear the spinner — the client leaves
`pendingInitialSync` and advances to Element's `E2E_SETUP` view, which shows
"Unable to set up keys", because
`POST /_matrix/client/v3/keys/device_signing/upload` answers
`M_UNRECOGNIZED`.

**Do not ship that stub.** In a seventy-second session it produced:

```text
10325 --> POST /_matrix/client/v3/keys/query
    5 --> GET  /_matrix/client/v3/sync
```

Roughly 150 requests a second, against 5 syncs. Answering `keys/query` with
empty maps tells the rust crypto machine the query did not resolve what it
asked for, so it asks again immediately, forever. That is a worse failure
than the 404 it replaces: the 404 was retried once per 25-second sync cycle,
because it rode the sync loop's outgoing-request flush.

A crypto endpoint answering *syntactically* is not the same as answering
*usefully*, and the difference shows up as a request storm rather than an
error. Whatever `keys/query`
returns has to satisfy the machine's notion of a completed query for the
device it asked about — which means the device id has to be real.

## Open questions to settle first

- **Device-aware sessions are probably a prerequisite, not a follow-up.**
  `SessionRegistry` records a user, not a device; the device id is minted at
  login, returned, and discarded. Every crypto endpoint is per-device, and
  the storm above is what a device-blind `keys/query` looks like.
- What `keys/query` must contain for the machine to consider the query
  answered. This is the crux and it is not guessable — it needs the same
  treatment `/sync` got: change one thing, run Element, read the log.
- Whether to implement cross-signing (`keys/device_signing/upload`,
  `room_keys/version`) or to find the branch that skips `E2E_SETUP`
  altogether. Not investigated.
- `account_data` PUT is the cheapest non-crypto item left — Element retries
  it five times a session and it needs no key handling at all.

## How to re-run the probe

The spike that produced these numbers lives outside the repository, but it is
small: build the server, run it with `--log-requests` piped through
something that stamps each line with a monotonic clock, then drive Element
with a Marionette script that signs in and samples
`mxMatrixClientPeg.get().getSyncState()` and `document.body.innerText` every
ten seconds. The client-state sampling is what distinguishes "stuck" from
"slow"; a screenshot alone does not.
