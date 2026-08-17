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
held answers its empty document up to `MaxSyncWait()` later, and the
request after that is the first one refused.

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

Memory is remotely growable, through the parse rather than the derivation.
`_ParseLogin` hands the request body to `JsonParser`, which allocates a
container frame per level of nesting and bounds neither depth nor total
allocation. Measured against the shipped binary from a fresh process, 100
concurrent deeply-nested bodies of 64 kB each — 6.4 MB of traffic — took RSS
from 8.9 MB to 901 MB, and it does not come back. The request is refused with
`400` before any derivation runs, so this costs an attacker less than a real
login attempt does.

The 64 kB body limit caps the per-request cost, and is why the figure is
901 MB rather than sixteen times that. It does not cap the total.
A depth or size check before `JsonParser.parse` would; there is no limits API
on `JsonParser` in ponyc 0.68.0, so it has to be a length check on the body
or a `JsonTokenNotify` that aborts past a depth.

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
