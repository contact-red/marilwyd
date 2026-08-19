# marilwyd

A very small Matrix homeserver, in Pony, that also delivers its own Element
web client — one origin, one process.

## Status

**Element signs in and reaches the app.** A local user logs in, the client
settles into a real sync loop instead of retrying, finishes setting up
encryption keys, and renders the room list. Thirty-four Matrix endpoints,
listed below.

One account can be signed in from several clients at once — a browser, a
phone, a desktop — each with its own device id and its own token, and each
able to sign out without disturbing the others.

Accounts come from a file of password hashes — there is no registration
endpoint. Sessions live in memory, so a restart ends all of them. Everything
Element asks for beyond the table below answers `M_UNRECOGNIZED`.

Encryption is stored and served, not performed. marilwyd holds the keys
clients publish and hands them back — device keys, cross-signing keys,
signatures, and the description of a key backup — which is what a client
needs to finish signing in. It verifies no signature and encrypts nothing:
that is the clients' job, and `SECURITY.md` says exactly what crosses which
line. Two devices of one account can now reach each other: `POST /keys/claim`
spends a one-time key so they can open a session, and
`PUT /sendToDevice/…` carries what they say over it, delivered through the
recipient's `/sync`. marilwyd never reads any of it, and a device queues
each sending account separately so that an account flooding one can only
discard its own messages.

A settled session costs five syncs and one `keys/query` per seventy
seconds. That number is in the README because the naive version of the same
endpoint — answering `keys/query` with empty key maps — produced 10,325
requests in the same span.

A bridge configuration may be named with `--bridges`. It declares which
IRC channels marilwyd carries and what Matrix room each one is; the rooms
are created before the listener opens, so a client connecting the instant
marilwyd is up finds them there. marilwyd then connects, joins each
channel, and relays what is said there into the room.

**Inbound only.** What is said on IRC reaches Matrix; nothing goes the
other way yet. That half has no injection surface — marilwyd sends the
network nothing a person wrote — and reading a channel from a phone is most
of what a bridge is for.

An IRC participant becomes a Matrix user the first time they speak, with
their nickname as a display name. Two spellings of one nickname are one
Matrix user, because IRC nicknames are case-insensitive; a nickname a
Matrix user id cannot hold is escaped so that two different people can
never become the same one.

A room may be published in the directory and given an alias — `#pony:…` —
which is how a person finds a room without being handed its id. Publishing
one is deliberate rather than incidental: a room id is the entire access
control, so a listed room is one anybody signed in may join, and
`SECURITY.md` says what follows from that.

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

`hash-password` prints a YAML sequence element. Collect them under
`users:`:

```yaml
users:
  - localpart: alice
    algorithm: pbkdf2-sha256
    iterations: 600000
    salt: "<32 hex characters from hash-password>"
    hash: "<64 hex characters from hash-password>"
```

Each entry carries its own iteration count, so raising the figure applies to
new entries without invalidating existing ones. The salt and hash lengths are
fixed and checked at startup: a truncated paste is refused rather than
quietly weakening the credential.

Adding a second user means editing the file — `hash-password` prints one
entry, it does not append. Every entry sits under the one `users:` key, and
YAML allows comments, so a rotation date next to an entry is free.

Keep the file readable only by its owner; marilwyd refuses to start
otherwise, and refuses a file placed inside `--asset-root`, where everything
is served to anyone who can reach the socket.

## Running

```shell
marilwyd serve \
  --server-name localhost:8008 \
  --asset-root build/element \
  --credentials credentials.yaml
```

| Flag | Required | Default |
|---|---|---|
| `--server-name` | yes | — |
| `--asset-root` | yes | — |
| `--credentials` | yes | — |
| `--scheme` | no | `http` |
| `--bind-host` | no | `127.0.0.1` |
| `--bind-port` | no | the port in `--server-name`, else 8008 |
| `--log-requests` | no | off |
| `--bridges` | no | bridge nothing |

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

