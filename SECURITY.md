# Security

## What `--asset-root` exposes

Everything under `--asset-root` is served unauthenticated to anyone who can
reach the socket. That is the whole Element tree, which is more than the login
path needs — it includes the element-call widget, a second bundled
application, and source maps. Narrowing the served set is a future change, not
a current guarantee.

`_AssetRoot` canonicalises the root at startup, and `hobby.ServeFiles` resolves
every request path through `FilePath.from`, which keeps the result within that
root.

## Symlinks are followed

`FilePath.from`'s containment is **textual**: it does not resolve symlinks. A
symlink placed under `--asset-root` therefore serves whatever it points at,
including a target outside the root. `FileInfo` reports such a symlink as a
regular file, so `ServeFiles` has nothing to reject it on.

This is documented upstream behaviour, not a defect. Confirmed by probe: a
symlink under the asset root pointing at `/etc/passwd` serves that file.

Consequently the asset root should contain only files intended to be public.
The Element release tarball contains **zero** symlinks, so the shipped
configuration is unaffected; this matters when an operator assembles a tree by
hand.

The asset root is opened with `{FileLookup, FileRead, FileStat}` only, so the
exposure is disclosure, never modification.

## Credentials and tokens

The credentials file holds PBKDF2-HMAC-SHA256 hashes, never passwords.
marilwyd has no code path that writes a plaintext password anywhere, and
`hash-password` reads one from stdin rather than from an argument so it does
not reach the process table or shell history. Still, treat the file as
sensitive: it is the offline-attack surface for every account. A weak password
behind it is recoverable, and the iteration count in its entry sets only the
cost of each guess.

`AccessToken` is deliberately not `Stringable` and has no `string()`. A token
cannot reach a log line, an error message, or a string concatenation by
accident, because none of those compile — verified from outside the package.
`reveal` is the single deliberate exit, so grepping for it lists every place
a token leaves marilwyd.

The protection is one-directional. A token arriving from a client is a plain
`String` from the `Authorization` header until it is compared, and gets none
of it.

Password and token comparisons both go through `ConstantTimeCompare`, so
neither leaks where a supplied value first differs from the real one. Token
resolution is a linear scan for that reason rather than a keyed lookup.

An unknown user and a wrong password produce identical responses and take the
same time: the unknown-user path derives against a fixed decoy rather than
returning early. Without that, the two differed by the whole cost of the key
derivation — measured at roughly 400x — and identical bodies would not have
stopped anyone timing the difference.

Matrix permits `?access_token=` in a query string. marilwyd reads only the
`Authorization: Bearer` header — a query string reaches logs, proxies and
browser history far too easily.

The credentials file is validated for value as well as shape at startup: the
hash must be exactly the derived-key length, the salt at least 16 bytes, and
the iteration count at or above a floor. A short hash used to be accepted, and
`verify` derived to the *stored* length — so a truncated paste became a prefix
check and an empty hash matched every password.

marilwyd refuses a credentials file that any user but its owner can read, and
one placed inside `--asset-root`, where every file is served unauthenticated.

## Revocation

Tokens do not expire on their own. A session ends when its own client calls
`POST /logout`, when another of that account's clients deletes its device, or
when the server restarts — and a restart still ends every session at once,
because sessions are held in memory.

One session is one device, so revocation is per-client: signing out on a
phone leaves a desktop signed in. Deleting devices is scoped to the token's
own user, because a device id is a public label rather than a secret — and
once the crypto endpoints publish device ids to everyone sharing a room,
naming one stops requiring a guess. The ownership check is the whole
barrier, not a second one behind the identifier's entropy.

Deleting answers success whether or not a named device existed, so the
response cannot be used to discover which ids are in use. The scan that
looks for it is not constant-time, so its duration can still distinguish
one of your own devices from an absent one; that discloses nothing an
account cannot already list about itself.

