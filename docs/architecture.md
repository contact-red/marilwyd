# How marilwyd works

marilwyd is a Matrix homeserver and an IRC bridge in one process. It serves
its own Element web client from the same origin, holds every account and
room in memory, and writes nothing to disk.

This document describes the actors it is built from, the state each one
holds, and the message sequence behind every operation it performs.

## Contents

- [The shape of the program](#the-shape-of-the-program)
- [Actors that live for the process](#actors-that-live-for-the-process)
- [Actors that live for one request](#actors-that-live-for-one-request)
- [Classes that carry state](#classes-that-carry-state)
- [The receiver protocol](#the-receiver-protocol)
- [Operations](#operations) — a sequence diagram each
- [Rules that hold everywhere](#rules-that-hold-everywhere)

---

## The shape of the program

Nothing in marilwyd is shared mutable state. Every piece of state belongs
to exactly one actor, and everything else asks that actor a question and is
answered later. There is no lock anywhere, because there is nothing to lock.

Three ideas explain most of the design.

**A request is an actor.** Every HTTP request builds a short-lived handler
actor which holds the client's connection, asks whatever it needs to ask,
and responds when the answers arrive. It then dies. A handler never blocks
and never shares.

**An answer comes back as a behaviour call, not a return value.** Asking
`SessionRegistry` who holds a token does not return a session; it calls
`token_resolved` on the asker later. Every such contract is a named
interface — the *receiver protocol* — so what can be asked and what can
come back are both visible in the types.

**The fan-out path avoids the shared actors.** A room delivers an event
straight to its members' `User` actors, which deliver to their `Device`
actors. `RoomDirectory` is consulted to *find* a room and never to deliver
into one, which is what keeps the one shared map off the path that runs
per message.

```mermaid
graph TB
    subgraph "per process"
        SR[SessionRegistry<br/>who is signed in]
        RD[RoomDirectory<br/>which room is which]
        LD[LinkDirectory<br/>who holds which IRC connection]
    end
    subgraph "per account"
        U[User<br/>rooms, keys, account data]
    end
    subgraph "per signed-in device"
        D[Device<br/>the sync queue]
    end
    subgraph "per room"
        R[Room<br/>membership and fan-out]
        RS[RoomState<br/>plain class, no actor]
    end
    subgraph "per user per channel"
        UL[UserLink<br/>one IRC connection]
    end
    H[request handler<br/>one per HTTP request]

    H -->|resolve| SR
    H -->|with_room / for_user| RD
    SR --> U
    U --> D
    R -->|deliver| U
    U -->|deliver| D
    R -->|deliver| UL
    UL -->|admit_ghost / send| R
    LD --> UL
    R -.holds.- RS
```

---

## Actors that live for the process

### `Main`

Reads the command line, builds the route table, declares any bridged
channels, and opens the listener. It is also the only place marilwyd is
told the server has started or failed to bind.

`Main` holds nothing but `_env`. Everything else it builds and hands away.

### `SessionRegistry` — one per process

Who is signed in, for as long as the process runs.

| Field | Holds |
|---|---|
| `_sessions` | `Array[_Session]` — token, user id, device id |
| `_users` | `Map[String, User tag]` — one actor per account |
| `_streams` | `Map[String, Map[String, Device tag]]` — devices per account |
| `_epoch` | `StreamEpoch` — distinguishes this run's stream positions |

Behaviours: `issue`, `resolve`, `devices`, `lookup_users`, `revoke`,
`revoke_devices`.

Tokens are compared **one at a time in constant time** rather than looked
up by key, so verifying a token cannot leak where it first differs from a
real one. That makes verification linear in stored sessions, and every
authenticated request pays it. `SECURITY.md` records the cost.

`_actors_for` makes a `User` and a `Device` on first use — which is why a
client that signs back in with the device id it stored finds everything
that was held for it.

### `User` — one per account

An account: which rooms it is in, which devices are signed in to it, and
everything published under its name.

| Field | Holds |
|---|---|
| `_devices` | device id → `Device tag` |
| `_rooms` | room id → `Room tag` |
| `_invites` | room id → invite state, until answered |
| `_account` | account data, by type |
| `_keys` | published device keys, by device id |
| `_master`, `_self_signing`, `_user_signing` | cross-signing keys |
| `_backups` | key backup versions |

It exists so that a `Room` has one target that does not change. Membership
is a fact about an account, and a device signing in or out is not a
membership change — if rooms held device references, every login would have
to find every room, and until it did, ORCA would keep a signed-out device's
queue alive because a room still pointed at it.

Fanning out here rather than in the room is also what keeps a room's cost
proportional to its members rather than to their devices.

### `Device` — one per signed-in device

The sync queue, and everything a client is owed.

| Field | Holds |
|---|---|
| `_pending` | `Pending[RoomEvent]` — the bounded event queue |
| `_parked`, `_parked_since` | a held `/sync` and the position it gave |
| `_state`, `_described` | room state per room, and the position it was stamped at |
| `_invites` | rooms this device has been asked into |
| `_ephemeral`, `_ephemeral_at` | receipts and typing, per room |
| `_account`, `_account_at` | account data and its position |
| `_one_time` | unclaimed one-time keys |
| `_to_device` | `Map[String, Pending[ToDeviceEvent]]`, **keyed by sending account** |

To-device messages are queued **per sender**, so one account flooding
another cannot evict a third party's messages — an attacker only evicts
their own.

`_position` advances for anything a client needs to know about, not only
events: account data and room descriptions move it too, so a position
derived from queue length would miss them.

### `Room` — one per room

Membership, fan-out, and the room's own bookkeeping.

| Field | Holds |
|---|---|
| `_state` | `RoomState` — a plain class, described below |
| `_bridge`, `_network` | the channel this room is, if it is one |
| `_members` | user id → `RoomMember tag` — who to deliver to |
| `_carrying` | user id → `RoomMember tag` — outward connections, *not* members |
| `_stalled` | whose carrier cannot currently reach the network |
| `_watching` | accounts that hear ephemeral state |
| `_receipts`, `_typing` | the ephemeral state itself |
| `_position` | the room's own event counter |

`_members` and `_carrying` are deliberately separate. A member is somebody
the room delivers to; a carrier is a connection that takes what a member
said outward. A bridged room has both for the same person, and they answer
different questions.

### `RoomDirectory` — one per process

Which room actor is which. **Deliberately not on the fan-out path**: once a
`User` has joined a room it holds that room's tag directly, so delivering
an event never comes back here.

| Field | Holds |
|---|---|
| `_rooms` | room id → `Room tag` |
| `_aliases` | alias → room id |
| `_published` | rooms listed in the public directory |
| `_channels` | alias → declared `(BridgedChannel, BridgedNetwork)` |
| `_theirs` | `alias + " " + user_id` → that person's own bridged room |

`_aliases` and `_channels` are two maps over **one** alias namespace, and
both creation paths check both — an alias that named a channel to one
endpoint and a room to another was a real defect.

### `LinkDirectory` — one per process

Every Matrix user's own IRC connection, and the one place they are made.
Keyed by `user + network + channel`, because that pairing is what a
connection is for.

Behaviours: `open`, `close`, `forget`. The last is a connection reporting
its own death, so the next join opens a fresh one rather than being
answered with a corpse.

### `UserLink` — one per Matrix user per channel

One person's IRC connection. A **bouncer, not presence**: it opens when
they join the bridged room and closes when they explicitly leave, so idling
in a channel — the ordinary way to be on IRC — is what membership means.

There is no bot. A room's traffic is carried by the connections of the
people in it, so nothing relays on anyone's behalf and nothing sees its own
words come back. That is the whole of the loop prevention: it is
structural, not a configured check.

`UserLink` implements both `irc.IRCNotify` (what the network says) and
`RoomMember` (what the room delivers), so a room fans out to it exactly as
it does to a `User` and never learns which it is holding.

---

## Actors that live for one request

Every endpoint builds one. They share a shape: capture the bearer token,
ask `SessionRegistry.resolve`, and do nothing else until `token_resolved`
arrives — so an unauthenticated caller drives no parsing, allocates no
timer, and touches no room.

| Handler | Endpoint |
|---|---|
| `_LoginHandler` | `POST /login` |
| `_LogoutHandler`, `_DevicesHandler`, `_DeleteDevicesHandler` | session management |
| `_SyncHandler` | `GET /sync` |
| `_CreateRoomHandler` | `POST /createRoom` |
| `_MembershipHandler` | `POST /join/{…}`, `POST /rooms/{id}/leave` |
| `_InviteHandler` | `POST /rooms/{id}/invite` |
| `_SendEventHandler` | `PUT /rooms/{id}/send/{type}/{txn}` |
| `_RoomStateHandler` | `GET /rooms/{id}/state`, `/members` |
| `_ReceiptHandler`, `_TypingHandler` | receipts, read markers, typing |
| `_ResolveAliasHandler`, `_PublicRoomsHandler` | the directory |
| `_UploadKeysHandler`, `_QueryKeysHandler`, `_UploadCrossSigningKeysHandler`, `_UploadSignaturesHandler` | encryption keys |
| `_ClaimKeysHandler`, `_SendToDeviceHandler` | device-to-device |
| `_CreateKeyBackupHandler`, `_KeyBackupVersionHandler` | key backup |
| `_SetAccountDataHandler`, `_GetAccountDataHandler` | account data |
| `_ProfileHandler`, `_WhoamiHandler`, `_AuthedJSONHandler` | small reads |
| `_UnrecognizedHandler` | everything else, as `M_UNRECOGNIZED` |

Three tiny actors exist only to absorb an answer nobody is waiting for:
`_IgnoreRelay`, `_IgnoreDeparture`, `_DeclaredThen`.

---

## Classes that carry state

These are not actors. They are owned by one actor and never shared mutably.

### `RoomState` — `class ref`

What a room is: who is in it and what its current state says. **No actor
and no clock**, so every rule in it is reachable from a test.

- `_state`: kind → state key → `RoomEvent`, the current state
- `_members`: who has joined
- `_invited`: who may join and has not

`leave` removes a member **and** the membership event that named them, in
one call, because membership is recorded twice here and a caller that
updated one would leave the room disagreeing with itself.

**No messages.** A room fans an event out and keeps nothing. A client that
was not a member when an event was sent will never see it.

### `Pending[A: Any val]`

A bounded queue of `(position, value)` pairs. Used for room events and, per
sender, for to-device messages. It counts what it evicted, so a device can
tell a client its timeline has a gap.

### The validated identifier types

`RoomId`, `EventId`, `DeviceId`, `AccessToken`, `RoomAlias`, `Localpart`.
Each has a private constructor and a factory that can refuse, so an invalid
one cannot be built. They exist because a room id, an event id and a user
id are all text and arrive at handlers side by side, where nothing but
parameter order would keep them apart.

`AccessToken` is **structurally unprintable** — not `Stringable`, no
`string()`, and exactly one `reveal()` in production — so it cannot be
logged by accident.

### Other values

`Config`, `Credentials`/`Credential`, `Bridges`/`BridgedChannel`/`BridgedNetwork`/`NameMapping`,
`CreateRoomRequest`, `RoomEvent`, `SyncView`, `Ephemeral`/`Receipt`,
`ToDeviceEvent`, `Session`, `StreamEpoch`, `Homeserver`, `RoomSummary`,
`KeyBackup`.

---

## The receiver protocol

Around thirty one-method interfaces name what may come back from an ask.
They are the reason a handler never blocks: it hands `this` to a
long-lived actor and gets a behaviour call later.

```mermaid
graph LR
    H[handler] -->|"resolve(token, this)"| SR[SessionRegistry]
    SR -->|"token_resolved(session)"| H
    SR -->|"token_rejected()"| H
```

The most-used are `UserReceiver` (token resolution), `RoomLookupReceiver`,
`EventReceiver`, `MembershipReceiver`, `SyncReceiver`, `StateReceiver`,
`BridgedRoomReceiver`, `JoinReceiver` and `RoomMember`.

`RoomMember` is the important one: it is the room's entire view of a
member — `deliver`, `joined`, `departed` — and both `User` and `UserLink`
satisfy it.

---

## Operations

### Startup

```mermaid
sequenceDiagram
    participant Op as operator
    participant M as Main
    participant RD as RoomDirectory
    participant HS as hobby.Server

    Op->>M: marilwyd serve --server-name … --asset-root … --credentials …
    M->>M: Configure(args) → Config or StartupError
    Note over M: refuses a credentials file others can read,<br/>or one inside --asset-root
    M->>RD: declare(channel, network, this) per bridged channel
    RD-->>M: channel_declared / declaration_refused
    Note over RD: records the channel by alias.<br/>No room is made and nothing connects.
    M->>HS: Server(auth, routes, this)
    HS-->>M: listening(host, port)
    M->>Op: marilwyd, listening on host and port
```

### Login

```mermaid
sequenceDiagram
    participant C as client
    participant LH as _LoginHandler
    participant SR as SessionRegistry
    participant U as User
    participant D as Device

    C->>LH: POST /login {user, password}
    LH->>LH: CheckLoginShape — size, then depth, before parsing
    alt account exists
        LH->>LH: Credential.verify — PBKDF2, ConstantTimeCompare
    else unknown account
        LH->>LH: _Decoy.verify — same cost, so the two are indistinguishable
    end
    LH->>SR: issue(user_id, requested_device, this)
    SR->>SR: MakeAccessToken(), pick or mint a DeviceId
    Note over SR: a second login on one device replaces the first,<br/>so one device never holds two tokens
    SR-->>LH: token_issued(token, device)
    LH-->>C: 200 {access_token, device_id, user_id}
    Note over SR,D: User and Device are made on the first<br/>authenticated request, not here
```

### Sync — answered at once

```mermaid
sequenceDiagram
    participant C as client
    participant SH as _SyncHandler
    participant SR as SessionRegistry
    participant D as Device

    C->>SH: GET /sync with since and timeout
    SH->>SR: resolve(token, this)
    SR-->>SH: token_resolved(session)
    SH->>D: sync(since, wait, this)
    D->>D: anything owed? pending, to-device, state, ephemeral, invites
    D-->>SH: synced(view)
    SH-->>C: 200 SyncDocument(view)
```

### Sync — parked, then woken

The long-poll. A sync with a position and nothing owed parks; whatever
arrives next wakes it.

```mermaid
sequenceDiagram
    participant C as client
    participant SH as _SyncHandler
    participant T as Timers
    participant D as Device
    participant R as Room
    participant U as User

    C->>SH: GET /sync since=s5, timeout=25000
    SH->>T: arm MaxSyncWait (25 s, under hobby's 30 s watchdog)
    SH->>D: sync(5, 25000, this)
    D->>D: nothing owed → park (_parked, _parked_since)
    Note over D: the request is held, with no response yet

    R->>U: deliver(event)
    U->>D: deliver(event)
    D->>D: _pending.push, then _wake()
    D-->>SH: synced(view) — answered from _parked_since, not as a fresh sync
    SH-->>C: 200 with the event
    SH->>T: cancel

    alt nothing arrives in time
        T-->>SH: waited()
        SH->>D: expired(this)
        D-->>SH: synced(view) — just a position
        SH-->>C: 200 carrying next_batch only
    end
```

### Create a room

```mermaid
sequenceDiagram
    participant C as client
    participant CH as _CreateRoomHandler
    participant RD as RoomDirectory
    participant R as Room
    participant U as User

    C->>CH: POST /createRoom {name?, room_alias_name?, visibility?, initial_state?}
    CH->>CH: bounds, then _CreateRoomWanted → CreateRoomRequest
    CH->>RD: create_room(user_id, user, wanted, this, watching)
    RD->>RD: alias free in BOTH _aliases and _channels?
    RD->>R: new Room(id), then created_by(...)
    R->>R: m.room.create, m.room.name?, m.room.encryption?,<br/>m.room.join_rules, m.room.canonical_alias?
    R->>R: _admit(creator) — state, member, event, then joined
    R->>U: joined(room_id, this)
    R-->>RD: room_created(id)
    RD-->>CH: room_created(id)
    CH-->>C: 200 {room_id}
```

A room is **public** if it was given an alias or asked to be listed, and
**invite-only** otherwise — `m.room.join_rules` records which. Encryption
is written only if `initial_state` asked for it, and only here: there is no
endpoint that sets state on a room that already exists.

### Invite somebody

```mermaid
sequenceDiagram
    participant C as client
    participant IH as _InviteHandler
    participant SR as SessionRegistry
    participant R as Room
    participant U2 as User (invitee)
    participant D2 as Device (invitee)

    C->>IH: POST /rooms/{id}/invite {user_id}
    IH->>R: (via RoomDirectory.with_room) room_found
    IH->>SR: lookup_users([invitee], this)
    SR-->>IH: users_found(known, unknown)
    IH->>R: invite(invitee, by, account?, this)
    R->>R: is `by` a member? otherwise refuse
    R->>R: _state.invite, then an m.room.member invite event
    R->>U2: invited(room_id, state)
    U2->>D2: invited(room_id, state) — and kept, for devices that sign in later
    D2->>D2: _wake()
    R-->>IH: membership_changed(id)
    IH-->>C: 200 {}
```

The invitee sees it in `/sync` under `rooms.invite.{id}.invite_state`,
carrying the room's state and none of its timeline.

### Join a native room

```mermaid
sequenceDiagram
    participant C as client
    participant MH as _MembershipHandler
    participant RD as RoomDirectory
    participant R as Room
    participant U as User

    C->>MH: POST /join/{roomIdOrAlias}
    MH->>RD: for_user(id, user_id, this)
    RD-->>MH: no_such_channel — not a bridged alias
    MH->>RD: with_room(id, this)
    RD-->>MH: room_found(room)
    MH->>R: bridged(this)
    R-->>MH: room_is_local()
    MH->>R: join(user_id, user, this, watching)
    alt invite-only and not invited
        R-->>MH: membership_refused(NotInvited)
        MH-->>C: 403 M_FORBIDDEN
    else public or invited
        R->>R: _admit — state, member, membership event, then joined
        R->>U: joined(room_id, this)
        R-->>MH: membership_changed(id)
        MH-->>C: 200 {room_id}
    end
```

### Join a bridged channel

Membership means connected on both sides, so the Matrix join does not
complete until the IRC channel has been entered.

```mermaid
sequenceDiagram
    participant C as client
    participant MH as _MembershipHandler
    participant RD as RoomDirectory
    participant R as Room
    participant LD as LinkDirectory
    participant UL as UserLink
    participant IRC as IRC network

    C->>MH: POST /join/{channel alias}
    MH->>RD: for_user(alias, user_id, this)
    RD->>R: new Room + declared(...) — this person's own room
    RD-->>MH: bridged_room(room, network)
    MH->>R: bridged(this)
    R-->>MH: room_is_bridged(channel, network)
    MH->>LD: open(user_id, channel, network, room, this)
    LD->>UL: new UserLink, carries(room), directed_by(this), connect(...)
    UL->>IRC: TCP + TLS + registration
    IRC-->>UL: registered
    UL->>IRC: JOIN the channel
    IRC-->>UL: JOIN echo
    UL-->>MH: joined_with(channel, link)
    MH->>R: join(user_id, user, this, watching)
    MH->>R: carry(user_id, link)
    R-->>MH: membership_changed(id)
    MH-->>C: 200 {room_id}

    alt the network refuses, or 25 s passes
        UL-->>MH: join_refused(channel)
        MH->>LD: close(...)
        MH->>R: leave(user_id, this)
        MH-->>C: 403 — they are not in the room at all
    end
```

### Send a message

```mermaid
sequenceDiagram
    participant C as client
    participant SEH as _SendEventHandler
    participant R as Room
    participant U as User
    participant D as Device
    participant UL as UserLink

    C->>SEH: PUT /rooms/{id}/send/m.room.message/{txn}
    SEH->>SEH: _EventContent — size, depth, then parse
    SEH->>R: send(user_id, kind, content, this)
    R->>R: a member? carrier stalled? too many IRC lines?
    R->>R: _append — mint EventId, stamp, apply_state
    par to every member
        R->>U: deliver(event)
        U->>D: deliver(event)
        D->>D: _pending.push, _wake()
    and to every carrier
        R->>UL: deliver(event)
    end
    R-->>SEH: event_sent(id)
    SEH-->>C: 200 {event_id}
```

Refusals, each with its own answer: `NotInRoom` → 403, `NoEventId` → 500,
`BridgeDown` → 502, `TooManyLines` → 400.

### Matrix → IRC

```mermaid
sequenceDiagram
    participant R as Room
    participant UL as UserLink
    participant IRC as IRC network

    R->>UL: deliver(event)
    UL->>UL: sender is my owner? otherwise drop
    UL->>UL: kind is m.room.message? Said() → m.text or m.notice only
    UL->>UL: SplitForIrc — CR/LF first, then 425-byte pieces
    loop each line, paced by the connection
        UL->>IRC: PRIVMSG or NOTICE to the channel
    end
```

A connection relays **only its owner's** words. Everyone else in the room
has their own connection saying their own words — which is why nothing
loops and nothing is attributed to the wrong person.

### IRC → Matrix

```mermaid
sequenceDiagram
    participant IRC as IRC network
    participant UL as UserLink
    participant R as Room
    participant U as User
    participant D as Device

    IRC-->>UL: 353 name list / JOIN / PART / QUIT / KICK / NICK
    UL->>R: admit_ghost(ghost_id, display) / part_ghost(ghost_id)
    Note over R: bounded by MaxRoomMembers — the far side fills this list

    IRC-->>UL: PRIVMSG / NOTICE / CTCP ACTION
    UL->>UL: skip my own nick, then ValidUtf8 and GhostLocalpart
    UL->>R: admit_ghost, then send(ghost, m.room.message, …)
    R->>U: deliver(event)
    U->>D: deliver(event)

    IRC-->>UL: CTCP PING
    UL->>IRC: NOTICE reply — never a PRIVMSG, which would invite an answer
```

An IRC nickname becomes a Matrix id through `GhostLocalpart`, which
escapes anything a localpart may not hold as `=xx` — injectively, so two
different nicknames can never collapse into one Matrix user.

### The connection dies

```mermaid
sequenceDiagram
    participant IRC as IRC network
    participant UL as UserLink
    participant R as Room
    participant LD as LinkDirectory
    participant C as client

    alt transient — the library will retry
        IRC-->>UL: dropped(why)
        UL->>R: carrier_stalled(user_id)
        Note over R: the member keeps the room,<br/>and send refuses with BridgeDown (502)
        IRC-->>UL: registered again → JOIN
        UL->>R: carrier_carrying(user_id)
    else terminal — no further attempt
        IRC-->>UL: died(why)
        UL->>R: leave(user_id, _IgnoreDeparture)
        UL->>LD: forget(user_id, network, channel)
        Note over LD: so the next join opens a fresh connection<br/>rather than being answered with a dead one
    end
```

### Leave

```mermaid
sequenceDiagram
    participant C as client
    participant MH as _MembershipHandler
    participant R as Room
    participant LD as LinkDirectory
    participant U as User

    C->>MH: POST /rooms/{id}/leave
    MH->>R: bridged(this)
    alt bridged
        R-->>MH: room_is_bridged(channel, network)
        MH->>LD: close(user_id, channel, network)
        LD->>LD: drop the entry, and the link parts and quits
    end
    MH->>R: leave(user_id, this)
    R->>R: membership event, remove from members / watching / carrying / stalled
    R->>U: departed(room_id)
    U->>U: every device forgets the room
    R-->>MH: membership_changed(id)
    MH-->>C: 200 {}
```

### Receipts and typing

```mermaid
sequenceDiagram
    participant C as client
    participant RH as _ReceiptHandler
    participant R as Room
    participant U as User
    participant D as Device

    C->>RH: POST /rooms/{id}/receipt/m.read/{eventId}
    RH->>R: read_up_to(user_id, event_id)
    R->>R: last write wins per person
    R->>R: _publish — the whole ephemeral block, not a delta
    loop every watching account
        R->>U: ephemeral(room_id, current)
        U->>D: ephemeral(room_id, current)
        D->>D: _wake()
    end
    RH-->>C: 200 {}
```

Only accounts hear ephemeral state. A bridged user's IRC connection is a
member and has no reading for a receipt.

### Publish and query encryption keys

```mermaid
sequenceDiagram
    participant C as client
    participant UK as _UploadKeysHandler
    participant U as User
    participant D as Device
    participant QK as _QueryKeysHandler
    participant SR as SessionRegistry

    C->>UK: POST /keys/upload {device_keys?, one_time_keys?}
    UK->>U: publish_keys(device_id, keys)
    UK->>D: take_one_time_keys(keys)
    D-->>UK: one_time_keys_held(n)
    UK-->>C: 200 {one_time_key_counts}

    C->>QK: POST /keys/query {device_keys:{user:[…]}}
    QK->>SR: lookup_users(wanted, this)
    SR-->>QK: users_found(known, unknown)
    loop each known account
        QK->>U: published_keys(this, own = user_id == asker)
        U-->>QK: keys_published(user_id, keys)
    end
    QK-->>C: 200 {device_keys, master_keys, self_signing_keys, user_signing_keys?}
```

`own` is the whole of one authorisation rule: the user-signing key is what
an account uses to sign *other* people, so it goes to its owner alone. The
master and self-signing keys are public by design.

### Device to device

```mermaid
sequenceDiagram
    participant A as client A
    participant CK as _ClaimKeysHandler
    participant SR as SessionRegistry
    participant U as User B
    participant DB as Device B
    participant STD as _SendToDeviceHandler
    participant B as client B

    A->>CK: POST /keys/claim {one_time_keys}
    CK->>SR: lookup_users(…)
    CK->>U: claim_keys(device_ids, this)
    U->>DB: claim_one_time_key(user_id, this)
    DB-->>CK: one_time_key_claimed(...) — spent, so never handed out twice
    CK-->>A: 200 {one_time_keys}

    A->>STD: PUT /sendToDevice/{type}/{txn} {messages}
    STD->>U: send_to_device(sender, kind, device_id, content)
    U->>DB: deliver_to_device(event)
    DB->>DB: queue under the SENDING account, then _wake()
    DB-->>B: next /sync carries it under to_device
    STD-->>A: 200 {}
```

---

## Rules that hold everywhere

**Nothing survives a restart.** No account, room, message, session or
invitation is written to disk. Standing bridged channels are declared in
`bridges.yaml` and re-created at startup; everything else is gone.

**A room keeps no messages.** State is kept because a joining member needs
it to render the room at all; history is not.

**Ordering.** Pony guarantees FIFO delivery between one sender and one
receiver, and causal delivery. It does **not** order messages from two
different senders to the same receiver. Several defects in this codebase
came from assuming otherwise, and the fix is always the same: chain through
a round trip rather than assume.

**Cloning at the boundary.** Any string a long-lived actor keeps from a
request is cloned. Under ORCA a foreign reference keeps its owning actor
alive — so storing a handler's string would pin that handler, its
connection, and its request body, which on the login path holds a plaintext
password.

**Refuse rather than half-do.** A message the bridge could only carry part
of, or that arrives while the connection is down, is refused. A client told
its message failed can send it again; one told it succeeded cannot.

**Bounds at the edge.** Every request body is size- and depth-bounded
before parsing, through one checked reader. Every queue an outsider can
feed is bounded, and every per-endpoint limit sits under the transport cap
so that it can actually fire.

**What is not bounded** is stated rather than implied: there is no rate
limit on sending, per user or per room. `SECURITY.md` records it.
