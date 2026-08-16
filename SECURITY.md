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
sensitive: it is the offline-attack surface for every account, and a weak
password behind it is only as strong as the iteration count in its entry.

`AccessToken` is deliberately not `Stringable` and has no `string()`. A token
cannot reach a log line, an error message, or a string concatenation by
accident, because none of those compile. `reveal` is the single deliberate
exit and has exactly one call site: the body of a successful login response.

Password and token comparisons both go through `ConstantTimeCompare`, so
neither leaks where a supplied value first differs from the real one. Token
resolution is a linear scan for that reason rather than a keyed lookup.

An unknown user and a wrong password produce identical responses, so login
cannot be used to enumerate accounts.

Matrix permits `?access_token=` in a query string. marilwyd reads only the
`Authorization: Bearer` header — a query string reaches logs, proxies and
browser history far too easily.

**Not yet done:** tokens never expire and there is no logout, so the only way
to revoke one is to restart. Sessions are in memory, so a restart revokes all
of them.

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