Revocation is not instant for a client mid-poll: a `/sync` already being
held answers up to `MaxSyncWait()` later, and the request after that is the
first one refused. Since rooms exist, that answer can carry room content
sent after the session was revoked — a window the old always-empty `/sync`
did not have.

Deleting a device deviates from the specification in one way: Matrix defines
that endpoint as requiring user-interactive authentication, and marilwyd has
none. The bearer token is the whole check. That is weaker than a conformant
server against an attacker who already holds a token, and no weaker against
one who does not.

A session whose token nobody holds any more — a browser closed without
signing out — can be ended by another of the account's clients, which is
what `GET /devices` and `POST /delete_devices` are for. There is no
`/logout/all`, so ending them all at once still means a restart.

Removing a user from the credentials file does not end their session by
itself — it ends only because the file is read once at startup, so removing
someone requires the restart that clears every session. Anything that reloads
credentials without restarting would break that coupling silently.

## Cost of a login attempt

Verifying a password is a single 600,000-iteration PBKDF2 call, which occupies
one scheduler thread for roughly 380 ms and cannot be preempted — it is one
FFI call into libcrypto. Nothing bounds how many run at once, and there is no
rate limit.

An unauthenticated caller can therefore buy ~380 ms of CPU with a ~130-byte
request, and the decoy derivation above means an unknown username costs the
same as a known one. Measured on two scheduler threads, eight concurrent
attempts took an unrelated static request from 1 ms to over a second. On a
many-core host it is not noticeable; on a one or two vCPU VPS it is a
denial-of-service surface.

Memory was remotely growable through the parse rather than the derivation,
and is now bounded. `JsonParser` allocates a container frame per level of
nesting and takes no limits, so a body's parse cost was proportional to its
length — and `/login` needs no credential to reach, and is refused with
`400` before any derivation runs, so it cost an attacker less than a real
login attempt. Measured on the shipped binary, 100 concurrent 64 kB nested
bodies over three rounds took RSS from 9 MB to 200 MB.

`_ParseLogin` now refuses a body over `MaxLoginBody()` or nested deeper
than `MaxLoginDepth()` before the parser builds anything from it. The size
limit bounds one body's cost; the depth limit bounds its shape, so the
frame count no longer follows the byte count. Both are checked in a
streaming pre-pass, since ponyc 0.68.0's `JsonParser` takes no limits and
only its token-level counterpart can be stopped mid-document.

Measured after: the same load reaches 30 MB, and a maximally nested body
now costs slightly *less* than a flat body of the same length at four times
the concurrency — 32 MB against 38 MB. What remains is the cost of the
connections themselves, which is the unbounded-concurrency surface
described above rather than anything specific to the parse.

## Cost of a held sync

`/sync` holds a request open for up to 25 seconds before answering. That
changes what a connection costs to keep, and it is a deliberate trade.

Before `/sync`, every request was answered in milliseconds, so the number of
simultaneous connections tracked the arrival rate. Now it tracks the number
of signed-in clients, continuously: each one keeps a connection, a handler
actor, two timers — marilwyd's deadline and hobby's watchdog — and its
parsed request and body alive for the whole wait, then re-opens
immediately afterwards. Measured at 147 kB per held sync, and 262 kB when
the request carries a 65,000-byte body, since the body is pinned for the
full hold.

A client that closes its tab costs nothing extra: the FIN reaches
`_SyncHandler.dispose`, which cancels the deadline at once. A client that
vanishes without closing — a suspended laptop, a dropped network — is the
expensive case, and there the socket is not released either; stallion's
60-second idle timeout is what eventually reclaims it.

One connection can also hold far more than one sync. hobby answers pipelined
requests in order, so several holds sent in a single write are served one
after another, each response resetting the idle timer. Measured: three
pipelined 25-second syncs in one 450-byte write answered at 25, 50 and 75
seconds. At stallion's default of 100 pending responses that is over 40
minutes of pinned connection bought with about 15 kB.

