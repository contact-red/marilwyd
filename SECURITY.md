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

Tokens do not expire and there is no logout endpoint. Restarting is the only
revocation, and it revokes every session at once, because sessions are held in
memory and nothing else removes one.

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

Memory is not remotely growable this way — a failed login retains nothing.

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