`--log-requests` prints each request as it arrives and each response as it
leaves, stamped with seconds since startup. The stamp is what makes a held
`/sync` legible: one unanswered arrow per signed-in client is the healthy
resting state, so the gap between a pair is the thing to read, not the
absence of one. Paths are logged and query strings never are.

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
| GET | `/_matrix/client/versions` | `["v1.1"]` |
| GET | `/_matrix/client/v3/login` | the password flow |
| POST | `/_matrix/client/v3/login` | verifies a password, issues a token |
| GET | `/_matrix/client/v3/account/whoami` | the token's user and device |
| POST | `/_matrix/client/v3/logout` | ends the calling session |
| GET | `/_matrix/client/v3/devices` | the account's devices |
| POST | `/_matrix/client/v3/delete_devices` | ends named sessions |
| GET | `/_matrix/client/v3/sync` | a device's events; holds up to 25 s |
| POST | `/_matrix/client/v3/createRoom` | makes a room |
| POST | `/_matrix/client/v3/join/:roomIdOrAlias` | joins one |
| POST | `/_matrix/client/v3/rooms/:roomId/leave` | leaves one |
| PUT | `/_matrix/client/v3/rooms/:roomId/send/:type/:txn` | sends an event |
| GET | `/_matrix/client/v3/rooms/:roomId/state` | a room's current state |
| GET | `/_matrix/client/v3/rooms/:roomId/members` | who is in a room |
| GET | `/_matrix/client/v3/profile/:userId` | a display name |
| POST | `.../rooms/:roomId/receipt/:type/:eventId` | read this far |
| POST | `/_matrix/client/v3/rooms/:roomId/read_markers` | the same |
| PUT | `/_matrix/client/v3/rooms/:roomId/typing/:userId` | who is typing |
| GET | `/_matrix/client/v3/pushrules/` | an empty ruleset |
| POST | `/_matrix/client/v3/user/:userId/filter` | a constant `filter_id` |
| GET | `/_matrix/client/v3/user/:userId/filter/:filterId` | an empty filter |
| PUT | `/_matrix/client/v3/user/:userId/account_data/:type` | stores it |
| GET | `/_matrix/client/v3/user/:userId/account_data/:type` | reads it back |
| POST | `/_matrix/client/v3/keys/upload` | publishes a device's keys |
| POST | `/_matrix/client/v3/keys/query` | answers an account's keys |
| POST | `/_matrix/client/v3/keys/device_signing/upload` | cross-signing keys |
| POST | `/_matrix/client/v3/keys/signatures/upload` | merges signatures |
| POST | `/_matrix/client/v3/room_keys/version` | makes a backup version |
| GET | `/_matrix/client/v3/room_keys/version` | the current one |
| POST | `/_matrix/client/v3/keys/claim` | spends a device's one-time key |
| PUT | `/_matrix/client/v3/sendToDevice/:type/:txn` | one device to another |
| GET | `/_matrix/client/v3/directory/room/:roomAlias` | an alias to a room id |
| GET | `/_matrix/client/v3/publicRooms` | the public room directory |
| POST | `/_matrix/client/v3/publicRooms` | the same, as a search sends it |
| GET, POST, PUT, DELETE | `/_matrix` | `M_UNRECOGNIZED` |
| GET, POST, PUT, DELETE | `/_matrix/*` | `M_UNRECOGNIZED` |

The catch-all covers four methods rather than just GET. A method with no row
of its own is answered by hobby, with a plain-text `405 Method Not Allowed`
carrying no `errcode` — which matrix-js-sdk cannot read, and so retries
forever. Element reaches this on every session. `OPTIONS` and `PATCH` are
not covered: a browser preflight needs CORS headers, which an
`M_UNRECOGNIZED` row would not supply either, so that is a known gap rather
than an oversight.

`/sync` holds a request open for as long as the client asked, up to 25
seconds, and answers the moment an event arrives for that device. Answering
an empty sync immediately is legal and catastrophic: the client re-asks at
once, measured at 36 syncs a second. The cap sits under hobby's own
30-second handler timeout, which would otherwise answer `504` with no
`errcode` and put the client into a permanent reconnect flap.

A first sync — one carrying no position — is answered at once whatever
timeout it asks for, because a client with no position is owed everything
it can already see.

Sessions live in memory only, so a restart logs everyone out — and takes
every room with it, since rooms are held the same way.

**A room keeps no messages.** It knows who is in it and what its current
state says, and fans each event out to its members as it arrives. A client
that was not a member when a message was sent will never see it, and one
that leaves and rejoins is told nothing about the gap. What is held for a
client that is offline is held by that client's own device, not by the
room, and is bounded per device rather than per room. Replaying history to
a rejoiner, if it is ever wanted, belongs to a separate actor that
subscribes to rooms as any member does.

Each login mints its own device, so the same account signed in twice has two
sessions that end independently. `GET /devices` lists them and
`POST /delete_devices` ends the ones you name — the pair Element's session
manager is built on. It has no call site for the specification's
single-device `DELETE /devices/{deviceId}`, so marilwyd does not answer one.

A login never reuses a device id a client asks for. Matrix allows that,
meaning "replace this device's session", and marilwyd always mints a fresh
one instead, so a re-login after a soft logout leaves the old session behind
rather than replacing it. Deleting devices requires user-interactive
authentication in the specification and only a bearer token here; see
[SECURITY.md](SECURITY.md).

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