Nothing in marilwyd bounds how many syncs are held at once. The only ceiling
is lori's own default of 100,000 connections, which marilwyd cannot currently
change, because `hobby.Server` does not expose it — recorded under **Known
upstream issues** in the README. On the one or two vCPU VPS this project is
aimed at, that ceiling is not a protection.

This is accepted rather than fixed, for the same reason as the login cost
above: marilwyd is a personal homeserver, and both surfaces need an
authenticated session or a rate limiter in front rather than a bound here.
Holding costs more memory per client than the alternatives and far less CPU
and bandwidth: answering immediately produces 36 requests a second per
client, and letting hobby's watchdog expire produces a `504` with no
`errcode` and a permanent client reconnect flap.

The bound to add first, if this becomes real: a count of held syncs, with
anything above it answered immediately instead of held. Matrix permits a
server to answer before the requested timeout, so that degrades to the
immediate-answer behaviour rather than to an error.

## Cost of a room

A room keeps no messages, so nothing accumulates in one. What accumulates
is per device: an event is fanned out to every member's devices as it
arrives, and a device that is not syncing holds what it has not
acknowledged.

`PendingLimit()` bounds that at a thousand events per device. Past it the
oldest are dropped and the device records that it has a gap.

That record does not currently reach the client. `/sync` renders
`"limited": false` unconditionally, so a device that has lost events says
nothing about it — the honest field to set would tell a client to backfill
through an endpoint marilwyd does not implement, and answering a client
with a pointer to nothing is the failure mode this codebase has already
been bitten by twice. The gap is recorded and asserted in tests; surfacing
it needs somewhere for the client to go.

Dropping rather than refusing is deliberate: the alternative lets one
sleeping device stop a room delivering to everyone else.

What this bounds and what it does not:

* Bounded — how much one device accumulates while away, and therefore how
  much an account accumulates, since a device count is bounded by logins.
* **Not bounded** — the number of rooms, the number of members in one, and
  the current state a room holds. A room's name comes from its creator and
  nothing caps its length. Every one of those needs an authenticated
  account, so this is the same posture as the login cost above: stated,
  and left for a rate limiter in front rather than a bound here.

A room id is the whole of the access control on a room. Anyone holding one
can join, there are no invitations, and nothing revokes an id — a room
cannot be renamed into a new one and a member cannot be removed by anyone
but themselves. It is 128 bits from the CSPRNG so it cannot be guessed,
which makes disclosure the only way one escapes. `--log-requests` prints
paths, and three of the room endpoints carry the id in the path, so **do
not enable request logging on a deployment where room ids matter** until
that is redacted.

## Published keys

Encryption keys are the one thing marilwyd stores that is meant to be read
by people other than the account that wrote it, so what crosses that line
is worth stating.

**Public by design.** A device's identity keys, and an account's master and
self-signing keys, are answered to anyone with a valid token who asks for
that account. That is not a leak — it is what the endpoint is for, and it
is what everyone else encrypts to. It does mean a signed-in account can
enumerate any account it can name, and learn its device ids. `POST
/delete_devices` is scoped to the caller's own account for exactly that
reason: device ids stop being something an attacker has to guess once
`keys/query` will hand them over.

**Withheld.** The user-signing key is answered only to its owner. It is
what an account uses to sign *other* people, and no one else has a use for
it.

**A signature upload cannot replace a key.** `keys/signatures/upload`
carries the whole key object it signs, so the obvious implementation stores
what arrives — and then any device of an account could republish another
device's identity keys, changing what other users encrypt to. marilwyd
reads only the `signatures` field of an upload and merges it into what is
stored, which makes that substitution impossible rather than merely
disallowed. Signatures under a user id other than the caller's own are
ignored entirely.

