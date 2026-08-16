# marilwyd

A very small Matrix homeserver, in Pony, that also delivers its own Element
web client — one origin, one process.

## Status

A skeleton, but a working one: Element loads, a local user signs in, the
token that comes back can be spent, and the client settles into a real sync
loop instead of retrying. Ten Matrix endpoints, listed below.

Accounts come from a file of password hashes — there is no registration
endpoint. Sessions live in memory, so a restart ends all of them. Everything
Element asks for beyond the table below answers `M_UNRECOGNIZED`.

**Element does not become usable yet, and `/sync` is not what is missing.**
It clears its "Syncing…" screen only once a first sync *and* a cross-signing
key query have both completed. marilwyd implements no crypto endpoints, so
`POST /_matrix/client/v3/keys/query` answers `M_UNRECOGNIZED`, matrix-js-sdk
retries it forever, and the screen stays. Underneath it the sync loop is
healthy — measured at one request per 25 seconds against Element 1.12.25,
where before this the client re-asked several times a second. Crypto is the
next piece of work; see `docs/next-increment.md`.

Out of scope: the Application Service API, permanently — IRC and Discord
bridging will be built natively instead. Federation, for now.

## Building

Requires [corral](https://github.com/ponylang/corral), a C SSL library (a
transitive requirement of `ssl`, via `stallion`), and a ponyc **newer than
0.68.0**.

That version floor is not arbitrary. `hobby.ServeFiles` keeps requests inside
`--asset-root` via `FilePath.from`, whose containment check landed after
0.68.0. Built against 0.68.0 or earlier, a request for
`/element/../<sibling>` escapes the asset root whenever a sibling directory's
name extends its own.

```shell
corral fetch
make
make test
```

`make run` fetches and unpacks Element, then starts marilwyd on
`http://localhost:8008`. The Element tarball is verified against a recorded
SHA-256 and unpacked atomically, so an interrupted build cannot leave a
partial tree that looks up to date.

## Accounts

There is no registration endpoint. Accounts are provisioned from a
credentials file that holds **password hashes, never passwords** — marilwyd
never writes a plaintext password anywhere, and recovering one from an entry
costs a PBKDF2 search.

Generate an entry, reading the password from stdin so it never reaches your
shell history or the process table:

```shell
read -rs PASSWORD
printf '%s' "$PASSWORD" | marilwyd hash-password alice
```

Collect the entries into a file:

```json
{
  "users": [
    {
      "localpart": "alice",
      "algorithm": "pbkdf2-sha256",
      "iterations": 600000,
      "salt": "<32 hex characters from hash-password>",
      "hash": "<64 hex characters from hash-password>"
    }
  ]
}
```

Each entry carries its own iteration count, so raising the figure applies to
new entries without invalidating existing ones. The salt and hash lengths are
fixed and checked at startup: a truncated paste is refused rather than
quietly weakening the credential.

Adding a second user means editing the file — `hash-password` prints one
entry, it does not append. The `users` array holds them all:

```json
{ "users": [ { "localpart": "alice", … }, { "localpart": "bob", … } ] }
```

Keep the file readable only by its owner; marilwyd refuses to start
otherwise, and refuses a file placed inside `--asset-root`, where everything
is served to anyone who can reach the socket.

## Running

```shell
marilwyd serve \
  --server-name localhost:8008 \
  --asset-root build/element \
  --credentials credentials.json
```

| Flag | Required | Default |
|---|---|---|
| `--server-name` | yes | — |
| `--asset-root` | yes | — |
| `--credentials` | yes | — |
| `--scheme` | no | `http` |
| `--bind-host` | no | `127.0.0.1` |
| `--bind-port` | no | the port in `--server-name`, else 8008 |

`--server-name` is the only identity input. The advertised `base_url` is
computed from it, so Element cannot be handed an address for a different
server.

`--bind-port` defaults to the port inside `--server-name`, so the common case
repeats nothing. They stay separable because a reverse-proxied deployment
needs them to differ — and nothing at startup can check that they agree, so
marilwyd prints both:

```quote
marilwyd: clients are told to use http://localhost:8008
marilwyd: listening on 127.0.0.1:8008
```

If those two disagree and nothing is proxying between them, the browser will
load Element and every Matrix call will fail as cross-origin.

