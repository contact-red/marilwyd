# Next increment: what Element needs after encryption

Everything here was measured against **Element 1.12.25** — the version the
Makefile pins — signed in as a local user, driven through headless Firefox,
with `--log-requests` on and its output timestamped.

## What is already true

Element signs in and reaches the app. `/sync` long-polls, rooms deliver,
account data round-trips, and the encryption handshake completes in about a
hundred milliseconds and then stops. A seventy-second session after sign-in
costs five syncs and one `keys/query`.

The client renders "Verify this device" over the room list. That prompt is
not a failure — it is Element offering to cross-sign this device from
another one, and there is no other one.

## What still limits a usable server

Nothing blocks a session. What is left are things a client can do that
marilwyd cannot yet answer, in rough order of how soon a person would hit
them.

### A second device cannot talk to the first

Device verification, and any encrypted message between two devices, needs
an Olm session, and opening one needs two endpoints marilwyd does not have:

- `POST /keys/claim` — hand out one of a device's one-time keys and spend
  it. The keys are already stored, and this is the only reader they lack;
  it is the smallest useful next step in this area.
- `PUT /sendToDevice/{eventType}/{txnId}` and the `to_device` block in the
  sync response — the channel the two devices then talk over.

`to_device` needs care. `SyncDocument` deliberately never emits the block,
because matrix-js-sdk pins `timeout=0` while it believes it is catching up
and clears that only on a sync whose `to_device.events` is absent or empty.
Emitting an empty block is fine; emitting one that is never empty would put
a client into a hot loop.

### Rooms are not encrypted, and `createRoom` says otherwise

Element sends `preset`, `join_rules`, `guest_access` and
`m.room.encryption` to `createRoom`; marilwyd reads `name` and ignores the
rest. A room a client asked to make private and encrypted comes back public
and unencrypted, and nothing tells it so. This is the oldest lie in the
codebase and it grows more visible now that a client can reach the UI that
makes rooms.

Deciding what to do about `m.room.encryption` is a design question, not an
implementation one: the IRC bridge is plaintext by nature, so a room that
is genuinely encrypted end-to-end is a room the bridge cannot read.

### A backup holds nothing

`room_keys/version` records a version and answers it back, which is all a
client needs to finish signing in. There is no `room_keys/keys`, so the
backup a client believes it has holds no keys and reports a count of zero.
A client that loses its device loses its history — which is already true,
since a room keeps no messages, but a backup that exists and is empty is a
more specific promise than no backup at all.

### Endpoints Element asks for and does not get

All answer `M_UNRECOGNIZED` in JSON, and all are retried slowly rather than
storming.

| Method | Path | Cost of leaving it |
|---|---|---|
| GET | `capabilities` | Element assumes defaults |
| GET | `profile/{userId}` | no display name or avatar anywhere |
| GET | `voip/turnServer` | no calls |
| GET | `thirdparty/protocols` | no bridge list in the UI |
| POST | `register` | out of scope permanently |
| GET | `unstable/org.matrix.msc2965/auth_metadata` | no OIDC, by choice |
| GET | `unstable/org.matrix.msc3814.v1/dehydrated_device` | no dehydration |
| GET | `unstable/org.matrix.msc4143/rtc/transports` | no element call |

`profile` is the cheapest of these and the most visible: it is why the
client shows a user id where a name belongs.

## What was measured, so it need not be measured again

- **An endpoint answering syntactically is not the same as answering
  usefully.** `keys/query` with empty key maps clears the spinner and then
  produces 10,325 requests in seventy seconds, because a query that does
  not resolve what it asked about is retried at once. The rule that fixes
  it: every account named in the request gets an entry in the response,
  including the account asking, whether or not it named itself.
- **Each of the five encryption endpoints was verified by removal.**
  Dropping `keys/signatures/upload` ends a session at "Unable to set up
  keys" before the backup step. Dropping `POST /room_keys/version` ends it
  at the same screen one step later.
- **`device_one_time_keys_count` and `device_lists` in the sync response
  change nothing.** Omitting both was driven end to end and produced an
  identical session. They are not implemented for that reason, and this is
  the note that stops someone adding them on the assumption they are
  required.
- **A client reads account data back from its local store, which only
  `/sync` fills.** `PUT` and `GET` on `account_data` alone would let a
  client save settings it could never read.

## How to re-run the probe

The spike lives outside the repository. Build the server, run it with
`--log-requests`, and drive Element with a Marionette script that signs in
and samples `mxMatrixClientPeg.get().getSyncState()` and
`document.body.innerText` every ten seconds. The client-state sampling is
what distinguishes "stuck" from "slow"; a screenshot alone does not.

Two things worth knowing before repeating it. Firefox from a snap has a
private `/tmp`, so a profile written there is invisible to it — put the
profile under `$HOME`. And a process-killing pattern like `marilwyd` or
`hs.py` matches the shell that names it as well as the target; match on the
start of the command line instead.