**What marilwyd does not do.** It does not verify a single signature.
Nothing here checks that a key was signed by the key it claims, that a
device key is well formed, or that an account's cross-signing keys are
self-consistent. A client that trusts marilwyd's answers is trusting the
account that uploaded them and the transport, not a server that checked
anything. Real homeservers do not verify these either — verification is the
clients' job, and it is why the keys are signed — but it is worth being
explicit that a compromised account can publish nonsense and marilwyd will
serve it.

Key backups are storage of a description only. `room_keys/version` records
the algorithm and `auth_data` a client sends and hands back a version
number; there is no endpoint to put room keys into a backup, so a backup
holds none and reports a count of zero. Nothing in a backup is secret to
marilwyd — `auth_data` is a public key — and nothing about it is verified.

## What one device says to another

`sendToDevice` carries a message from one device to another and marilwyd
reads none of it. The content is parsed only far enough to check it is a
JSON object and is then stored as text; in practice it is an Olm
ciphertext, and marilwyd holds no key that could open one.

**The sender is the token, not the body.** A message is stamped with the
account the access token belongs to, so a client cannot send as anyone
else. A client may address any account it can name — that is what the
endpoint is for — but it cannot forge who a message came from.

**Nothing is reported back.** Sending to an account that does not exist, or
to a device that does not exist, answers exactly as sending to a real one
does. That is deliberate: a response that distinguished them would let any
signed-in account enumerate accounts and devices by sending to guesses.
`keys/claim` behaves the same way — a device with no keys left and a device
that has never existed are both answered by leaving it out.

**A flood costs only the flooder.** Any signed-in account may send to any
device it can name, and the device ids needed to aim at one are public —
`keys/query` hands them out, as recorded above. A single queue per device
would therefore let a stranger push past `ToDeviceLimit()` and evict a
handshake the device was in the middle of with someone else.

A device keeps one queue per sending account instead, so the only messages
a flood discards are the flooder's own. The bound is per sender, and what
bounds the number of senders is that an account cannot be created: they
come from the credentials file. Keying by device rather than by account
would have undone that, since anyone may mint devices without limit by
signing in again.

What is left is the ordinary cost: a device's to-device memory is bounded
by the number of accounts times `ToDeviceLimit()`, and an account that
floods still occupies its own share. That needs an authenticated account,
so it is the same posture as the other costs here — stated, and left to a
rate limiter in front.

## Cost of the to-device channel

Per device, bounded at `ToDeviceLimit()` messages — a hundred, smaller than
the thousand `PendingLimit()` allows for room events, because what a
dropped message costs differs. A dropped room event costs a client one
message it can see is missing; a dropped to-device message costs it half a
handshake, and neither end is told which half.

A `sendToDevice` request is refused past `MaxToDeviceBody()`. One request
may name many devices, so that is larger than the key-upload bound rather
than equal to it.

## Cost of published keys

Per device, bounded: one identity key object, and a pool of one-time keys
capped at `MaxOneTimeKeys()`. A key upload is refused past
`MaxKeysBody()` — 131,072 bytes, against the 12,698 a real Element upload
measures — so a single request cannot be arbitrarily large.

Per account, **not bounded**: published device keys are keyed by device id
and are removed when a device is deleted, not when it signs out. An account
that signs in repeatedly, each time being issued a fresh device,
accumulates one key object per device for as long as the process runs. This
is the same posture as the room costs above — it needs an authenticated
account, so it is stated here and left to a rate limiter in front rather
than bounded here.

## Deployment shape

marilwyd never terminates TLS: it calls `hobby.Server`, not
`hobby.Server.ssl`. An `https` `--scheme` therefore describes a terminator in
front of this process, and marilwyd cannot verify that one exists — setting it
does not encrypt the socket, it only changes the address clients are told to
use.

Because of that, a loopback `--bind-host` says nothing about whether marilwyd
is reachable from the internet: the intended topology puts a terminator in
front and binds loopback.

## Reporting

This is a personal project and not yet released. Raise anything you find with
the repository owner directly.