A port below 1024 *derived* from `--server-name` is refused, since
`--server-name contact.red:443` is legal Matrix and would otherwise turn an
identity flag into a privileged bind. An explicit `--bind-port 443` is
honoured.

## Layout

```quote
marilwyd/         the server
marilwyd_test/    its tests, a sibling package
```

They are separate packages because marilwyd is a program: `actor Main` is
already taken in `marilwyd/`. Private types are therefore invisible to the
tests, which is a real cost — anything carrying a rule a test must check is
public.

## Routes

| Method | Path | |
|---|---|---|
| GET | `/` | redirects to `/element/index.html` |
| GET | `/element` | same |
| GET | `/element/config.json` | generated from `--server-name` |
| GET | `/element/config.<host>.json` | Element probes this first |
| GET | `/element/bundles/*` | content-hashed; `immutable` |
| GET | `/element/*` | the Element tree; `no-cache` |
| GET | `/_matrix` | `M_UNRECOGNIZED` |
| GET | `/_matrix/client/versions` | `["v1.1"]` |
| GET | `/_matrix/client/v3/login` | the password flow |
| POST | `/_matrix/client/v3/login` | verifies a password, issues a token |
| GET | `/_matrix/client/v3/account/whoami` | resolves a token |
| GET | `/_matrix/client/v3/sync` | always empty; holds up to 25 s |
| GET | `/_matrix/client/v3/pushrules/` | an empty ruleset |
| POST | `/_matrix/client/v3/user/:userId/filter` | a constant `filter_id` |
| GET | `/_matrix/client/v3/user/:userId/filter/:filterId` | an empty filter |
| GET, POST, PUT, DELETE | `/_matrix/*` | `M_UNRECOGNIZED` |

The catch-all covers four methods rather than just GET. A method with no row
of its own is answered by the HTTP framework, with a plain-text
`405 Method Not Allowed` carrying no `errcode` — which matrix-js-sdk cannot
read, and so retries forever. Element reaches this on every session.

`/sync` holds a request open for as long as the client asked, up to 25
seconds. Answering an empty sync immediately is legal and catastrophic: the
client re-asks at once, measured at 36 syncs a second. The cap sits under
the framework's own 30-second handler timeout, which would otherwise answer
`504` with no `errcode` and put the client into a permanent reconnect flap.

Sessions live in memory only, so a restart logs everyone out. That is
deliberate: there is nothing worth persisting until rooms and events exist.

An unknown user and a wrong password produce byte-identical answers **and
take the same time** — the unknown-user path derives against a decoy rather
than returning early, so the endpoint cannot be used to enumerate accounts by
either route. Password and token comparisons are constant-time.

That means every login attempt, valid or not, costs a full key derivation.
See [SECURITY.md](SECURITY.md).

Element is mounted under `/element/` rather than at the origin root. Its
release tarball ships `apple-app-site-association` and
`.well-known/assetlinks.json`, which delegate universal-link handling and iOS
keychain credential sharing for the serving domain to Element's published
mobile apps. Serving them from a homeserver's own domain grants that
authority; serving Element from a subpath does not, because neither platform
looks for those files outside the origin root. It also leaves `/` free for
marilwyd.

Three routes are marked `hobby#1` in the source. hobby's router does not
consult a node's wildcard entries once the request's path segments are
exhausted, so a wildcard mount cannot answer its own mount point. They delete
together when that is fixed upstream — except `/`, which stays as the
namespace boundary.

## Known upstream issues

Found while building this, and deliberately not worked around here:

- **ponyc** — `cli` cannot report whether an option was supplied or defaulted,
  which is why `--bind-port` needs a sentinel to stay overridable; its
  environment-variable fallback cannot reach a kebab-case option name at all.
  (`FilePath.from`'s containment check is fixed, after 0.68.0. Symlinks are
  still followed, by design — see [SECURITY.md](SECURITY.md).)
- **hobby** — a wildcard mount cannot answer its own mount point;
  `ServeFiles` requires the wildcard to be named `filepath` or it returns 500
  at request time; `listen_failed` reports one constant string for every bind
  failure; `listening` reports a resolved address rather than the bind host;
  response interceptors are silently inert on streamed responses;
  `lori.TCPListener`'s connection limit is not reachable through
  `hobby.Server`.
