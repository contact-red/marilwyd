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

### Two devices can talk, but Element will not start the conversation

`POST /keys/claim` and `PUT /sendToDevice/{eventType}/{txnId}` are
implemented, and `to_device` is delivered through `/sync`. Two devices of
one account exchange keys and messages correctly, driven over curl: a
claim spends a key and the next claim gets a different one, a message
addressed to one device reaches that device and no other, `*` reaches all
of them, and a delivered message is not delivered twice.

What has not been seen is Element doing it. With neither device verified,
its UI offers "Remove this device" and nothing else — the control that
sends an `m.key.verification.request` appears after a device has been
verified against a recovery key, which needs secret storage
(`m.secret_storage.*` in account data) and the 4S flow behind it. That, not
the to-device channel, is what stands between here and two Elements
verifying each other.

Worth knowing before starting it: account data already round-trips, so the
storage half of secret storage may need nothing new. The work is finding
which account-data keys Element writes and reads during
`bootstrapSecretStorage`, and whether anything else gates the flow.

### Rooms are not encrypted, and `createRoom` says otherwise

**Done.** `createRoom` reads an `m.room.encryption` entry from
`initial_state` and writes the state event, so a client that asked for an
encrypted room gets one that says it is. `join_rules` follows from whether
the room asked to be found rather than from the field. `preset` and
`guest_access` are still dropped.

The design question it raised — the IRC bridge is plaintext by nature, so
an encrypted room is one the bridge cannot read — is answered by the two
being unable to meet. A bridged room is created by marilwyd without asking
for encryption, and encryption is creation-time only, so neither can
become the other.

### A backup holds nothing

`room_keys/version` records a version and answers it back, which is all a
client needs to finish signing in. There is no `room_keys/keys`, so the
backup a client believes it has holds no keys and reports a count of zero.
A client that loses its device loses its history — which is already true,
since a room keeps no messages, but a backup that exists and is empty is a
more specific promise than no backup at all.

### A recorded gap goes nowhere

A device that drops queued events or to-device messages records that it has
a gap, and nothing renders it: `/sync` writes `"limited": false`
unconditionally. Setting it honestly would tell a client to backfill
through `/rooms/{roomId}/messages`, which does not exist and will not — a
room keeps no messages. So surfacing a gap needs somewhere for the client
to go before it needs a field.

### Endpoints Element asks for and does not get

All answer `M_UNRECOGNIZED` in JSON, each is asked once, and none is asked
again.

| Method | Path | Cost of leaving it |
|---|---|---|
| POST | `register` | out of scope permanently |
| GET | `unstable/org.matrix.msc2965/auth_metadata` | no OIDC, by choice |
| GET | `unstable/org.matrix.msc3814.v1/dehydrated_device` | no dehydration |
| GET | `unstable/org.matrix.msc4143/rtc/transports` | no element call |

`M_UNRECOGNIZED` is the whole answer for the dehydrated device rather than a
placeholder for one. The client branches on the errcode: `M_UNRECOGNIZED`
means the server does not do dehydration, `M_NOT_FOUND` means it does and
holds none, and anything else is rethrown. `UnrecognizedRequest` therefore
tells it the truth, and implementing the endpoint to say the same thing
would gain nothing.

`capabilities`, `voip/turnServer` and `thirdparty/protocols` were on this
list and are answered now — the first because a refusal cost a request every
thirty seconds for the life of a session, the other two because an empty
document ends the asking where a refusal does not.

`m.fully_read` is the one part of that group still dropped. It is a private
per-room marker — the line Element draws for unread messages — and it needs
room-scoped account data, which marilwyd has none of. The receipt beside it
in the same request is kept, which is what stopped the retry loop.

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
- **Emitting `to_device` does not cause the hot loop the note warned of.**
  matrix-js-sdk pins `timeout=0` while it believes it is catching up and
  clears that only on a sync whose `to_device.events` is absent or empty.
  Driven end to end, a block emitted on every sync and a block emitted only
  when it has something behave identically: five syncs in eighty-four
  seconds either way. The danger is narrower than "emit the block" — it is
  a message that is delivered and never acknowledged, which would make the
  block permanent.
- **A client reads account data back from its local store, which only
  `/sync` fills.** `PUT` and `GET` on `account_data` alone would let a
  client save settings it could never read.
- **A refused endpoint is not always retried at one rate, and the rate is in
  the bundle.** matrix-js-sdk's capability poller re-polls thirty seconds
  after a failure and six hours after a success; the PSTN check behind
  `thirdparty/protocols` retries twice at ten-second intervals and then
  assumes no support; the TURN check runs on a ten-minute interval and stops
  for good on a 403. Reading the call site in
  `build/element/bundles/` answered all three in minutes, and the request log
  alone would have suggested one shared cadence.

## How to re-run the probe

The spike lives outside the repository. Build the server, run it with
`--log-requests`, and drive Element with a Marionette script that signs in
and samples `mxMatrixClientPeg.get().getSyncState()` and
`document.body.innerText` every ten seconds. The client-state sampling is
what distinguishes "stuck" from "slow"; a screenshot alone does not.

Three things worth knowing before repeating it.

Firefox from a snap has a private `/tmp`, so a profile written there is
invisible to it — put the profile under `$HOME`.

A process-killing pattern like `marilwyd` or `hs.py` matches the shell that
names it as well as the target, so match on the start of the command line
instead. But `/proc/<pid>/cmdline` separates arguments with NUL rather than
spaces: a multi-word pattern compared against it raw matches nothing, and a
teardown that quietly matches nothing leaves the previous run's server
holding the port. Two runs were served by a stale process before that was
spotted, and both looked like results. Replace the NULs before comparing,
and check the port is free rather than trusting the kill.

A spike server that survives is not a harmless leftover: it keeps the state
of every run before it, so device ids and login counts accumulate and the
client behaves as though it has more devices than the test created.
