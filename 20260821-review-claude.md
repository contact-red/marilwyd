# marilwyd — ensemble code review

Target: the whole repository at `0f5b394` (branch `kill-a-hung-runner`), from a
clean start. Not a diff. Baseline measured before any reviewer ran: clean build,
no warnings, **260 tests pass**, `pony-lint` clean over both packages, ponyc
0.69.1-38f9f11 release / LLVM 22.1.6.

Nine reviewers, all accepted at triage. Everything below is pre-existing; there
is no change to scope a finding against.

---

## Orientation

marilwyd is a single-process actor-based Matrix homeserver with an IRC bridge,
no database, all state in memory, aimed at a one or two vCPU VPS. Roughly 21,000
lines across two packages.

**Where it is strong.** This is a well-built program and the review found it so
from eight independent directions. The fan-out path genuinely avoids the shared
actors it claims to avoid — `Room._append` and `User.deliver` hold their targets
directly, and no shared actor sits on the per-message path. Authorization is
present on every route and correctly scoped; the Security reviewer walked all 34
rows of `routes.pony` and found the unauthenticated set is exactly what it should
be, with cross-account reads gated inside `SessionRegistry` rather than at the
handler. Injection is closed in both directions — every document is built from
text that was minted internally or run through `JSONPrinter`, and outbound IRC
text is CRLF-split twice over. `AccessToken` is structurally unprintable with one
`reveal()` in production. The CSPRNG discipline fails closed everywhere. The
validated-identifier types, the receiver protocol, `_ObjectBody`, `_SyncHandler`
and `Pending`'s eviction policy are each the right shape for what they do, and
each says why. The async test discipline is unusually careful: `_StepRunner`
sequences rather than assumes, and several test docstrings record real races the
suite once had. Hygiene is a clean sweep — no `TODO`, no `FIXME`, no
commented-out code, three lines over 80 columns in 21,000.

**Where the defects cluster.** Four places, and they are not evenly weighted.

1. **The bounds at the edge do not hold.** `docs/architecture.md` states "Every
   request body is size- and depth-bounded before parsing, through one checked
   reader." That sentence is false on *every* endpoint, for two independent
   reasons — one endpoint never calls the pre-pass, and the pre-pass itself can
   be walked past with a long number literal. This is where the two highest
   findings sit and it is where the review should start.

2. **Written claims and code have diverged.** `SECURITY.md` states two bounds the
   code does not have, claims a timing property that is conditional, claims two
   unbounded stores are bounded, and claims signatures under a foreign user id
   are ignored when only the outer map is scoped. `README.md` states the opposite
   of what login does with a requested device id. `docs/completion.md` says a
   room asked to be private and encrypted comes back public and unencrypted —
   the code reads all four fields and does the right thing. The package docstring
   describes a program two increments old. This is the class the owner holds this
   codebase to, and it is where the strongest prose findings are.

3. **The invitation path.** Declining an invitation is a no-op, the fix exists
   and was never wired up, a pending invitation prevents `/sync` from ever
   parking, and the entire invitation-to-sync path has no test. Four defects,
   one area, one reviewer each side of it.

4. **A request that is never answered is the handler layer's default failure
   mode.** Four reviewers reached this from five directions: nullable-field matches
   with no `else`, a constructor arm that fails silently when forgotten, a parked
   sync receiver overwritten without being answered, and a numeric counter that
   wraps rather than errors. Every one of them ends the same way — hobby's
   30-second watchdog answers a bodiless 504 with no `errcode`, which is the
   exact failure `MaxSyncWait` and the four-method catch-all were both built to
   prevent.

**The pattern behind the prose defects**, which the Wildcard reviewer put best
and which is worth carrying: *prose that lives in a whole document is maintained
here; prose that lives next to the code drifts.* `README.md` and
`docs/architecture.md` were touched in the last two commits of a 37-commit
history and are accurate to the digit — the README's "thirty-five Matrix
endpoints" was independently counted correct twice. `marilwyd/marilwyd.pony` and
the `SessionRegistry` class docstring were last touched at commit 15 of 37 and
have been wrong for twenty-two commits. The fix that matters is not the edits;
it is that a package docstring and a class docstring are not on anyone's
end-of-change checklist.

**On scope**, all nine reviewers converged: nothing is carried that no stated
purpose accounts for, there is no speculative abstraction, no unused extension
point, and the declined features (history replay, message persistence,
registration, federation, the Application Service API) are declined with reasons
recorded. Every scope defect runs the other way — the documentation promises
properties the code does not deliver.

---

## The ten findings that matter most, and why they rank there

1. **`_JSONDeeperThan` can be walked past with a long number literal**
   (`jsondepth.pony:19`). Every depth bound in the server routes through this one
   primitive, including `CheckLoginShape` on unauthenticated `POST /login`. One
   reviewer found it; it was verified by running code twice, independently. It
   ranks first because it is unauthenticated, because it defeats every bound
   simultaneously rather than one, and because it is the reason the stated
   invariant is false everywhere rather than in one place.

2. **`PUT /sendToDevice` has no depth bound at all**
   (`to_device_http.pony:204,218`). Six reviewers, six routes in. It ranks second
   because it is the same invariant broken a second, simpler way — no trick
   needed — and because fixing either one does not fix the other. Two findings,
   not one.

3. **`SECURITY.md` states two bounds the code does not have** (`SECURITY.md:366`,
   `:373`). A prose finding that is a fact about the code, and it sits in the
   same document as the depth claim that findings 1 and 2 falsify. It ranks here
   because of what it costs: a reader who checks two numbers, finds them wrong,
   and stops checking, never gets to the ones that matter.

4. **Declining an invitation does nothing, and a pending invitation prevents
   `/sync` parking** (`room.pony:284`, `device.pony:249`). One reviewer, two
   findings, and they compound — the second becomes permanent because of the
   first. `RoomState.withdraw` is documented as the fix and has no caller
   anywhere in the repository. The consequence is the request storm the long poll
   exists to prevent, at 36 syncs a second per affected client, each paying a
   full `SessionRegistry` scan.

5. **A carrier that drops between `joined_with` and `carry` leaves the room
   believing the bridge is up** (`room.pony:345`). Two reviewers from opposite
   directions. The client is answered `200` with an event id for a message that
   never leaves. That is precisely what `BridgeDown` and the "refuse rather than
   half-do" rule exist to prevent, and `UserLink._finished`'s own docstring names
   this failure as one already fixed once.

6. **`Pending.push` at the cap costs ~0.8 ms, measured** (`pending.pony:48`).
   2,300× the cost of a push below the cap, on the per-event fan-out path, at the
   exact moment the bound was meant to be capping something. The docstring's
   stated rationale for choosing a persistent vector is wrong on both counts.
   Reachable in ordinary use because `POST /logout` leaves the device on the
   fan-out path forever.

7. **`docs/completion.md` states the opposite of what `createRoom` does**
   (`docs/completion.md:162-166`). The most expensive prose in the repository:
   it tells a reader that asking for a private encrypted room silently produces a
   public plaintext one. It is a security claim, it is wrong, and it is in the
   document whose entire job is to say what works.

8. **The login decoy derives at a constant while real entries carry their own
   count** (`_decoy.pony:27`). Four reviewers. `SECURITY.md` and `README.md` both
   state the equal-time property unconditionally; it holds only while every entry
   carries the current default, and the iteration field exists precisely so that
   default can be raised. The shipped test fixture already runs at a 6×
   divergence and no test can notice.

9. **Five stated security or protocol guarantees whose enforcing code can be
   deleted with the suite green** (Tests H1–H5). Reasoned by tracing every
   caller, not by mutation — but the tracing is thorough. Two of the five line up
   exactly with defects other reviewers found, which makes them the highest-value
   test additions in the repository.

10. **Three per-account stores grow without bound behind a token, and
    `SECURITY.md` affirmatively claims two of them are bounded** (`user.pony:247`,
    `:94`, `published_keys.pony:135`). Three reviewers reached parts of this. It
    ranks last of the ten because authenticated resource cost is the class the
    document explicitly leaves to a rate limiter — except that the document says
    these are bounded, which is what lifts it out of that class.

---

## Cross-persona corroboration

Independent traces from different lenses, not one finding echoed. Weight these up.

| # | Finding | Reviewers |
|---|---|---|
| 1 | `sendToDevice` parses with no depth bound | Security F1, Principles F1, Correctness 6, Performance 4, Adversarial F2, API/Design 7 — **six** |
| 2 | `SECURITY.md`'s bounds disagree with the constants | Editor F2, Adversarial F7 |
| 3 | The login decoy's fixed iteration count | Security F6, Wildcard 2, Adversarial F5, Tests M1 — **four** |
| 4 | The package docstring describes a program that no longer exists | Principles F3, Wildcard 5, Correctness 9, API/Design 16 — **four** |
| 5 | `--asset-root` containment is a character prefix | Security F10, Principles F7, Correctness 14, Adversarial F10 — **four** |
| 6 | Unbounded per-account growth behind a token | Security F3/F4/F5, Adversarial F4, Correctness 15 — **three** |
| 7 | `docs/completion.md` contradicts the code, the other docs, and itself | Editor F1/F3, Wildcard 6, Tests L8 |
| 8 | A never-answered request becomes a bodiless 504 | Correctness 7, Adversarial F6, API/Design 10, API/Design 14 — **four**, with Tests L4 supplying the coverage gap |
| 9 | A bare `try` with no `else` swallows a check | Principles F2, Security F10, API/Design 4, API/Design 24 — **three** |
| 10 | The bridge's configuration is undocumented and `make run` needs it | API/Design 2+3, Wildcard 8, Editor F14 |
| 11 | The `event_refused` union is spelled by hand at every implementor | API/Design 9, Principles F9 |
| 12 | Room membership keys stored without cloning | Correctness 8, Principles F5 |
| 13 | `README.md` and the class docstring say a device id is never reused | Security F7, Wildcard 7 |
| 14 | `docs/architecture.md` claims a factory shape `Localpart` does not have | API/Design 18, Principles F6 |
| 15 | `SessionRegistry` is the one actor every request funnels through | Performance 3, Security F9 |

Counts are of **reviewers**, not of findings — where one reviewer filed two
findings against the same defect (API/Design in clusters 8 and 9) it counts once.

Clusters 8, 9, 10, 11, 14 and 15 are additions to the orchestrator's list.
Cluster 8 in particular is the largest un-named pattern in the review: four
reviewers reached one structural problem from four directions and none of them
saw it as structural.

---

## Patterns worth naming before the findings

**A. Eight reviewers checked whether the depth primitive was *called*; one
checked whether it *works*.** Security enumerated every `JSONParser.parse` call
site and concluded exactly one was unguarded. Performance listed
`_JSONDeeperThan` under **Passes**. Principles tabulated the bound for every
endpoint. All three were right about the call graph and all three took the
primitive's contract on trust. That is the single most instructive result in this
round, and it argues for the same treatment of the other primitives whose
contracts everything else depends on — `ConstantTimeCompare`, `ValidUtf8`,
`_Upward`, `ReadStreamPosition`. (Adversarial and Security did attack the latter
three and found them sound.)

**B. Five small findings, one structural problem: the handler layer's default
failure mode is silence.** `var _session: (Session | None)` re-matched without
an `else` across ten handlers; a `MissingToken()` constructor arm that fails
silently when forgotten, in 26 near-identical copies; `_expected = _expected - 1`
on a `USize` that wraps rather than errors; `Device.sync` overwriting a live
parked receiver; `_InviteHandler.users_found`'s bare `return`. None is reachable
today. All five make "forgot to answer" the cheap mistake in the most-copied
structure in the codebase, and all five produce the same client-visible outcome.

**C. Four sites where a bare `try … end` makes a failed check indistinguishable
from a passed one.** Two are security checks (`config.pony:258`, `:311` — a
`FileInfo` failure silently skips the credentials and bridges permission
refusal). One is an invariant (`link_directory.pony:89` — a transposed-argument
`close` builds a key nothing matches and the IRC connection stays open after the
Matrix user left). One is the twin of the first. The pattern is the finding.

**D. Prose next to code that argues for behaviour the code does not have.** This
is distinct from stale prose. `ephemeral.pony:112` carries a comment stating that
an empty `m.typing` "has to be sent when the last person stops", directly above
an `if` that ensures it never is. `pending.pony:31` justifies a persistent vector
by structure sharing that `remove(0, n)` defeats and that no consumer uses.
`profile.pony:31` describes un-escaping that does not exist anywhere in the
repository, contradicting a correct docstring 30 lines above it. In each case the
comment is the strongest available evidence that the code is wrong.

**E. Tests that pin the wrong behaviour, or pass on an empty response.**
`_ExpectNoEphemeral` asserts `rendered.contains("m.typing")` is false, locking in
finding M-3 below. `_TestUnknownUserIsIndistinguishable` cannot make its intended
assertion because the fixture writes entries at `Pbkdf2MinIterations()` while the
decoy burns `Pbkdf2Iterations()`. Two tests assert only negations and pass when
the server never answers at all.

**F. Test gaps that line up with defects other reviewers found.** These are the
highest-priority test additions in the repository, and they are named as such in
each finding below:
- `to_device_http_tests.pony` has no depth test → findings C-1 and H-1. Note that
  no existing depth test could catch C-1 either: `login_limit_tests.pony:122`'s
  `_Nested` helper builds `{"a":{"a":…` with no number in it.
- The whole invitation-to-sync path is untested (Tests H2) → findings H-3 and H-4.
- `LinkDirectory` is never exercised (Tests M3) → findings H-5 and M-9.
- Four startup refusals are untested (Tests H3) → finding M-9.
- Device reuse on login is untested (Tests H4) → finding M-14.
- The login timing defence is untested (Tests M1) → finding M-1.

---

# Findings

## Critical

### C-1 — `_JSONDeeperThan` answers `false` for any body carrying a number literal over 256 bytes, defeating every depth bound in the server

**Location**: `marilwyd/jsondepth.pony:19` (the `JSONTokenParser(counted)`
construction), with the swallowing `try` at `:20-27`

**Personas**: Adversarial F1 (sole finder). Independently reproduced by the
orchestrator against unmodified `marilwyd/jsondepth.pony`.

**Finding**: The pre-pass constructs `JSONTokenParser(counted)` and takes the
default `JSONParseLimits`, which caps `max_number_len` at 256 bytes
(stdlib `packages/json/json_parse_limits.pony:32-39`). A longer number literal
raises out of `feed()` (`json_token_parser.pony:507`); the bare `try … end`
swallows the raise; `counted.exceeded` is still `false`; the caller concludes
the body is within depth. The real parse that follows is `JSONParser.parse`,
which uses `JSONParseLimits.unlimited()` (`json_parser.pony:26`). The pre-pass is
therefore strictly *stricter* than the parse it guards, and hitting one of its
own limits is indistinguishable, at the call site, from a shallow document.

Put the long number **before** the nesting and the depth counter never sees a
container at all.

**Evidence** — measured, by running an exact copy of the primitive against ponyc
0.69.1, and separately reproduced by the orchestrator:

```
plain deep body (4,000 levels), limit 8            -> deeper? true
same body with a 300-digit number first, limit 8   -> deeper? false
JSONParser.parse on that body                      -> BUILT THE WHOLE TREE
```

Cost of what then gets built, max RSS measured in an isolated harness:

| body | shape | held concurrently | max RSS |
|---|---|---|---|
| 4,091 B | 300-digit number + 1,890 levels | 100 | **82 MB** |
| 32,511 B | 300-digit number + 16,100 levels | 50 | **324 MB** |

The first row is the `/login` shape and needs **no credential**:
`MaxLoginBody()` is 4,096 (`login_limits.pony:17`), `POST /login` is
unauthenticated (`routes.pony:93`), and its depth check routes through this
primitive (`login_limits.pony:71`). `SECURITY.md`'s "Cost of a login attempt"
measures the *post-fix* figure at 30 MB for 100 concurrent bodies. The real
figure with this bypass is 82 MB, and the 32 kB and 49 kB authenticated
endpoints amplify it roughly 200×.

Blast radius — every depth bound in the server:

| Caller | Endpoint | Auth |
|---|---|---|
| `CheckLoginShape` | `POST /login` | **none** |
| `_EventContent` | `PUT /rooms/{id}/send/…`, `PUT …/account_data/{type}` | token |
| `_CreateRoomHandler` | `POST /createRoom` | token |
| `_ObjectBody` | `keys/upload`, `keys/query`, `keys/device_signing/upload`, `keys/signatures/upload`, `keys/claim`, `room_keys/version`, `delete_devices`, `invite`, `read_markers`, `typing` | token |

`MaxBodyDepth`'s own docstring names exactly the document this lets through:
"Sixty-four kilobytes of `[[[[` is a legal document a few characters wide and
thousands of levels deep, and it is the parser's recursion that costs."

**Why Critical, above the finder's own High.** Adversarial rated this in
isolation. Combined with the six-reviewer finding that `docs/architecture.md`
asserts the property universally, and with the fact that this is the single
chokepoint every bound passes through, the reach is larger than any one reviewer
saw: the stated invariant is true on *no* endpoint unconditionally. It is the
only unauthenticated remote memory-exhaustion path in the program, it needs a
4 kB request, and it silently reopens a hole `SECURITY.md` records as measured
and fixed. Judged against what marilwyd is — a hobby server that restarts freely
— the process dying is cheap; a bound that reads as present and is absent is not.

**Suggested fix**: construct the pre-pass with `JSONParseLimits.unlimited()`.
`_JSONDepth` is already the depth bound and does not need a weaker one
underneath it. Distinguishing "the parser raised" from "the document is shallow"
would also work, but it changes the documented contract ("Malformed JSON is not
this primitive's business"), so the limits fix is the right one.

**Test**: no existing test can catch this — `login_limit_tests.pony:122`'s
`_Nested` helper builds `{"a":{"a":…` with no number in it, so every depth test
in the suite exercises the path where the pre-pass does work. Add a
number-literal variant to `_Nested` and the existing depth tests become
regression tests for this.

---

## High

### H-1 — `PUT /sendToDevice/…` parses its body with no depth bound at all

**Location**: `marilwyd/to_device_http.pony:204` (the size check) and `:218`
(the parse)

**Personas**: Security F1, Principles F1, Correctness 6, Performance 4,
Adversarial F2, API/Design 7 — six reviewers, six independent routes in. Not
averaged: Principles and Adversarial rated it High, the other four Medium, and
the evidenced higher severity stands.

**Finding**: This is the one body-reading endpoint that neither uses
`_ObjectBody` nor calls `_JSONDeeperThan` itself. Size is checked; depth is not.
No long-number trick is needed — plain nesting reaches `JSONParser.parse`, which
takes `JSONParseLimits.unlimited()`.

```pony
if _body.size() > MaxToDeviceBody() then      // 49,152 — size only
  _respond(…)
else
  _dispatch(session, kind)
end
…
fun ref _dispatch(session: Session, kind: String) =>
  match JSONParser.parse(String.from_array(_body))
```

**Evidence**: Every other body path is bounded on both axes — `_ObjectBody` does
size then depth then parse (`login_limits.pony:117-124`), `_EventContent` does
its own `_JSONDeeperThan` (`rooms.pony:213-226`), `_CreateRoomHandler` does its
own (`rooms.pony:303`), `CheckLoginShape` does both (`login_limits.pony:66-72`).
`_ClaimKeysHandler`, **in the same file**, does it correctly at
`to_device_http.pony:47`. Enumerating every `JSONParser.parse` over a request
body confirms `to_device_http.pony:218` is the only unguarded one.

Measured with a 49,013-byte body of 24,500 levels, 10 held concurrently:
**104 MB max RSS**, ~10 MB per in-flight request. A hundred concurrent is ~1 GB
on a box the README aims at one or two vCPUs. (Measured in an isolated harness,
not against the running server.)

Two shipped claims are false here:
- `docs/architecture.md:793`: "**Bounds at the edge.** Every request body is
  size- and depth-bounded before parsing, through one checked reader."
- `login_limits.pony:92-107`, `_ObjectBody`'s own docstring: the bounds "were
  missed on eleven endpoints while a docstring said every one of them was
  covered — which is the kind of claim that stops the next person checking."
  This is the twelfth.

Secondary defect in the same block: the oversize refusal answers
`MalformedKeys.message()` — "Key uploads must be a JSON object" — for a
`sendToDevice` body that is too large. Wrong on both counts: it is not a key
upload, and the problem is not the shape.

**This is a separate finding from C-1.** Fixing the pre-pass does not fix this
endpoint, and fixing this endpoint does not fix the pre-pass.

**Suggested fix**: `match \exhaustive\ _ObjectBody(_body, MaxToDeviceBody())` in
place of the hand-rolled size check and bare parse. The handler already answers a
single `M_BAD_JSON` for both failures, so it loses nothing. Give it its own
refusal text.

**Test**: `to_device_http_tests.pony` has no depth test at all — grepping the
whole suite for `Depth`/`nested` returns nothing from that file, while every
other depth-bounded endpoint has one. Adding it is the highest-value single test
in the repository.

---

### H-2 — `SECURITY.md` states two resource bounds the code does not have

**Location**: `SECURITY.md:366` and `SECURITY.md:373`, against
`marilwyd/published_keys.pony:16` and `marilwyd/to_device.pony:27`

**Personas**: Editor F2 (High), Adversarial F7 (Medium). Not averaged — Editor
rated it High with the source cited, so it is High.

**Finding**: This is a prose finding that is a fact about the code, and it
belongs here rather than with the documentation.

| `SECURITY.md` says | code says |
|---|---|
| "A key upload is refused past `MaxKeysBody()` — **131,072 bytes**, against the 12,698 a real Element upload measures" | `MaxKeysBody() => 49_152` |
| "A `sendToDevice` request is refused past `MaxToDeviceBody()`. One request may name many devices, so that is **larger than the key-upload bound rather than equal to it**." | `MaxToDeviceBody() => 49_152` — equal |

**Evidence**: Verified directly. `published_keys.pony:16` is `49_152`;
`to_device.pony:27` is `49_152`. The code records both changes in its own
docstrings, which is what makes this a lag rather than a disagreement:
`published_keys.pony:11-15` says 131,072 was "twice the transport cap — so it
could never fire", and `to_device.pony:20-25` says the to-device bound was made
equal because under a 64 kB transport cap "there is no room for a meaningful
difference".

Both mismatches point the safe way — the code is stricter than the document — so
nothing is exploitable. What is damaged is the document's usefulness as an audit
target. The 131,072 figure is worse than merely stale: it advertises a bound the
code abandoned *because it could never fire*. And this is the same document that
carries the depth-bound claim C-1 and H-1 falsify. A reader who checks these two
numbers, finds them wrong, and stops checking never reaches the ones that matter.

Every other numeric bound in `SECURITY.md` was checked and is correct
(`PendingLimit()` 1000, `ToDeviceLimit()` 100, `MaxSyncWait()` 25,000 ms, the
128-bit room id, `IrcLineBudget` 425, and the credential-validation
at-least/exactly distinctions). Only these two are wrong.

**Suggested fix**: state `MaxKeysBody()` as 49,152 and `MaxToDeviceBody()` as
equal to it, with the transport-cap reason. Better, follow the form the
surrounding paragraphs already use for `PendingLimit()` and `ToDeviceLimit()` —
name the primitive without the literal, which is the form that cannot go stale.

---

### H-3 — Declining an invitation does nothing, and the fix exists unwired

**Location**: `marilwyd/room.pony:284-301`, `marilwyd/room_state.pony:69-75`,
`marilwyd/user.pony:306-317`, `marilwyd/device.pony:203-223`

**Personas**: Correctness 1 (sole finder)

**Finding**: `POST /rooms/{roomId}/leave` on a room the caller was invited to but
has not joined is how Matrix spells "decline this invitation" — it is what
Element's Decline button calls. `Room.leave`'s entire body is guarded by
`_state.is_member(user_id)`, and an invitee is in `_invited`, not `_members`
(`room_state.pony:60-64`). So the whole body is skipped and the handler answers
`200` (`rooms.pony:570`).

**Evidence**: Verified. Three pieces of state survive the decline:

- `RoomState._invited` still holds the user, so the invitation was never spent
  and they may still join later.
- `User._invites` still holds the room. It is removed only in `User.joined`
  (`user.pony:285-293`); `User.departed` is not reached because `Room.leave`
  only calls it for actual members.
- `Device._invites` still holds the room. It is removed only in
  `Device.room_state` (`device.pony:174-176`), which a room sends on join.
  `Device.forget_room` (`device.pony:203-223`) removes `_state`, `_described`,
  `_ephemeral` and `_ephemeral_at` — not `_invites`.

`Device._pending_invites()` renders every entry into every sync
(`device.pony:444-457`, `documents.pony:328-362`), so the declined invitation
reappears in the client's room list on every sync for the life of the process.

The strongest corroboration is that the fix is written and not wired.
`RoomState.withdraw` (`room_state.pony:69-75`) is documented as "Drop an
invitation that was refused, or that its holder left behind" and has **no caller
anywhere in the repository** — confirmed:

```
$ grep -rn withdraw --include=*.pony .
marilwyd/room_state.pony:69:  fun ref withdraw(user_id: String) =>
```

**Suggested fix**: add an `elseif _state.is_invited(user_id)` branch to
`Room.leave` calling `_state.withdraw(user_id)`, and a `User` behaviour that
drops the invitation and fans out to the devices the way `invited` does.

**Test**: this is inside the largest untested area in the repository. Tests H2
records that the whole invitation-to-sync path — `Room.invite`, `User.invited`,
`Device.invited`, `_pending_invites`, `documents._Invites`, the `invite_state`
block, and `Device.room_state`'s invitation clearing — has no test reaching any
of it. `grep -rn "invite_state\|invites" marilwyd_test/` returns nothing. The
one invite test asserts a 200 and that the invitee could then join; it never
syncs the invitee.

---

### H-4 — A pending invitation stops `/sync` ever parking

**Location**: `marilwyd/device.pony:249` (the `(_invites.size() > 0)` disjunct in
the park condition at `:248-260`)

**Personas**: Correctness 2 (sole finder)

**Finding**: Every other disjunct in the park condition is a *change since the
client's position*. `_invites` is not. `_pending_invites()`'s own docstring
(`device.pony:444-451`) says invitations are deliberately "Not stamped like room
state is" and are re-sent "on every sync until it is answered". So
`_invites.size() > 0` is a standing condition, not a change, and while it holds
`Device.sync` answers immediately every time.

**Evidence**: Verified — the condition reads exactly as reported.

The effect is the request storm the long poll exists to prevent.
`_SyncHandler.token_resolved` arms its deadline and calls `stream.sync(...)`
(`sync.pony:198-202`); the device answers at once; `synced` cancels the timer and
responds (`sync.pony:216-221`); the client re-asks. `MaxSyncWait`'s docstring
measures the immediate-answer behaviour at "36 syncs a second against Element
1.12.25". Each cycle also pays a full linear `SessionRegistry.resolve` scan,
which the registry's own docstring measures at 0.45 µs per stored session and
describes as the quadratic cost of the design. `SECURITY.md`'s "Cost of a held
sync" is written on the assumption that a settled client holds one connection for
25 seconds.

Reachable in entirely ordinary use: invite somebody and wait for them to decide.
**H-3 makes it permanent**, because a declined invitation is never removed.

**Suggested fix**: stamp invitations with the device position the way `_described`
and `_ephemeral_at` are stamped, and make the disjunct
`_invites_since(since).size() > 0`. Re-sending on every sync can be kept for the
*answer* while the *wake* condition tests only whether something changed.

**Test**: same gap as H-3 — `device.pony:249` is explicitly named in Tests H2 as
untested code. The cheapest instrument mirrors `_TestJoiningWhileSyncingIsTold`:
park a `Device`, `Room.invite` its user, assert the woken `SyncDocument` carries
`invite_state`, and assert a second sync with a fresh position parks.

---

### H-5 — A carrier that drops between `joined_with` and `carry` leaves the room believing the bridge is up

**Location**: `marilwyd/room.pony:345-357` (`carrier_stalled`'s guard), with
`marilwyd/rooms.pony:536-548` and `marilwyd/user_link.pony:597-645`

**Personas**: Adversarial F3 (High), Correctness 5 (Medium). Not averaged —
Adversarial rated High with a concrete sequence and the architecture doc states
the rule this breaks.

**Finding**: `docs/architecture.md` states it: "Pony … does **not** order
messages from two different senders to the same receiver. Several defects in this
codebase came from assuming otherwise, and the fix is always the same: chain
through a round trip rather than assume." `_MembershipHandler.joined_with` sends
`room.join` then `room.carry`, which are FIFO with respect to each other — but
`UserLink` also talks to the same `Room` directly, and those are unordered
against the handler's.

```pony
be carrier_stalled(user_id: String) =>
  if _carrying.contains(user_id) then
    _stalled.set(user_id)
  end
```

**Evidence**: Two reachable outcomes.

**(a) A stall is lost.** `UserLink._watch_for_join` clears `_waiting` and sends
`joined_with` (`user_link.pony:308-313`). The connection drops before the
handler's `carry` reaches the room — a K-line, an `ERROR :Closing link`, a
netsplit right after the JOIN echo. `dropped` finds `_waiting` already `None` and
sends `room.carrier_stalled(_user_id)` (`user_link.pony:626-628`). `_carrying` is
empty, so the guard discards it. `join` and `carry` then land and the room
believes the carrier is healthy. `Room.send` passes all three checks, mints an
event id, answers `200 {"event_id":"$…"}`; `UserLink.relay` finds `_sending` is
`None` and prints "a message was lost as … went away" to the operator's stdout.
That is exactly what `BridgeDown` exists to prevent — `room_refusal.pony:22-33`
states the rule as "A client that is told the message failed can send it again;
one that is told it succeeded cannot." The window closes when the library
reconnects, which is seconds to tens of seconds of backoff.

**(b) A terminal death is lost, permanently.** Same start, but the connection
dies terminally: `died` calls `_finished` (`user_link.pony:631-645`), which sends
`room.leave(_user_id, _IgnoreDeparture)` and `directory.forget(...)`. If `leave`
reaches the room before `join`, the caller is not yet a member and the whole body
is skipped. `join` and `carry` then land. The result is a member of a bridged
room whose carrier is a dead `UserLink`, with `_stalled` empty and the
`LinkDirectory` entry already forgotten — nothing will ever tell the room again.
Sends are accepted and go nowhere for as long as the user stays in the room.
`LinkDirectory.forget`'s own docstring describes this exact state: "That join
succeeded, the room accepted messages, and none of them went anywhere."

`UserLink._finished`'s docstring names this class of failure as one already fixed
once: "Leaving any of those out is how a dead connection went on looking alive —
the room accepted messages nobody received."

**Confidence**: the mechanism is not in doubt and the ordering rule is the one the
repository states for itself. Neither reviewer built a harness that forces the
interleaving, so the *frequency* is unestablished. A netsplit immediately after a
JOIN echo is ordinary IRC.

**Suggested fix**: make `UserLink` the single sender for everything the room
learns about its carrier. It already holds `_room` from `carries(room)`, so it
can send `carry` itself once its own JOIN comes back, before answering
`joined_with`; `carrier_stalled`, `carrier_carrying` and the `leave` in
`_finished` are then FIFO-ordered behind it. That is the round trip the
architecture doc prescribes.

**Test**: `link_tests.pony` exercises `BridgeDown` but never the
`carrier_stalled`-before-`carry` interleaving. This also sits inside Tests M3 —
`LinkDirectory` is constructed five times in the harnesses and never exercised;
no test calls `open`, `close` or `forget`, and `LinkDirectory.forget`'s body can
be deleted with all 260 tests green.

---

### H-6 — `Pending.push` at the limit costs ~0.8 ms per event, measured

**Location**: `marilwyd/pending.pony:48-80` (`push`); hot caller
`marilwyd/device.pony:144-152` (`Device.deliver`), with
`marilwyd/session_registry.pony:140-153` (`revoke`)

**Personas**: Performance 1 and Performance 2 — the cliff and the thing that
makes it reachable. Performance 2 is a distinct defect from the unbounded stores
in M-2 and is credited here rather than there.

**Finding**: Once the queue holds `limit` entries, every subsequent push is
`remove(0, 1)` on a `limit + 1` element persistent vector.
`collections/persistent.Vec.remove` (ponyc 0.69.1, `vec.pony:94-104`) is one
`pop` followed by `_size - 1` `update` calls, and each `update` is a HAMT path
copy (`_vec_node.pony:65-73`) — two 32-slot array clones, two `_VecNode`
allocations, and a fresh `Vec` per element.

**Evidence** — **measured**, standalone program, ponyc 0.69.1 release, same
toolchain, same call pattern:

| case | cost |
|---|---|
| plain `Vec.push` below the cap | **311 ns** |
| `push` + `remove(0,1)` at a 100-element cap (`ToDeviceLimit()`) | **76 µs** |
| `push` + `remove(0,1)` at a 1000-element cap (`PendingLimit()`) | **847 µs** |
| same at 1000, with a traced `class val` element | **735 µs** |

Linear in the cap, as the source predicts; roughly **2,300×** a push below the
cap. The last row confirms it is not an artefact of untraced harness elements.

`Device.deliver` runs for every room event, for every member, for every device
(`Room._append` → `User.deliver` → `Device.deliver`). `PendingLimit()` exists
precisely for the device "that is offline… the only thing in marilwyd that grows
without anyone asking it to" — so the bound converts a memory cost into a
per-event CPU cost of the same shape, at the exact moment it was meant to be
capping something. A Pony mailbox is unbounded: a `Device` that cannot keep up
backs its own mailbox up, and the backlog holds the very `RoomEvent` references
`PendingLimit` was dropping. The bound does not bound the mailbox.

**The docstring's rationale is wrong on both counts** (`pending.pony:31-35`): "A
persistent vector, so handing a device the events it is owed leaves the queue
valid while the next arrival builds a version sharing almost all of its
structure." First, `remove(0, n)` defeats the structure sharing — it rebuilds
every element after the removal point. Second, the sharing has no consumer:
`Pending` values appear at three sites, all fields of one `Device`
(`device.pony:21`, `:67`, `:139`), no `Pending` is ever sent to another actor,
and `since()`/`paired()` copy into a fresh `Array` before anything leaves. The
persistence is paid for and not used.

**Reachability** is what makes this High rather than a note. `POST /logout`
removes only the `_Session` from `_sessions` (`session_registry.pony:140-153`);
`_streams` and `User._devices` are untouched, so an ordinary sign-out leaves the
`Device` actor on the fan-out path forever. A login naming no `device_id` mints a
fresh one, so repeated sign-in/sign-out accumulates one live device per cycle,
each filling to `PendingLimit()` and then costing 0.8 ms per event permanently.
The compound is R rooms × D dead devices × 0.8 ms of scheduler work per message.
`SECURITY.md`'s "Cost of published keys" acknowledges the device accumulation and
frames the whole cost as *memory*; it does not say each accumulated device stays
on the delivery path.

**Suggested fix**: `Pending` is owned by one actor and never shared, so it does
not need a persistent structure. A ring buffer over a mutable `Array`, or an
`Array` plus a head index, gives O(1) head removal. `collections.List` also has
O(1) `shift`. If the persistent shape is kept for its own sake, dropping a block
rather than one entry lowers the constant and leaves the asymptotics alone.
Separately, either bound registered devices per account (evicting the
least-recently-synced) or state plainly in `SECURITY.md` that a signed-out device
stays on the fan-out path.

**Test**: nothing exercises `PendingLimit()`'s default of 1000 — both bound tests
pass explicit limits of 3 and 2 (`room_tests.pony:111-161`), so changing
`PendingLimit()` to any value above about ten leaves the suite green.
`SECURITY.md` states the figure as a guarantee.

---

### H-7 — `docs/completion.md` states the opposite of what `createRoom` does

**Location**: `docs/completion.md:162-166`, with the same claim in table form at
`:131`

**Personas**: Editor F1 (High), Wildcard 6

**Finding**: Highest-ranked prose defect, because it misleads in the most
expensive direction available.

> `createRoom` is the one to watch. Element sends `preset`, `join_rules`,
> `guest_access` and `m.room.encryption`; marilwyd reads `name` and ignores the
> rest, so a room a client asked to make private and encrypted comes back public
> and unencrypted. Nothing renders that yet, and it becomes a lie the moment
> something does.

Three of those clauses are false at HEAD. `rooms.pony:68` reads
`room_alias_name`, `:77` reads `visibility`, `:101-128` walks `initial_state` for
`m.room.encryption` and defaults the algorithm when none is named;
`create_room_request.pony:22` carries `encryption: (String | None)`. And a room
made with no alias and no `visibility: public` is invite-only, not public —
`room.pony:139-145` writes `m.room.join_rules` accordingly, and `SECURITY.md:251`
and `README.md:25` both say so.

**Evidence**: The same repository contradicts this paragraph in three other
places. `docs/next-increment.md:46-52` heads a section "Rooms are not encrypted,
and `createRoom` says otherwise" and opens the body with "**Done.**"
`README.md:34-40` says a room asked to be encrypted is created with
`m.room.encryption`. `rooms.pony:294-298` says the same in a comment.

A reader who trusts this concludes that asking for a private encrypted room
silently produces a public plaintext one. That is a security claim, it is wrong,
and it is in the document whose entire job is to say what works.

**Suggested fix**: rewrite the paragraph to what the code does — `name`,
`room_alias_name`, `visibility` and `m.room.encryption` in `initial_state` are
read; `preset`, `join_rules` and `guest_access` are dropped; join rules follow
from whether the room asked to be found. Update the `:131` table cell. Do not
re-add "it becomes a lie the moment something does" — the code has left that
state.

---

### H-8 — Five stated guarantees whose enforcing code can be deleted with the suite green

**Location**: `room.pony:258-261`; the invitation path (see H-3, H-4);
`config.pony:249-256`, `:258-266`, `:300-307`, `:309-318`;
`session_registry.pony:246-255` and `:298-311`; `stream_position.pony:54-103`

**Personas**: Tests H1–H5

**Finding**: Five properties the documentation states as guarantees have no test
that would notice their removal. Each claim below was established by grepping
every caller and reading the tests that reach it — **reasoned, not verified by
mutation**, because the Tests reviewer was forbidden from editing the repository.
It said so; I repeat it here.

- **H1 — "Only a member may invite" is untested.** `Room.invite` has exactly one
  caller (`rooms.pony:940`), `_InviteHandler` performs no membership check of its
  own, and the one invite test has the room's *creator* issue the invitation, so
  `by` is always a member. Delete `room.pony:258-261` and 260 tests still pass;
  with it gone, any signed-in account holding a room id could add third parties
  to a room it is not in — the exact outcome `SECURITY.md` names.
  *Fix: one `_ServeSteps` case, modelled on `_TestAClosedRoomRefusesAStranger`.*

- **H2 — The whole invitation-to-sync path is untested.** See H-3 and H-4;
  `Device.invited` could be `=> None` and the suite stays green.

- **H3 — Four startup refusals claimed in `SECURITY.md` are untested.**
  `credentials-in-asset-root`, `credentials-permissions`, `bridges-in-asset-root`
  and `bridges-permissions`. The only `StartupError.cause` values asserted
  anywhere are `bind-port`, `bridge-network-name`, `server-name`, and the
  `credentials-*` causes that come out of `ReadCredentials`'s *content*
  validation — never out of `_ReadCredentialsFile`'s permission and location
  checks. Each block can be deleted with 260 tests green. These are the difference
  between a password-hash file that is private and one served unauthenticated to
  the internet. *This lines up with M-9 below: the same four blocks also fail
  open on a swallowed `try`.* `Configure` is public, `StartupError.cause` is
  public, and `_WriteFixtures` already chmods fixture files, so the machinery
  exists.

- **H4 — Device reuse on login, and "one device, one token", are untested.**
  Every `issue` call in the suite passes `None` as `requested`, with one exception
  that asserts a *fresh* id comes back. `_device_for`'s loop body never returns
  and `_forget_device` never finds a session. Both can be gutted with the suite
  green — after which a client resuming its stored device id silently gets a new
  empty device (destroying the buffer the whole `Device`-per-id design exists to
  preserve) and one device can hold two live tokens. No login body in the suite
  carries a `device_id` either, so `_ParseLogin`'s extraction is unexercised.
  *This lines up with M-14: the README and the class docstring both state this
  behaviour backwards, and nothing tests it.*

- **H5 — `ReadStreamPosition` has no test.** The epoch check at
  `stream_position.pony:95` is the entire purpose of `StreamEpoch`, whose own
  docstring states the stakes: "the difference between a client correctly
  resyncing and a client silently blind to every room." Every test runs against a
  single registry with a single epoch, so a foreign epoch never occurs. Deleting
  the check leaves 260 tests green. This is a pure, total, deterministic function
  with a documented five-case list and an obvious round-trip law — the strongest
  property-test candidate in the repository:
  `ReadStreamPosition(StreamPositionText(e, n), e) == n` over generated `n`, plus
  examples for each `None` input.

**Ranked High as a group** because each is an enforcing branch for a written
guarantee, and because the suite's structural imbalance is what produced them: it
is deepest where the code was hardest to get right asynchronously and thinnest
where the code is easiest to test — pure functions with documented case lists and
configuration-time validation. That is the opposite of the usual distribution and
suggests the suite grew by chasing observed defects. Five of the nine
High/Medium test findings could be closed synchronously in under twenty lines
each.

---

## Medium

### M-1 — The login decoy derives at a constant while real entries carry their own iteration count

**Location**: `marilwyd/_decoy.pony:27`, against `marilwyd/credentials.pony:65-82`
and `marilwyd/login.pony:57-66`

**Personas**: Security F6 (Low), Wildcard 2 (Medium), Adversarial F5 (Medium),
Tests M1 — four reviewers.

**Finding**: `_Decoy.verify` always derives at `Pbkdf2Iterations()` = 600,000.
`Credential.verify` derives at the entry's own `iterations`, which `_Entry`
accepts down to `Pbkdf2MinIterations()` = 100,000. The two are equal only by the
coincidence that `hash-password` writes the current default today.

**Evidence**: Verified — `_decoy.pony` passes `Pbkdf2Iterations()` literally.

Both documents state the property unconditionally:
- `SECURITY.md`: "An unknown user and a wrong password produce identical
  responses and take the same time."
- `README.md`: "…produce byte-identical answers **and take the same time**."

Two ways it stops holding, and the second is the one the code invites:

1. An operator hand-writes an entry at the 100,000 floor. `POST /login` then
   returns in ~63 ms for a name in the file and ~380 ms for one that is not — a
   6× difference on the same 403 body, on an unauthenticated endpoint. That is an
   account-enumeration oracle.
2. `Pbkdf2Iterations`'s own docstring says "Entries carry their own count, so
   raising this does not invalidate them" — and the README sells that freedom as
   a feature. **The moment the figure is raised, every pre-existing entry becomes
   timing-distinguishable from an unknown name by exactly the ratio of the
   raise**, silently, with no test failing. It reopens in the direction that is
   worse to explain: the *fast* responses are the real accounts.

The detail that closes it comes from Tests M1: **the shipped test fixture already
runs at a 6× divergence.** `_WriteFixtures` (`marilwyd_test/main.pony:1041-1047`)
writes entries at `Pbkdf2MinIterations()` deliberately, for speed, while `_Decoy`
burns `Pbkdf2Iterations()`. So under `make test` the property `SECURITY.md`
claims is already false, and no test can notice — the timing defence has no test
at all (`grep -rn "Decoy"` returns the definition and the single call site),
and deleting the `_Decoy.verify` call leaves 260 tests green. The fixture makes
the honest assertion impossible, which is itself a finding about the fixture.

There is a second consequence with no clean fix: per-entry counts make *known
accounts distinguishable from each other*. Two real users at 100,000 and 600,000
respond 6× apart. The README presents per-entry counts purely as an upgrade
convenience and never states they are also a per-account timing label.

`hash_password.pony`'s docstring makes exactly the right argument and stops one
consumer short: "a generator that can drift from its verifier eventually will."
There are **three** consumers of those parameters, not two.

**Why Medium rather than Security's Low**: Security assessed the mechanism alone.
Combined with Wildcard's observation that the upgrade path is the trap and Tests'
observation that the suite already runs divergent, the property is conditional on
something the code does not enforce and no test can see.

**Suggested fix**: derive the decoy from the credentials file rather than from a
constant — `ReadCredentials` has every entry in hand at startup. The maximum
present errs slow; the minimum leaks nothing and equals every entry when the file
is uniform. Then state in `SECURITY.md` that entries with differing counts are
distinguishable from one another, which nothing can fix while counts vary.

**Test**: assert the unknown-user path takes at least a floor derived from
whatever the decoy is configured with. Fixing the fixture divergence is a
precondition.

---

### M-2 — Three per-account stores grow without bound, and `SECURITY.md` claims two of them are bounded

**Location**: `marilwyd/user.pony:239-248` (`_backups`),
`marilwyd/user.pony:88-97` (`_account`),
`marilwyd/published_keys.pony:140-175` + `marilwyd/user.pony:147-166`
(merged signatures)

**Personas**: Security F3/F4/F5, Adversarial F4, Correctness 15 — three
reviewers reached parts of this. Filed as one finding because the three stores
share a shape, a fix, and a documentation defect. (Performance 2, which the
orchestrator's cluster grouped here, is a different defect and is credited at
H-6.)

**Finding**:

**(a) `_backups`** is an `Array[KeyBackup]` that is only ever pushed to.
`POST /room_keys/version` is authenticated, has no idempotency, and stores
`auth_data` up to `MaxKeysBody()` = 49,152 bytes. Nothing evicts, nothing caps,
and `latest_backup` only ever reads the last one. A loop adds ~48 kB per request
permanently. This is the cheapest unbounded store behind a token in the server:
no room to create, no device to mint, one small POST.

**(b) `_account`** is a `Map[String, String]` keyed by the `{type}` path segment,
percent-decoded, bounded only by stallion's `max_request_line_size` default of
8192 (which `ServerLimits` does not override — `main.pony:53` sets
`max_body_size` only). Content is bounded at `MaxEventBody()` = 32,768. Distinct
types accumulate without limit. Two amplifications: `_snapshot()` rebuilds the
whole array on every write and hands it to every device, so N writes cost O(N²);
and `SyncDocument` renders **all** of `view.account` into every `/sync` answer
whose position predates the last write. A thousand PUTs under a thousand types
make every subsequent sync response for that account tens of megabytes.

**(c) Merged signatures.** `MergeSignatures` parses the stored key object, merges
every `(signer, key_id)` pair from the upload, and prints the result back.
Nothing prunes. Each subsequent merge re-parses and re-prints the grown object —
quadratic in the number of uploads, on the `User` actor, which is also the
fan-out hop for every room event to that account. The grown object is then
rendered into every `keys/query` answer anyone makes about that user.

**Evidence**: All three verified. `SECURITY.md` affirmatively claims two are
bounded and omits the third:

- "**Cost of published keys.** Per device, bounded: one identity key object, and
  a pool of one-time keys capped at `MaxOneTimeKeys()`." The identity key object
  is not bounded — (c).
- The same section, which is where a reader would look, does not mention backup
  versions at all — (a). The "Key backups are storage of a description only"
  paragraph says nothing about growth.
- "Cost of a room" enumerates what is not bounded — "the number of rooms, the
  number of members a room gains from Matrix, and the current state a room holds"
  — and account data is on no list — (b).

`SECURITY.md`'s standing posture is that authenticated costs are accepted and
left to a rate limiter that does not exist yet, and that unbounded things are
"stated rather than implied". These are not stated, and two are claimed bounded.
That is what lifts this out of the accepted class.

**Suggested fix**: keep only the latest backup version (nothing reads an older
one); cap the number of account-data types and the length of the `{type}` key;
cap the number of signers or the printed length of a stored key object. All three
are small. If the owner prefers to accept the costs, `SECURITY.md`'s two claims
still have to change.

---

### M-3 — The end of a typing notification never reaches a client, and a test pins the wrong behaviour

**Location**: `marilwyd/device.pony:374-398` (`_ephemeral_since`),
`marilwyd/ephemeral.pony:112-131` (`EphemeralEvents`)

**Personas**: Correctness 3 (sole finder)

**Finding**: Two independent guards drop the transition to "nobody is typing".

`Device._ephemeral_since` filters on the *new* state: `if unseen and
(current.size() > 0)`. `Ephemeral.size()` is `receipts.size() + typing.size()`
(`ephemeral.pony:38`), so a room where nobody has sent a read receipt and the
last typist has just stopped produces `size() == 0` and is dropped from the sync
entirely.

Even when receipts are present and the block travels, `EphemeralEvents` omits the
typing event — and does so directly beneath a comment stating the opposite
requirement:

```pony
// Emitted only when somebody is typing. An empty list is how a
// client is told that nobody is any more, so it has to be sent when
// the last person stops — …
if ephemeral.typing.size() > 0 then
```

**Evidence**: Verified — both guards read exactly as reported. An `m.typing` with
an empty `user_ids` is the only way Matrix expresses "nobody is typing";
matrix-js-sdk sets `RoomMember.typing` from that event and does not expire it on
its own. The change *is* produced: `_TypingHandler` passes `typing: false` to
`Room.typing` (`ephemeral_http.pony:202-220`), which removes the entry and calls
`_publish()` (`room.pony:477-482`). It is delivered to the device and then
filtered out of the document.

**The test pins the wrong behaviour.** `_ExpectNoEphemeral` asserts
`rendered.contains("m.typing")` is false, and
`_TestEmptyEphemeralIsNotSent`'s docstring
(`marilwyd_test/ephemeral_tests.pony:402-409`) argues the correct rule — "What
must still arrive is the change *to* empty — the last person stopping typing" —
while the predicate is applied to the state being sent rather than to the state
the client holds. The docstring describes behaviour the code does not have.

**Suggested fix**: render `m.typing` whenever the room has ephemeral state worth
sending at all, with an empty `user_ids` when nobody is typing; and make
`_ephemeral_since` compare against what the device last sent rather than against
the emptiness of the new value. Update `_ExpectNoEphemeral` and
`_TestEmptyEphemeralIsNotSent` together — the test change is part of the fix,
not a follow-up.

---

### M-4 — Leaving a room leaves your read receipt and typing flag behind

**Location**: `marilwyd/room.pony:284-301` (`leave`), `marilwyd/room.pony:460-482`

**Personas**: Correctness 4 (sole finder)

**Finding**: `Room.leave` clears `_members`, `_watching`, `_carrying` and
`_stalled`. It does not touch `_receipts` or `_typing`, which are keyed by the
same user id (`room.pony:50-51`). `_publish()` (`room.pony:484-506`) walks both
maps unfiltered and hands the result to every watching account.

**Evidence**: Verified against `Room.leave`'s body, which touches four maps and
not the other two.

- A departed member's read receipt is republished to the remaining members
  forever. Element draws a read marker for someone not in the room.
- Somebody who leaves while their typing flag is set is reported as typing
  forever, and cannot be cleared: `Room.typing` returns early for a non-member
  (`room.pony:470-472`), so even the client's own `typing: false` is refused. The
  stuck entry also permanently occupies one of the `MaxTypists()` slots.

`_TestOnlyMembersAreHeard` (`ephemeral_tests.pony:153-181`) covers a *stranger*
who was never a member; it does not cover a member who leaves.

**Suggested fix**: remove the user's entries from `_receipts` and `_typing` in
`Room.leave` (and in `part_ghost`, for symmetry), then `_publish()`.

---

### M-5 — `Device.sync` silently drops an already-parked receiver

**Location**: `marilwyd/device.pony:255-259`

**Personas**: Correctness 7, Adversarial F6 — both Medium

**Finding**: `_parked` is overwritten without checking whether one is already
held. Every other transition out of the parked state is guarded on identity —
`expired` and `abandon` both test `if _parked is receiver` (`device.pony:262-281`)
precisely so a stale receiver cannot be answered by mistake. Here the *live*
receiver is discarded instead.

**Evidence**: Verified — the `else` arm assigns unconditionally while both
neighbouring behaviours guard on identity.

The orphaned `_SyncHandler` is then unreachable: its own deadline fires,
`waited()` calls `stream.expired(this)` (`sync.pony:210-214`), `_parked is
receiver` is false, and nothing happens. The handler never calls
`respond_with_headers`, and hobby's 30-second watchdog answers a bodiless `504`
with no `errcode`. `MaxSyncWait`'s docstring says what that costs: "measured
against Element 1.12.25, a server that lets the watchdog win puts the client into
a permanent `SYNCING`/`RECONNECTING` flap."

**Reachability** is where both reviewers' confidence drops. One Element instance
runs a single sync loop, and `SECURITY.md` measures pipelined syncs on one
connection being answered serially, so this needs two *connections* resolving to
the same `Device` — two clients holding tokens for the same device id, which
`_device_for` permits when a login names a device the account already has, or a
second Element tab sharing the stored device id. A hostile or buggy client
trivially can.

**Suggested fix**: answer the previously parked receiver immediately — `_wake()`
before `_parked = receiver` — with whatever it is owed. Matrix permits a server
answering before the requested timeout.

**Note**: this is one of five sites in pattern B above. See M-8.

---

### M-6 — Room membership keys are stored without cloning, pinning dead `UserLink` actors

**Location**: `marilwyd/room.pony:580` (`_admit`), `marilwyd/room.pony:356`
(`carrier_stalled`), `marilwyd/room_state.pony:53` (`join`),
`marilwyd/room_state.pony:64` (`invite`)

**Personas**: Correctness 8 (the ORCA consequence), Principles F5 (the
inconsistency)

**Finding**: `docs/architecture.md` states the rule: "**Cloning at the boundary.**
Any string a long-lived actor keeps from a request is cloned. Under ORCA a
foreign reference keeps its owning actor alive." `Room` follows it for four of
its six string-keyed fields (`_watching`, `_carrying`, `_receipts`, `_typing` —
`room.pony:92`, `:228`, `:453`, `:475`, `:519`) and not for the other two.
`RoomState.join` and `RoomState.invite` do not clone either. `_append` clones
everything it keeps (`room.pony:606-615`), which makes the omission look
accidental rather than reasoned.

**Evidence**: Verified — `_admit` reads `_state.join(user_id)` then
`_members(user_id) = user`, with no clone on either.

**No leak exists on the Matrix path.** Every caller was traced: `room.join`,
`invite` and `leave` are reached with `s.user_id` and with `known(0)`/`unknown(0)`
(`rooms.pony:516`, `:518`, `:532`, `:546`, `:936-940`), all of which originate as
`SessionRegistry`-owned clones (`session_registry.pony:63`, `:133`, `:135`), and
`SessionRegistry` lives for the process.

**The ghost path is different.** `Room.admit_ghost` calls `_state.join(user_id)`
(`room.pony:333`) with the id built by `UserLink._ghost`
(`user_link.pony:446-455`), so `RoomState._members` holds a string owned by that
`UserLink`. Under ORCA that keeps the actor alive. When the connection dies,
`_finished` (`user_link.pony:182-202`) parts only its *owner* and asks the
directory to forget the link — the ghosts stay in `RoomState._members`. Every tag
to the `UserLink` is dropped, but the room's membership set still references its
heap, so the actor is never collected. One leaked actor per bridged connection
that ever saw a participant, for the life of the process.

Two further pieces of evidence that the invariant is non-local rather than
reasoned. `RoomDirectory` clones the *same value* defensively one hop earlier
(`room_directory.pony:78`), which is redundant if the caller's clone were the
rule and necessary if it is not — both cannot be right. And nothing at
`room.pony:579` tells a new handler it must have cloned.

**Confidence**: the refcap and GC reasoning is straightforward, but neither
reviewer measured a `UserLink` surviving its death, and Correctness could not
exhaust every path that might clear `RoomState._members` for a ghost — reading
`_finished`, `part()` and `_close()` it found none.

**Suggested fix**: clone in `RoomState.join`/`invite`, `Room._admit` and
`Room.carrier_stalled`, matching the four neighbouring fields, and drop the
now-redundant clone at `room_directory.pony:78`. Separately, `_finished` should
part the ghosts it admitted, which fixes the stale membership as well as the pin.

---

### M-7 — `soft_logout: true` tells every client the opposite of what a marilwyd restart did

**Location**: `marilwyd/documents.pony:430-445` (`UnknownToken`), with
`marilwyd/documents.pony:116-126` (`ExpiredToken`) and
`marilwyd/room_directory.pony:168-185`

**Personas**: Wildcard 1 (sole finder), which rated it High.

**Downgraded to Medium, with the reason stated**: the falsity of the assertion
is High-confidence and I have not softened it. What is unestablished is the
consequence — no restart-with-a-live-client scenario has ever been driven here,
and every path by which a wrong `soft_logout` hurts a user runs through client
behaviour nobody observed. Against a server that restarts freely and loses only
in-memory state by design, a false flag whose downstream effect is unmeasured is
Medium. The probe below moves it back to High or closes it in fifteen minutes.

**Finding**: `UnknownToken` is the body for every rejected token and sets
`soft_logout: true`. Its docstring names the case it is aimed at, then reasons
one step short:

> `soft_logout` tells the client its credentials are still good and only the
> session is gone, so it offers to sign in again rather than discarding local
> state. Every marilwyd restart puts every client in exactly that position,
> because sessions are held in memory.

A marilwyd restart does not put a client in "only the session is gone". It puts
it in *everything* is gone. `docs/architecture.md`'s own "Rules that hold
everywhere": "**Nothing survives a restart.** No account, room, message, session
or invitation is written to disk."

**Evidence**: Verified — `documents.pony:445` sets `soft_logout` to `true`
unconditionally, and `ExpiredToken` is `M_UNKNOWN_TOKEN` *without* it.

So after a restart the server has lost, and the client has been told to keep:
every room and membership (`/sync` will never mention them again, and `PUT …/send`
answers 403 — nothing in the protocol tells the client those rooms ended, because
there is no room left to emit a `leave`), every invitation, published device and
cross-signing keys, the key backup version, and account data.

The bridged case is worse than "gone" — it is *silently replaced*.
`RoomDirectory._theirs` is in-memory and the room id comes from `MakeRoomId`,
while the alias is re-declared from `bridges.yaml` at startup. After a restart
the same alias resolves to a **new** room id, so a client keeping local state
accumulates one dead room per bridged channel per restart, each carrying the same
alias as the live one.

The right answer already exists in the same file, and the two have been assigned
backwards: `ExpiredToken`'s docstring gets the semantics exactly right — the flag
is "right when a session ended underneath a client and wrong when the client
asked for it to end" — yet the hard logout is used for the deliberate
`POST /logout` (where the server's state *does* survive) and the soft logout for
the restart (where nothing does).

**Confidence**: the falsity of the assertion is high. The client-visible
consequence — whether matrix-js-sdk on a soft-logout re-login really retains the
room and crypto stores in the way described — is inference from protocol intent,
not observation, and no restart-with-a-live-client scenario has ever been driven
here.

**Suggested fix**: answer a token minted before this run with `ExpiredToken`,
keeping `UnknownToken` + `soft_logout` for a token revoked within a live process.
`StreamEpoch` already exists for exactly this distinction and is not consulted
here. If that is more than the increment wants, the minimal honest change is to
drop `soft_logout` everywhere and say in `SECURITY.md` that this server has no
state that outlives a session, so there is no such thing as a soft logout here.

**Verification, in this project's own style**: run marilwyd with
`--log-requests`, sign Element in, create or join a room, restart, sign in again,
and read whether the old room is still rendered and what
`GET /rooms/{old id}/state` answers. Fifteen minutes, and it settles the severity.

---

### M-8 — A request that is never answered is the handler layer's default failure mode

**Location**: ten `var _session: (Session | None)` / `var _room: (Room tag |
None)` fields re-matched without an `else` — concretely `rooms.pony:924-941`,
`:513`, `:523`, `:544`; `ephemeral_http.pony:206-208`; `directory_http.pony:77-80`.
Plus `rooms.pony:895-901` (`_InviteHandler.users_found`'s bare `return`),
`keys_http.pony:154` (`_expected = _expected - 1` on a `USize`), the
`MissingToken()` constructor arm in 26 copies, and `device.pony:255-259` (M-5).

**Personas**: API/Design 10, API/Design 14, Correctness 7, Adversarial F6 —
four reviewers reaching one structural problem from four directions, with Tests
L4 supplying the coverage gap that would let a slip ship (it reports that
`_SyncHandler.dispose` and `Device.abandon` are untested; it did not reach the
pattern itself).

**Finding**: The handler state machine is: stash the session (and sometimes the
room) in a nullable field, then re-`match` it in each later behaviour. Every one
of those matches is written without an `else`:

```pony
be room_found(room: Room tag) =>
  match _session
  | let s: Session => room.send(s.user_id, _kind, _content, this)
  end                                    // no else — no response
```

The consequence of any of these falling through is not an error, a 500, or a log
line. It is a request that is never answered, held until hobby's 30-second
watchdog answers `504` with no `errcode` — which is the exact failure
`MaxSyncWait`'s docstring measures against Element 1.12.25 ("a permanent
`SYNCING`/`RECONNECTING` flap") and the four-method catch-all was built to
prevent.

**Evidence**: Measured by grep over `marilwyd/`:

- `be dispose() => None` — 27 copies
- `be throttled()` / `be unthrottled()` — 28 copies each
- `fun ref _respond(...)` — 27 byte-identical copies
- `be token_rejected() => _respond(stallion.StatusUnauthorized, UnknownToken())`
  — 23 copies
- the constructor preamble ending `_respond(stallion.StatusUnauthorized,
  MissingToken())` — 26 copies

Roughly 150 lines of exact duplication. Three of the pieces fail loudly if
forgotten — the compiler enforces `hobby.HandlerReceiver`. **The `MissingToken()`
arm does not**: a constructor that resolves a token and forgets the `else`
produces a handler that is constructed, never responds, and is answered by the
watchdog.

None of the individual sites is reachable today; the fields are always set before
the ask that reads them. **The finding is the shape**: it makes "forgot to
answer" the cheap mistake in the most-copied structure in the codebase, copied
across ten handlers, and M-5 is the one site where the same failure mode *is*
reachable.

**Suggested fix**: at minimum, give each of these matches an `else` that responds
`500`, so a state-machine slip is a visible error rather than a hang. Better,
carry the session with the ask instead of stashing it, so the behaviour that
needs it receives it. For the boilerplate, Pony's documented remedy is the Mixin
pattern — a `trait tag _MatrixHandler is hobby.HandlerReceiver` supplying default
bodies for `dispose`, `throttled`, `unthrottled` and `token_rejected` with
`_respond` left abstract. The codebase is already halfway there: `embed _handler:
hobby.RequestHandler` in every handler is the Embed-and-Delegate half of the same
pattern. Handlers that need a different `_respond` (`_SyncHandler`) or
`token_rejected` (`_UnrecognizedHandler`) override. *This half is a proposal that
was not compiled; the counts are verified.*

**Test**: `_SyncHandler.dispose` and `Device.abandon` are both untested
(Tests L4) — `grep -rn "abandon" marilwyd_test/` returns nothing — which includes
the `_disposed` guard at `sync.pony:186-188` whose comment records the exact
ordering bug it exists for. `Device.abandon` is reachable from a test with no
HTTP at all.

---

### M-9 — A bare `try` with no `else` makes a failed check indistinguishable from a passed one

**Location**: `marilwyd/config.pony:257-265` and `:311-319` (the credentials and
bridges permission checks); `marilwyd/link_directory.pony:89-92` (`close`'s
`_links.remove`); `marilwyd/config.pony:222-268` and `:270-322` as a duplicated
pair

**Personas**: Principles F2, Security F10, API/Design 4, API/Design 24 — four
reviewers, one pattern.

**Finding**:

**(a) Two security checks fail open.** `SECURITY.md` states without
qualification: "marilwyd refuses a credentials file that any user but its owner
can read, and one placed inside `--asset-root`." The code:

```pony
try
  let mode = FileInfo(resolved)?.mode
  if mode.group_read or mode.any_read then
    return StartupError("credentials-permissions", …)
  end
end

ReadCredentials(resolved)
```

There is no `else`. If `FileInfo` raises, control falls straight into
`ReadCredentials(resolved)` — the file is accepted with its permissions
unchecked. The same shape is repeated verbatim for `--bridges` at `:311-319`.
Verified in both blocks. Practical reachability is low (`canonical()` has already
succeeded), which is why this is Medium — but the codebase is elsewhere explicit
about failing closed on security decisions (`session_registry.pony:66`, "Fail
closed. There is no weaker credential worth issuing"), and a swallowed `error`
loses the information entirely.

**(b) The same shape hides a live argument-order trap.**
`LinkDirectory.close(user_id, channel, network)` and
`LinkDirectory.forget(user_id, network, channel)` are two behaviours on one actor,
both `(String, String, String)`, with parameters 2 and 3 transposed relative to
each other. `LinkOwner.forget` and `_key` both use `(user_id, network, channel)`;
`close` alone is transposed. Verified. A transposed call compiles, `close` builds
a key nothing matches, `_links.remove` raises, the bare `try` swallows it, and
the IRC connection stays open and registered after the Matrix user has left the
room — which is the "membership means connected on both sides" invariant the
design turns on. Nothing in the type system and nothing at runtime reports it.
The one call site (`rooms.pony:544`) happens to be correct, so this is latent.

**(c) The whole check is written twice.** `_ReadCredentialsFile` and
`_ReadBridgesFile` are the same 35 lines: same `FileCaps`, same
`canonical()?`, same prefix compare, same `FileInfo` mode check, different
strings. `_ReadBridgesFile`'s docstring says as much ("The same posture as the
credentials file"). Two copies of a security check is one copy too many — a third
configuration file gets a third copy, and the next hardening (symlinks, ownership,
parent directory) has to land in all of them.

**Suggested fix**: add `else return StartupError("credentials-unstattable", …)`
to both `try` blocks. Make `close` take `(user_id, network, channel)` like
everything else, or take `BridgedChannel`/`BridgedNetwork` as `open` does — the
typed values are already in hand at the one call site. Factor the two file
readers into one `_ReadSecretFile(flag, path, auth, asset_root)` with the flag
name threaded through the messages.

**Test**: Tests H3 — all four of these startup refusals are untested and can be
deleted with the suite green, and `LinkDirectory.close` is never called by any
test (Tests M3).

---

### M-10 — The bridge's `to_matrix` template is never validated, and nothing keeps a ghost id out of the real-account namespace

**Location**: `marilwyd/read_bridges.pony:135-136`, `marilwyd/bridges.pony:56-83`
(`NameMapping`), `marilwyd/user_link.pony:512-522` (`_ghost`)

**Personas**: Security F2 (sole finder)

**Finding**: `NameMapping`'s own docstring states the invariant: "An IRC user's
Matrix id is an identity this server mints and **must never collide with a real
account's**." Nothing enforces it. `ReadBridges` builds the mapping with no
checks — while validating the *network name* twenty lines earlier for exactly
this reason ("The network name goes into every ghost's user id, so it has to be
usable in one"). The template goes into every ghost's user id by the same route
and gets none of that care.

**Evidence**: Three consequences, the third reachable with the shipped template.

1. `to_matrix: "{nick}"` makes IRC nick `alice` into `@alice:server` — the real
   account. Accepted at startup without a word.
2. A template with characters a localpart may not hold mints unaddressable user
   ids. `GhostLocalpart` respects `Localpart.check`'s set for the *nick*; the
   template's own literal text is never checked.
3. With the shipped `to_matrix: "irc_{network}_{nick}"` and network `fussake`, a
   credentials entry with localpart `irc_fussake_bob` is the same Matrix id as IRC
   nick `bob`. `Localpart.check` permits every character in that string, and no
   startup check compares credentials localparts against the template's output
   space.

Case 3 traces end to end: that account joins the bridged channel and gets its own
room; IRC nick `bob` joins; `UserLink._admit` calls `Room.admit_ghost` with their
own user id, short-circuited because `is_member` is already true. Then `bob`
parts and `Room.part_ghost` runs on the room owner's own id — `_state.leave`
drops them from `_members` and removes their membership event, while
`Room._members` still holds their `RoomMember tag`, so the room goes on
delivering to them but `Room.send` now answers `NotInRoom` (403) **for their own
room**. `admit_ghost` re-adds them the next time `bob` speaks. A stranger on a
public IRC channel controls whether a Matrix user can send in their own room, by
choosing a nickname.

`SECURITY.md`'s "A nickname becomes a user id, and the mapping is injective"
reads as a complete account of the collision question when it covers only half of
it — `GhostLocalpart`'s injectivity argument is correct and stops at the ghost
space, never reaching the real one.

**Confidence**: traced line by line, not run.

**Suggested fix**: at startup, require `to_matrix` to contain `{nick}` and
require `_Substituted` output over a probe nick to satisfy `Localpart.check`.
Then check every credentials localpart against the template and refuse a file
where any real localpart could be produced by it. Reserving one character the
ghost prefix must use and `Localpart.check` must forbid in a real account would
settle it structurally instead.

---

### M-11 — The bridge's configuration format is documented nowhere, and `make run` requires it

**Location**: `Makefile:97-102`, `.gitignore:8`, `README.md` "Building" and the
flags table, `marilwyd/read_bridges.pony:193-207`

**Personas**: API/Design 2 + 3, Wildcard 8, Editor F14 — three reviewers, one
signal. This is the review's only "scope" finding, and it points one way rather
than several.

**Finding**: `make run` hardcodes `--bridges=bridges.yaml`. `bridges.yaml` is in
`.gitignore`, no target creates it, and a missing bridges file is a hard startup
refusal (`config.pony:299-301`, `bridges-missing`), not a fallback. So on a fresh
clone `make run` — which `README.md:111-114` documents as "fetches and unpacks
Element, then starts marilwyd on `http://localhost:8008`" — exits 1.
`CREDENTIALS ?= credentials.yaml` is a variable precisely so the operator can
override it; the bridges path was hardcoded beside it without the same treatment.

**Evidence**: Verified. And the deeper half: the bridges YAML schema is
documented nowhere in the repository. The credentials file gets a worked README
example, a field-by-field explanation, and a generator subcommand. The bridges
file — the entire configuration surface for a feature the README spends five
paragraphs on, `SECURITY.md` two sections on, and `docs/architecture.md` four
diagrams on — gets one sentence and no schema. Grepping `README.md`,
`SECURITY.md` and all three `docs/*.md` for `networks:`, `room_name`, `to_irc`
and `mapping` finds one incidental match.

The schema is only recoverable from `_RawNetworkOf`/`_RawChannelOf`, and every
key except `alias` is required, so an operator writing it by guesswork gets one
`bridges-malformed` per missing key. Two further undocumented surprises: the file
is refused if group- or world-readable (a default-umask `bridges.yaml` will not
start) and refused inside `--asset-root`.

Where the schema *is* documented is the untracked `bridges.yaml` in the working
tree, whose comments are good and which no clone will ever see — and which
carries a self-contradiction showing it is doing documentation duty without
documentation review: a comment reading "No TLS and no password: the test server
wants neither" sits directly above `tls: true`.

**Suggested fix**: commit a `bridges.example.yaml` (the existing comments are
most of the work) or add a `## Bridges` README section beside the credentials
recipe, with the required keys, the template placeholders and the `chmod 600`
requirement. Then make `run` degrade: `BRIDGES ?=` with the flag appended only
when set, so `make run` works with no bridge configured — which is the documented
default behaviour of the flag.

---

### M-12 — The markdown linter is excluded by a path filter from every markdown-only change

**Location**: `.github/workflows/pr.yml:3-9`

**Personas**: Wildcard 3 (sole finder)

**Finding**: `on.pull_request.paths` gates the **workflow**, not a job. `pr.yml`
contains two jobs, one of which is `superlinter` with `VALIDATE_MD: true`. A pull
request touching only markdown matches no path in the list, so the workflow does
not run, so the markdown linter never sees the markdown. The one job whose entire
purpose is linting `.md` is switched off by a filter that exists to skip the
*tests* on documentation changes.

**Evidence**: Verified against the file, and against real history. PR #29
(`9485839`, "Architecture doc") changed `README.md` (+4) and
`docs/architecture.md` (+799) and nothing else. `pr.yml` excluded it;
`pony-lint.yml` also skipped it (`paths: '**/*.pony'`). An 803-line documentation
addition — the largest single addition to this repository outside the sources —
merged with **zero** CI runs of any kind.

Given how much of this review is documentation defects, this is the gate that
would have caught the cheapest of them.

Two smaller things in the same file: `actions/checkout@v4.1.1` here against
`v6.0.2` in the other three workflows, and `docker://github/super-linter:v3.8.3`
— a 2020-era image, five major versions behind, at the deprecated
`github/super-linter` location (upstream moved to `super-linter/super-linter`).
Every other pinned action and image in this repository is current.

**Suggested fix**: move `superlinter` into its own workflow with no `!**/*.md`
exclusion — the exclusion belongs on the test job's workflow, not the linter's.
Bring `checkout` and the image into line with the rest.

---

### M-13 — CI never builds the configuration the README tells people to build

**Location**: `.github/workflows/main.yml:19`, `.github/workflows/pr.yml:29`,
against `Makefile:9-38`

**Personas**: Wildcard 4 (sole finder)

**Finding**: Both test jobs run exactly `make test ssl=libressl config=debug`.
The `Makefile` defaults are `config ?= release` and `ssl ?= 3.0.x`, and the `ssl`
default carries a comment explaining it exists so `make` works out of the box on
a machine with OpenSSL 3. The README's build instructions are
`corral fetch && make && make test` — release and OpenSSL 3, **neither of which
is ever compiled in CI**. Verified.

Three concrete gaps:

1. `-Dopenssl_3.0.x` and `-Dlibressl` select different FFI declarations in
   `ponylang/ssl`, and marilwyd reaches libcrypto through `Pbkdf2Sha256`,
   `RandBytes`, `ConstantTimeCompare` and `SSLContext`. A break confined to the
   OpenSSL-3 path compiles and passes everywhere in CI and fails on every
   developer machine that follows the README.
2. `config=release` is never compiled — no gate on a release-only miscompile.
3. `make build` is never invoked. `make test` does compile the whole `marilwyd`
   package so type-checking is covered, but the `build/marilwyd` rule, the
   `build/element` fetch, the SHA-256 check and the `run` target are exercised by
   nobody but a human.

Also: `main.yml` (push to `main`) runs only `make test`, and `pony-lint.yml` and
`lint-action-workflows.yml` are both `on: pull_request` only — so a direct push
to `main`, which `0f5b394` appears to be, gets no lint at all.

**Suggested fix**: one extra job (or matrix leg) running `make build test` with
the defaults. That buys the configuration every reader of the README actually
uses.

---

### M-14 — `README.md` and the `SessionRegistry` class docstring both say a device id is never reused; `_device_for` reuses it

**Location**: `README.md:301-305`, `marilwyd/session_registry.pony:9-11`, against
`marilwyd/session_registry.pony:243-256` and `:37-70`

**Personas**: Security F7, Wildcard 7

**Finding**: README:

> A login never reuses a device id a client asks for. Matrix allows that, meaning
> "replace this device's session", and marilwyd always mints a fresh one instead,
> so a re-login after a soft logout leaves the old session behind rather than
> replacing it.

The class docstring at lines 9-11 says the same. Twenty lines below, `issue`'s
docstring says the opposite and is correct, and `_device_for` reuses a requested
id when the account already has it — verified directly. `issue` then calls
`_forget_device`, so the previous session on that device is silently revoked.

**Evidence**: The behaviour itself is fine — scoped to the authenticated account,
and `docs/architecture.md`'s Login diagram, `SessionRegistry.issue`'s docstring
and `login.pony`'s `_LoginRequest` docstring all describe it correctly. The
finding is the documents, and they are wrong in the section a reader consults for
session-lifetime semantics: the README tells them a re-login leaves the old
session alive when the old token in fact stops resolving, and that the returning
client cannot pick up the queue held for it when it can.

Two consequences beyond the words:

- The class docstring's conclusion — "so the count only falls when a client asks
  it to" — is derived from the false premise. A re-login on a known device is a
  fourth way the count falls, and the one a client does not ask for.
- `SECURITY.md`'s **Revocation** section enumerates session endings exhaustively:
  "A session ends when its own client calls `POST /logout`, when another of that
  account's clients deletes its device, or when the server restarts."
  Re-login-on-the-same-device is missing. It is legitimate — the specification
  requires it — but it is the only ending that revokes a token *without* the
  holder or another client having asked, and a threat model whose enumeration is
  short by one is worth correcting.

The class docstring has been wrong for twenty-two commits and is wrong *within
twenty lines of the method that contradicts it*, which is the reading order a
maintainer hits it in.

**Suggested fix**: rewrite the README paragraph and lines 9-11 to match `issue`,
and add the fourth ending to `SECURITY.md`'s Revocation enumeration.

**Test**: Tests H4 — this behaviour is untested from both ends; `_device_for` can
be reduced to `MakeDeviceId()` with 260 tests green.

---

### M-15 — The package docstring describes a program two increments old

**Location**: `marilwyd/marilwyd.pony:1-39`, and `marilwyd/sync.pony:114`

**Personas**: Principles F3, Wildcard 5, Correctness 9, API/Design 16 — four
reviewers.

**Finding**: This is the package-level docstring — the front page `pony-doc`
renders and the first file a reader opens. Verified in full:

> This is a skeleton. […] an always `/_matrix/client/v3/sync` that long-polls
> […]
>
> Element does not become usable at this point […] and **marilwyd implements no
> crypto endpoints** — so a signed-in client sits on that screen with a healthy
> sync loop underneath it. Crypto is the next piece of work.

`routes.pony:176-198` registers eight crypto endpoints (`keys/upload`,
`keys/query`, `keys/device_signing/upload`, `keys/signatures/upload`,
`room_keys/version` ×2, `keys/claim`, `sendToDevice`). `docs/completion.md` marks
every one "done" and prints a captured trace of the whole handshake completing in
116 ms. The README's first line under Status is "**Element signs in and reaches
the app.**" The package docstring asserts the exact opposite of the project's
headline claim.

It is also missing everything added since: the IRC bridge — arguably half the
program, ten commits, `user_link.pony` alone 815 lines, two sections of
`SECURITY.md` and four diagrams in `docs/architecture.md` — appears nowhere in
it. `docs/architecture.md:3-4` opens "marilwyd is a Matrix homeserver and an IRC
bridge in one process."

`git log -- marilwyd/marilwyd.pony` ends at `0aeeb3b` (#9); crypto arrived at
`ad0999b` (#11). Wrong for twenty-two commits.

One sentence is additionally broken and reads as a half-finished edit: "an always
`/_matrix/client/v3/sync` that long-polls" — "an always" governs nothing, and
looks like "an always-empty `/sync`" partly rewritten when `/sync` stopped being
always-empty. The same rot is at `sync.pony:114`, in `_Sync`'s class docstring:
"There are no rooms and no events, so every answer is the same document." There
are; `SyncDocument` spends 130 lines rendering them.

**Suggested fix**: two options, and the second is the one that stops this
recurring. Either rewrite it from `docs/architecture.md`'s opening three
paragraphs and `docs/completion.md`'s status, or cut it to a short orientation
paragraph that points at `README.md` and `docs/architecture.md` and cannot go
stale. The README is maintained; a second full description of the program in a
docstring is a copy that will drift again — which is exactly what the maintenance
table in the orientation shows.

---

### M-16 — `docs/completion.md` lists six implemented endpoints as unreachable, and contradicts itself

**Location**: `docs/completion.md:168-187`, against `docs/completion.md:133`,
`:138`, and `marilwyd/routes.pony:122-152`

**Personas**: Editor F3, Wildcard 6, Tests L8

**Finding**: Under "Defined by matrix-js-sdk, not yet reachable", introduced with
"None of these has been observed", the document lists `members`, `invite`,
`leave`, `typing/{userId}`, `receipt/{receiptType}/{eventId}` and `read_markers`.
All six are registered in `routes.pony`, implemented, and (except `leave`)
tested.

Two of the six — `leave` and `members` — also appear in the *same file's*
"Implemented but not observed" table. The document places them in both lists,
and the two lists say opposite things. The same happens to `account_data`: `PUT`
is in the Observed table marked "done" and in the not-reachable list.

**Evidence**: Verified against `routes.pony`. `git log -- docs/completion.md`
ends at `8d93748` (#15); commits #21, #24, #25, #26 and #28 all changed behaviour
it describes.

This matters to more than a reader. The document states its own purpose —
"**Observed** is what Element 1.12.25 actually requested … That is the list that
decides what to build next" — so a list that decides what to build next, and that
lists implemented endpoints as unbuilt, misdirects the work it exists to direct.
The Tests reviewer records that it did exactly that during this review: it went
looking for tests for endpoints the document said did not exist.

**Suggested fix**: bring the three tables in line with `routes.pony` and resolve
the `createRoom` paragraph against `docs/next-increment.md` (H-7). Longer term,
the "Implemented" tables are derivable from `routes.pony` and will keep drifting
while they are hand-kept; the part worth keeping by hand is the *observed* list,
which is a measurement and cannot be derived.

---

### M-17 — History narration in comments and docstrings, repository-wide

**Location**: ~20 sites. Worst: `marilwyd/room_directory.pony:111-117`,
`marilwyd/bridged_room_receiver.pony:25-34`, `marilwyd/room.pony:573`,
`marilwyd/rooms.pony:216-218`, `marilwyd/to_device.pony:20-25`,
`marilwyd/link_owner.pony:8-9`, `marilwyd/ghost.pony:108-111`,
`marilwyd/room.pony:654-659`, `marilwyd/config.pony:155-158`,
`marilwyd/device.pony:24-26`, `:33-36`, `marilwyd/room_directory.pony:24-26`,
`:46-51`, `:162-165`, `marilwyd/user_link.pony:213-216`, `:237-240`, `:671`,
`marilwyd/room.pony:88-90`, plus ~16 sites in the test suite.

**Personas**: Editor F6

**Finding**: `pony-comments` is unambiguous: "Never narrate history. 'Previously
this returned -1.' 'Before the refactor we…' Version control remembers."

The sharpest instance is a **public behaviour's docstring stamped "until now"**
(`room_directory.pony:111-117`): two thirds of `with_room`'s docstring describes a
bug that no longer exists, dated to a commit the reader cannot see.
`bridged_room_receiver.pony:25-34` is a docstring that is *nothing but* a past
defect — every sentence after the summary line is about code that is gone,
including the fact worth keeping (writing a room draws event ids separately from
the room id, so the declaration's outcome is what says the room is good), which
is recoverable from it but is not what the words say.

**The boundary matters for the fix.** "Without X, Y would happen" is a
counterfactual and is legitimate rationale — it explains why the code is shaped
as it is and does not rot. "An earlier version did X and the bug was Y" is
history. Several of the comments mix both in one sentence; the counterfactual
half stays.

The test suite's version is the most concentrated and the least defensible:
`wake_tests.pony:386-390` narrates a test that "asked its question of the wrong
path for as long as it existed", `key_http_tests.pony:239-242` records "exactly
how the first version of this test passed with the rule removed",
`login_limit_tests.pony:244` records "the first version of this one could not".
These are notes about how the tests were developed and belong to the pull request
that developed them.

**Suggested fix**: drop the history clause, keep the current fact. Docstrings are
tightened rather than deleted.

---

### M-18 — Shelf-life claims about tests and CI, including the exact sentences the rulebook names

**Location**: `marilwyd/room.pony:74`, `marilwyd/rooms.pony:436-438`,
`marilwyd/main.pony:27`, `marilwyd/ghost.pony:111`, `marilwyd/pending.pony:11`;
`SECURITY.md:60`, `:229`; `docs/completion.md:116`, `:153`; `Makefile:54-64`;
and nine sites in the test suite

**Personas**: Editor F7, Editor F8

**Finding**: `pony-comments`: "Never write a fact with a shelf life… whether a
test exists — 'nothing catches this,' 'no test covers this,' 'verified by
reasoning'… Every one becomes false the moment somebody edits a workflow or
deletes a test, and nothing catches it."

`marilwyd/room.pony:74` carries the forbidden sentence verbatim: "**No test
covers the refusal**." `rooms.pony:436-438` counts tests in a comment ("which
**two tests pin**"). `main.pony:27` says "a limit **the suite cannot reach**".
`SECURITY.md:60` uses the "verified by reasoning" shape ("**verified from outside
the package**"); `:229` says "**The gap is recorded and asserted in tests**".
`docs/completion.md` says "They are exercised by the test suite and by curl"
twice.

The `Makefile:54-64` `test` comment is eleven lines carrying three durable ones.
The rationale earns a comment — `timeout -k 10 300` does not explain itself — but
four clauses inside it do not earn their place: "which this suite has already
done once" (history, unverifiable), "CI would otherwise sit until its own job
timeout with no failing test to point at" (a claim about what CI does, which
`pony-comments` names first in its shelf-life list), "that was measured, not
assumed" (process leakage — it tells the reader about the author's confidence),
and "which costs one word to guard against and leaves a runner holding gigabytes
if it is not" (an unverified quantity arguing for a decision already made). The
durable content is: `long_test` bounds a test that reaches its own deadline, a
test that spins or blocks never does, and a hung run reads as a passing one until
somebody looks — so the wall clock is what makes a hang visible; `-k` covers a
test that blocks where TERM cannot reach it.

One case correctly falls the other side of the rule and is not flagged:
`credentials.pony:269` uses "silently" to mean the code produces a wrong value
and raises nothing, which is the exception `pony-comments` names explicitly.

**Suggested fix**: cut the clause about the test or the suite. What remains is
the invariant, which is what the comment was for.

---

### M-19 — `SECURITY.md` documents the current threat model by narrating the history of its fixes

**Location**: `SECURITY.md:74-76`, `:84-86`, `:111-115`, `:147-166`, `:173-180`,
`:224-230`

**Personas**: Editor F10

**Finding**: The document repeatedly describes a state the code has left, then the
state it is in, using undated "now" and "used to" to separate them: "Memory
**was** remotely growable… and **is now** bounded"; "`_ParseLogin` **now**
refuses"; "**Before** `/sync`, every request was answered in milliseconds… **Now**
it tracks the number of signed-in clients."

A reader arriving fresh cannot tell which sentence describes the shipped binary
and which describes a commit, and each "now" goes false silently the next time
the code moves — which H-2 has already shown happens here. `:228-229` compounds
it: "this codebase has already been bitten by twice" gives the codebase an
experience and states a count nothing in the repository lets a reader check.

**The honest tension**, which the Editor reviewer named and I agree with: a
security document that lists past vulnerabilities is a normal and useful thing.
But these sentences are not in a fixed-issues section — they are woven into the
paragraphs stating the current bounds, which is what makes the current bound hard
to read out. **The fix is separation, not deletion**: state the bound in the
present tense where the bound is stated, and keep the history under its own
heading where a date belongs.

---

### M-20 — `docs/next-increment.md` is a working session log, and one of its headings is now false

**Location**: `docs/next-increment.md:46-48`, `:98`, `:112-115`, `:54-58`,
`:127-151`

**Personas**: Editor F4

**Finding**: The file is not a document about the program; it is the record of a
measurement session, addressed to the person who ran it.

- **A heading contradicted by its own first word.** `### Rooms are not encrypted,
  and createRoom says otherwise` — followed immediately by "**Done.**" A reader
  scanning headings takes away the opposite of what the section says.
- **A heading addressed to the author's process** (`:98`, "What was measured, so
  it need not be measured again").
- **Prose about the prose** (`:112-114`): "this is the note that stops someone
  adding them on the assumption they are required."
- **An antecedent that is not in the repository** (`:115`): "does not cause the
  hot loop **the note warned of**" — no note has been introduced.
- **A whole section documenting an out-of-repository spike harness**
  (`:127-151`): "The spike lives outside the repository"; a Firefox snap `/tmp`
  quirk; a bug in the author's teardown script narrated as it happened.

The measured findings at `:100-125` are worth keeping — they are checkable facts
that save work. The framing around them is not.

**Suggested fix**: rewrite the stale heading to match its body. Retitle `:98` to
name the findings rather than the act of measuring. Cut `:112-114`'s
self-reference and `:115`'s "the note". Either move `:127-151` out with the spike
it documents, or reduce it to the two facts that outlast the session: sample the
client's sync state rather than screenshotting, and confirm the port is free
rather than trusting the kill.

---

### M-21 — The validated identifier types do not survive one actor hop

**Location**: `marilwyd/room_member.pony:16,21`; `marilwyd/room.pony:280`, `:290`,
`:297`, `:420`, `:434`, `:503`, `:582`; `marilwyd/user.pony:285`, `:295`, `:306`,
`:319`; `marilwyd/device.pony:155`, `:179`, `:192`, `:203`;
`marilwyd/room_directory.pony:63`, `:110`

**Personas**: Principles F4 — a principles violation no other reviewer reached,
which marks a blind spot — with API/Design 18 and Principles F6 independently
reporting the `Localpart` half.

**Finding**: `docs/architecture.md` states the intent: the identifier types "exist
because a room id, an event id and a user id are all text and arrive at handlers
side by side, where nothing but parameter order would keep them apart." Yet the
receiver protocol — the interface layer whose whole claim is that "what can be
asked and what can come back are both visible in the types" — takes raw `String`.
`Room` holds a real `RoomId` in `_state.id` and unwraps it to call them; `User`
and `Device` then key their maps by that `String`. So the one place in the program
where a room id and a user id genuinely do arrive side by side —
`Room.send(user_id: String, …)`, `Room.leave(user_id: String, …)`,
`Device.room_state(room_id: String, …)` — is precisely where the validated type
has been discarded. `RoomId.string()` returns `String iso^`, so each hop also
allocates.

The other direction is worse: a room id arriving *from a client* is never wrapped
at all. `RoomDirectory.with_room(room_id: String, …)` takes text straight from a
path parameter to a map lookup, and `RoomId.matches(supplied: String)` exists
because of this — the type compares itself against raw text rather than against
another `RoomId`. `RoomDirectory` does the same to the id it has just minted
(`room_directory.pony:63`). The validated form survives two statements.

**The `Localpart` half, reached independently by two other reviewers.**
`docs/architecture.md` lists `Localpart` among six types each of which "has a
private constructor and a factory that can refuse, so an invalid one cannot be
built." Principles F6 verified all six in a table: five have a private `_create`
and a `Make*`/`RoomAliases` factory; `Localpart` is a `primitive` with one
`check(String): (String | None)`, no type, no constructor, and no value. A
localpart therefore travels the program as a bare `String` — exactly what
`RoomId`'s and `DeviceId`'s docstrings argue against. Principles F6 adds a
secondary point worth keeping: for the five that do qualify, the refusing factory
refuses *CSPRNG failure*, not invalid input — only `RoomAliases` refuses bad
text — so "an invalid one cannot be built" is true only in the sense that the
private constructor is the only door.

API/Design 18 adds the two shape defects in the same family:

| Type | Factory | Returns |
|---|---|---|
| `RoomId`, `EventId`, `DeviceId`, `AccessToken` | `MakeX` | `(X \| NoSecureRandom)` |
| `RoomAlias` | `RoomAliases` (plural noun), `apply` **and** `make` | `(RoomAlias \| InvalidAlias)` |
| `Localpart` | `Localpart.check` | `(String \| None)` — **error-first** |

`RoomAliases` is the one plural-noun factory in a repository where every other
is `MakeX` (`MakeHomeserver` and `MakeStreamEpoch` included), and it offers two
entry points where the others offer one. And `Localpart.check`'s return
convention is inverted from everything around it — a `String` means *failure* and
`None` means *valid* — so its call sites read `match Localpart.check(x) | let e:
String => return StartupError(…)`, which is the opposite shape of every other
validated-value match in the codebase.

**On the `claude-lessons` tension**, which the reviewer raised and resolved
correctly: `design.md`'s "Pony has no zero-cost newtypes" warns against wrapping
values that get iterated in bulk. Room ids are low-frequency per-message
identifiers, and the lesson explicitly allows a wrapper for those. The current
code already pays the wrapper's cost — it throws the wrapper away at the boundary
and keeps only the allocation.

**Suggested fix**: change `RoomMember.joined`/`departed` and the `User`/`Device`
room behaviours to take `RoomId`. `RoomId` is `class val` and already sendable;
the map keys need `Equatable`/`Hashable`, which is the real cost. **This is not
small — it is the owner's call.** The alternative is to amend
`docs/architecture.md` to stop implying the validated form propagates, and to
move `Localpart` out of the six into its own sentence.

---

### M-22 — `Room.join`'s `watching` parameter is defaulted, defeating the guarantee its own comment claims

**Location**: `marilwyd/room.pony:197-231`, with `:56-95` and
`room_directory.pony:37-42`

**Personas**: API/Design 11

**Finding**:

```pony
be join(user_id: String, user: RoomMember tag, receiver: MembershipReceiver tag,
  watching: (User tag | None) = None)
=>
  …
  // Taken here rather than by a second call, so a caller cannot join
  // somebody and forget to.
  match watching
  | let account: User tag => _watching(user_id.clone()) = account
  end
```

The comment states the design intent exactly and the `= None` default defeats it:
a caller *can* join somebody and forget to, and it compiles. The consequence is
silent — the member is in the room, receives events, and never receives ephemeral
state (typing, receipts) because they were never added to `_watching`.

**Evidence**: The tests already exercise the failure path —
`wake_tests.pony:686` calls `_room.join("@alice:example.test", _user, this)` with
three arguments. Both production call sites (`rooms.pony:516`, `:546`) pass four,
so this is latent today.

Related shape problem at the same signature: both production call sites are
`room.join(s.user_id, s.user, this, s.user)` — the same actor passed twice, once
widened to `RoomMember tag` and once as `User tag`. In every call site in the
repository `watching` is either `user` or omitted; it has never been an
independent value.

**Suggested fix**: drop the default and make `watching` required, or drop the
parameter and take a `(User tag | UserLink tag)` for `user` so the room decides
for itself — it already distinguishes the two cases by whether the member watches.

---

### M-23 — `_KeysBody` is the general bounded-object reader wearing a keys-specific name, bound and error

**Location**: `marilwyd/published_keys.pony:70-88`; non-key call sites
`ephemeral_http.pony:31`, `:212`, `key_backup_http.pony:36`

**Personas**: API/Design 6

**Finding**: Eight call sites; four are key endpoints. The others are
`POST /rooms/{id}/read_markers`, `PUT /rooms/{id}/typing/{userId}` and
`POST /room_keys/version`. Two consequences:

- **The bound is inherited, not stated.** A read-marker body carries an event id
  and a typing body carries a boolean, and both are allowed `MaxKeysBody()` =
  49,152 bytes — a figure whose docstring justifies it as "a real upload from
  Element 1.12.25 is 12,698 bytes — one device key object and fifty one-time
  keys." Receipts and typing have no bound of their own at all; they have the
  key-upload one. `ServerLimits`' docstring says "Every per-endpoint limit sits
  under it", which is true, and `docs/architecture.md` says every body goes
  "through one checked reader", which is the claim H-1 already falsifies.
- **The error message is wrong where it reaches a client.**
  `POST /room_keys/version` with a non-object body answers "Key uploads must be a
  JSON object" (`key_backup_http.pony:48-51`). In `ephemeral_http` the
  `MalformedKeys` arm is discarded, so nothing leaks there.

The general form already exists one file away: `_ObjectBody(body, max_bytes,
max_depth)` at `login_limits.pony:92`. `_KeysBody` is `_ObjectBody` plus a
constant and an error primitive.

**Suggested fix**: have the three non-key sites call `_ObjectBody` with a bound
they declare (`MaxReceiptBody`, `MaxTypingBody`, `MaxBackupBody`), and leave
`_KeysBody` to key uploads.

---

### M-24 — The receiver protocol has three names for "your token names no live session", and a fourth that means something else

**Location**: `marilwyd/user_receiver.pony:11` (`token_rejected`),
`device_receiver.pony:11` (`devices_refused`),
`revocation_receiver.pony:14` (`revocation_rejected`),
`token_receiver.pony:11` (`token_refused`)

**Personas**: API/Design 8

**Finding**: One fact — the bearer token does not resolve — has three
interface-specific names, and all three produce the identical `401 UnknownToken()`
response (23 handlers, `logout.pony:91`, `logout.pony:155`). A fourth name,
`TokenReceiver.token_refused()`, means something entirely different — the registry
could not *mint* a token — while differing from `token_rejected` by one word.
`_LoginHandler` implements `token_refused`; every other handler implements
`token_rejected`. A reader moving between them has to check which is which each
time.

The wider vocabulary spells the negative answer seven ways across 28 interfaces —
`_missing`, `_unknown`, `_refused`, `_rejected`, `no_such_X`, `no_X_made`,
`_taken`. Some of those distinctions are real and documented (`alias_taken`
versus `room_refused` is argued well in `room_creation_receiver.pony`). The
token-rejection triple is not.

**Suggested fix**: settle on one spelling — `token_rejected` reads best — on all
three interfaces, and rename `TokenReceiver.token_refused` to something that
cannot be confused with it (`no_token_minted`).

---

### M-25 — `LogoutSuccess()` is the empty-object body for seven endpoints that are not logout

**Location**: `marilwyd/documents.pony:181-188`; call sites
`ephemeral_http.pony:122`, `:127`, `:209`, `account_data.pony:53`,
`rooms.pony:949`, `keys_http.pony:245`, `to_device_http.pony:254`,
`logout.pony:37`, `:153`

**Personas**: API/Design 5

**Finding**: Nine call sites; two are logout. The other seven are read receipts,
read markers, typing, `PUT account_data`, invite, cross-signing key upload and
`sendToDevice`. The docstring is a specific factual claim about which endpoints
use it — "The body of `POST /_matrix/client/v3/logout` and of deleting devices" —
and it is wrong about seven of the nine.

This is the "bad name repeated everywhere" case. Reading
`_InviteHandler.membership_changed`:

```pony
be membership_changed(room: RoomId) =>
  _respond(stallion.StatusOK, LogoutSuccess())
```

a reader has to go and check whether inviting somebody logs them out.

**Suggested fix**: rename to `EmptyObject` (or `NoContent`) and rewrite the
docstring to say what it is: the body for every endpoint whose success carries
nothing.

---

### M-26 — The `event_refused` union is spelled by hand at every implementor

**Location**: `marilwyd/event_receiver.pony:10`, `marilwyd/rooms.pony:673`,
`marilwyd/user_link.pony:762-763`, plus `link_tests.pony:572`, `:843`,
`wake_tests.pony:202-203`, `:292`, `:316` — eight occurrences, verified by grep.

**Personas**: API/Design 9, Principles F9

**Finding**: `(NotInRoom | NoEventId | BridgeDown | TooManyLines)` written out
eight times. Because the receivers are structural interfaces, every implementor
must spell the whole union; adding a fifth refusal reason is an eight-site edit,
and a site that misses it silently stops satisfying the interface.

The codebase already knows the fix and uses it twice —
`type _ReceiptSource is (ReadReceipt | FullyRead)` (`ephemeral_http.pony:41`) and
`type _StateReading is (AllState | MembersOnly)` (`rooms.pony:731`), both with
docstrings on the alias. `room_refusal.pony` is already the file that collects
these primitives; it is missing the type alias that names their union. The
principle at stake — "each layer should define its own error vocabulary *as a
concrete type*" — is met everywhere else in this codebase.

**Suggested fix**: `type EventRefusal is (NotInRoom | NoEventId | BridgeDown |
TooManyLines)` in `room_refusal.pony`, used everywhere.

Related and lower: the error types describe themselves three ways — a `.message`
field (`StartupError`), a `message()` method (the six in `room_refusal.pony` and
others) and a `string()` method (`NoSecureRandom`, `InvalidAlias`). Every case is
met, but nothing enforces it, because there is no common interface. A new error
type can be added with no way to render it and nothing will complain.

---

### M-27 — `UserLink` has a four-call setup protocol with no ordering or completeness check

**Location**: `marilwyd/user_link.pony:74-133`, `link_directory.pony:54-72`,
`link_owner.pony:1-20`

**Personas**: API/Design 12

**Finding**:

```pony
link .> carries(room) .> directed_by(this) .> connect(opened, receiver)
```

`UserLink`'s constructor takes six values and leaves the actor unusable; three
further behaviours must arrive, in an order the type does not express. Forget
`carries` and the connection reads for nobody. Forget `connect` and nothing ever
happens. Forget `directed_by` and — per `LinkOwner`'s own docstring — "a
connection that dies without saying so is answered to the next join as though it
were alive", **which is the exact bug `LinkOwner` was introduced to fix**. The
interface makes that bug *testable*; it does not make it *unreachable*, and the
one call site is the only thing standing between them.

**Evidence**: Actor constructors cannot fail, so some of this is unavoidable, and
the supply-chain pattern is applied correctly to the fallible part — the
`irc.IRC` is what `Connect` may fail to produce. But `room` and `directory` are
**not** fallible inputs. They are tags `LinkDirectory` already holds at
construction time, so the justification that covers `connect` does not reach
them.

The contrast the reviewer drew is the reason this is a defect rather than a
taste: `Room` has a two-phase form of the same shape (`Room(id)` then
`created_by` or `declared`) with the same property — a `Room` that received
neither is a room with no `m.room.create`. There the second phase genuinely can
fail (`_write_room` returns `None` on a CSPRNG refusal) and the receiver is how
it reports, so the split is earned. `UserLink`'s is not.

**Suggested fix**: move `room: Room tag` and `directory: LinkOwner tag` into
`new create`; leave `connect` as the one behaviour that must arrive afterwards.

**Test**: `LinkDirectory` — the only thing that performs this four-call sequence
— is never exercised by any test (Tests M3), so nothing checks the sequence is
performed correctly either.

---

### M-28 — The bridge does every expensive step of an outbound message twice, half of it on the `Room` actor

**Location**: `marilwyd/room.pony:639-663` (`_TooLongToRelay`),
`marilwyd/user_link.pony:659-687` (`deliver`), `:145-166` (`relay`),
`:712-750` (`Said`)

**Personas**: Performance 5

**Finding**: To decide whether a message would become too many IRC lines,
`_TooLongToRelay` runs `Said(content)` — a full `JSONParser.parse` plus a
`ValidUtf8` pass — and then `SplitForIrc(text)`, the whole line-splitting
algorithm, **on the `Room` actor**. The result is reduced to a `Bool` and the
array discarded. The event is then fanned out and `UserLink.deliver` does all of
it again. Each message into a carried room is JSON-parsed twice, UTF-8-revalidated
twice and line-split twice, with `MaxEventBody()` = 32 kB as the ceiling on each
pass.

The docstring justifies doing the split twice — "Doing the work twice for a
message about to be refused is cheaper than being wrong about which ones those
are" — which defends the *refused* case. It does not cover the accepted case,
which is the common one, and it does not mention the JSON parse or the UTF-8 pass
at all. The half in `_TooLongToRelay` sits on the actor every message in that room
is serialized through, which is the worst available place for per-message work.

**Suggested fix**: have `_TooLongToRelay` yield the split lines rather than a
`Bool`, and have `Room.send` hand them to the carrier alongside the event. The
refusal stays synchronous — the client is waiting on it — and the split is paid
for once, on the actor that already had to do it.

---

### M-29 — `SessionRegistry` serialises every authenticated request behind an O(sessions) scan, and it is reachable unauthenticated

**Location**: `marilwyd/session_registry.pony:70-88` (`resolve`), and `devices`,
`revoke`, `revoke_devices`, `lookup_users` in the same actor;
`marilwyd/unrecognized.pony:33-46`

**Personas**: Performance 3 (Medium), Security F9 (Low) — the same actor reached
from two angles, the first on the serialization cost and the second on who can
drive it. Not averaged: Medium stands, and this is the one entry where an earlier
draft of this synthesis had effectively taken the lower severity by keeping only
the documentation tail. The finding proper is here.

**Finding**: Every authenticated endpoint begins with `sessions.resolve(t,
this)`. Grepping the handler constructors gives **24 call sites across twelve
files** — `rooms.pony` 5, `keys_http.pony` 4, and one or two in each of
`ephemeral_http`, `account_data`, `directory_http`, `key_backup_http`,
`to_device_http`, `authed_json`, `profile`, `sync`, `whoami`, `unrecognized`.
There is one `SessionRegistry` per process, so this is the design's single
serialization point.

`resolve` is a linear scan over `_sessions`, and each comparison goes through
`AccessToken.matches` → `ConstantTimeCompare`, which is a per-byte Pony loop over
a `ByteSeq box` — each byte a dispatched `apply` on a union type rather than a
`memcmp`. The registry's own docstring records 0.45 µs per stored session, which
is consistent with 64 hex characters through that loop, and draws the conclusion
itself:

> Since `/sync` long-polls, every signed-in client pays a scan every 25 seconds
> against every session stored, so the work is quadratic in sessions and falls on
> one actor: roughly 7,500 concurrent sessions saturate a core.

**Evidence**: Three things make it worse than one trip per request.

- **Two round trips on two endpoints.** `keys/query` (`keys_http.pony:113-121`)
  and `sendToDevice` (`to_device_http.pony:216-227`) call `resolve` and then
  `lookup_users` — two passes through the same actor for one request.
- **`/profile` is asked per participant.** By its own docstring Element asks it
  "as soon as [it] renders a room, and… again for every participant it does not
  recognise." On a bridged channel with several hundred participants that is
  several hundred full trips through the singleton for one room render — and a
  bridged channel with several hundred participants is the deployment the bridge
  exists for.
- **It is reachable from outside the trust boundary.** `_UnrecognizedHandler`
  resolves any bearer token it is offered before deciding what to answer, and
  `/_matrix/*endpoint` is a wildcard over four methods, so `GET
  /_matrix/anything` with `Authorization: Bearer x` drives the whole scan from an
  unauthenticated caller. The reason the token is checked there is sound and well
  argued — a client holding a token from before a restart learns the truth from
  whichever endpoint it reaches first — but the effect is that the most contended
  actor in the program takes work from outside the boundary, and `SECURITY.md`'s
  account of unauthenticated cost covers `/login` alone. Per-request cost is
  microseconds and this was not measured under load, which is why Security rated
  its half Low.

**The docstring states the fix and nothing implements it**: split a token into a
public selector to key on and a secret verifier to compare, which is O(1) and
still constant-time in the half that matters. That is correct and unbuilt.

**Documentation mismatch, and it is the load-bearing half.**
`docs/architecture.md` says of this scan: "That makes verification linear in
stored sessions, and every authenticated request pays it. `SECURITY.md` records
the cost." **`SECURITY.md` does not record the cost.** Its only statement is
"Token resolution is a linear scan for that reason rather than a keyed lookup" —
no figure, no statement that the work is quadratic in sessions, no ceiling. The
number lives in the `SessionRegistry` docstring, where the cross-reference does
not point, so a reader following the pointer finds nothing and a reader who never
opens `session_registry.pony` never learns the ceiling exists.

**Severity against what the program is**: 7,500 concurrent sessions is far above
what a personal homeserver reaches, which is why this is Medium and not higher.
The `/profile` fan-out on a large bridged channel is the case that reaches it
first, and it reaches it at a size the README's own use case describes.

**Suggested fix**: implement the selector/verifier split the docstring proposes,
or — if the ceiling is accepted — move the figure and the quadratic statement
into `SECURITY.md` so the cross-reference in `docs/architecture.md` lands
somewhere, and add the unauthenticated path to `SECURITY.md`'s account of
unauthenticated cost.

**Passes on the same actor**, recorded because they were checked: `RoomDirectory`
and `LinkDirectory` are genuinely off the hot paths. `RoomDirectory` is consulted
to *find* a room and never to deliver into one — `User._rooms` holds `Room tag`
directly and `Room._members` holds `RoomMember tag` directly, so `Room._append`'s
fan-out touches no shared actor. `LinkDirectory` is touched only on join, leave
and connection death.

---

## Low

Low here means a small cost, not permission to leave it. Several of these are one
line.

### L-1 — Asset-root containment is a character prefix, not a path boundary

**Location**: `marilwyd/config.pony:249` and `:304`

**Personas**: Security F10, Principles F7, Correctness 14, Adversarial F10 — four
reviewers, all Low, all agreeing it over-refuses rather than under-refuses.

`if resolved.path.at(asset_root.path, 0) then`. Both paths are canonical, so
there is no false negative — a file genuinely inside the root always matches,
which is the direction that matters. There is a false positive on any sibling
whose name extends the root's: `--asset-root /srv/element` refuses
`--credentials /srv/element-secrets/x.yaml` with a message stating a containment
that does not exist. Fail-closed, so not exploitable, but a startup refusal
stating a false reason costs an operator real time.

This is the opposite of the rule the repository states for itself. `_Upward`
(`contained_path.pony:31-40`) gets the analogous comparison right on segments and
says why, and `SECURITY.md`'s "What `--asset-root` exposes" says "The comparison
is on path segments and not on characters" — true of one of the two places the
program compares paths.

**Fix**: compare against `asset_root.path + "/"` (or require equality). Fix both
twins in the same change, along with the `try` in M-9.

### L-2 — `SECURITY.md` says signatures under another user id are "ignored entirely"; only the outer map is scoped

**Location**: `marilwyd/published_keys.pony:162` against
`marilwyd/keys_http.pony:305-313` and `SECURITY.md:300-301`

**Personas**: Adversarial F8 (sole finder)

`_UploadSignaturesHandler` filters the **top-level** map to `session.user_id`,
which is correct and which Security independently verified. `MergeSignatures`
then merges the *inner* `signatures` object without filtering its signer keys —
verified: `for (signer, entries) in _Nested(uploaded, "signatures").pairs()`.

So a body of
`{"@mallory:srv":{"MALLORYDEV":{…,"signatures":{"@victim:srv":{"ed25519:VICTIMKEY":"AAAA…"}}}}}`
makes `keys/query` for `@mallory:srv` serve Mallory's device key object carrying
a signature attributed to `@victim:srv`. Impact is small — `SECURITY.md` also
says marilwyd verifies no signature and clients must, so a forged one fails
client-side — but the sentence is a security claim and it is wrong. The same loop
is the growth vector in M-2(c).

**Test**: Tests M2 — reading *every* user id in the body instead of only
`session.user_id` leaves 260 tests green, and so does deleting the whole `for`
loop. `_ServeTwoAccounts`'s own docstring says it exists for exactly this ("or
sign a device the account does not hold") and the second half of its stated
purpose was never written.

### L-3 — `MaxIrcLines` bounds marilwyd's split, not the lines that reach the network

**Location**: `marilwyd/line_split.pony:1-9` (`IrcLineBudget`),
`marilwyd/room.pony:637-663`, against
`_corral/github_com_contact_red_irc/irc/wire.pony:106-120,182-203`

**Personas**: Security F8 (sole finder)

marilwyd cuts at `IrcLineBudget()` = 425 and refuses past `MaxIrcLines()` = 16
pieces. It then hands each piece to `irc.IRCSend.privmsg`, whose `Wire.privmsg`
defaults `max_text: USize = 400` and splits again. Every 425-byte piece becomes
400 + 25, so one Matrix message can become up to 32 IRC lines rather than 16,
half of them 25 bytes long. `SECURITY.md` states the narrower thing: "each
resulting line is cut to `IrcLineBudget` bytes. How many lines one message may
become is bounded by `MaxIrcLines`." Neither sentence holds — nothing on the wire
is 425 bytes and the ceiling is 2× what is claimed. The message is still bounded
and the injection defences are unaffected.

**Fix**: set `IrcLineBudget()` to 400 so the two splits agree and `MaxIrcLines` is
exact, or pass the budget through to `privmsg` explicitly.

### L-4 — Leaving a room answers `{"room_id": …}` where the architecture doc says `{}`

**Location**: `marilwyd/rooms.pony:568-569`, `documents.pony:144-152`,
`docs/architecture.md` Leave sequence

**Personas**: API/Design 13

`_MembershipHandler` serves both join and leave and answers both with
`RoomCreated`, whose docstring reads "The body of `createRoom`, and of joining or
leaving one. All three answer with the room's id, which is what the specification
gives each of them." `docs/architecture.md`'s Leave diagram says `200 {}`. The
Matrix client-server API defines an empty object for leave. An extra field will
not break a client, so this is naming and documentation rather than
interoperability — and the name is the sharper half: `RoomCreated` is the body of
leaving a room.

**Fix**: answer leave with the empty object (`_InviteHandler` already does), and
either rename `RoomCreated` or confine it to createRoom and join.

### L-5 — A room is registered in the directory before it is known to be a room

**Location**: `marilwyd/room_directory.pony:59-83` and `:172-201`

**Personas**: Correctness 11

`create_room` writes `_rooms(key)`, `_aliases(text)` and `_published(key)` and
*then* sends `room.created_by(...)`, which can answer `room_refused` when
`_write_room` cannot mint an event id. The directory is never told, so the alias
stays permanently claimed by a room the client was told did not exist. `for_user`
has the same shape, and `_theirs` then caches the broken room, whose fast path
hands it to the next join without re-attempting the declaration.

`_DeclaredThen`'s docstring shows this class of bug was already found once here:
"The answer used to be sent the moment the room actor existed, with the
declaration's own outcome dropped on the floor." The answer was fixed; the
registration was not. Only reachable on a CSPRNG failure, which is why this is
Low — but the state is durable for the life of the process where the refusal is
transient.

### L-6 — `Room._position` and `RoomEvent.position` are dead, and three documented methods have no callers

**Location**: `marilwyd/room.pony:40`, `:616`; `create_room_request.pony:50-54`;
`room_id.pony:30-40`; `room_alias.pony:24-30`; `room_state.pony:124`;
`pending.pony:346-347`

**Personas**: Correctness 13, API/Design 15

`Room._position` is incremented on every `_append` solely to fill
`RoomEvent.position`, which is never read in production — the only reference is
`room_tests.pony:130`, on an event the test constructs itself.
`CreateRoomRequest.encrypted()`, `RoomId.matches()` and `RoomAlias.matches()`
have zero call sites beyond their definitions. `RoomState.members()` is called
only from `room_tests.pony:102-104`. `Pending.events()` is a weaker fourth case —
tests only, and exactly `since(None)`.

`RoomId.matches`' docstring is a five-line argument for why it uses ordinary
equality rather than `ConstantTimeCompare` — a design decision defended at length
for a method nothing calls. That is worse than the method alone: a reader spends
attention on a tradeoff that is not live, and a future caller takes the docstring
as evidence the method is load-bearing.

Contrast `SyncView.gap`, which is also read only by tests but is *documented as
deliberate* in `SECURITY.md`. `Room._position` has no such justification recorded
anywhere.

**Fix**: delete the three methods and `_position`/`RoomEvent.position`. If
`Pending.events()` is wanted for test convenience, the tests can call
`since(None)`. **Note that `RoomState.withdraw` is not in this list** — it is
H-3's missing wiring, not dead code to delete.

### L-7 — A refused path traversal logs a response with no request

**Location**: `marilwyd/routes.pony:50` against `:56-58`, and
`marilwyd/request_log.pony:31-46`

**Personas**: Wildcard 12 (sole finder)

`_ContainedPath` is registered before the logger and returns `InterceptRespond`
for a `..` segment. Reading hobby's `_connection.pony:203-209`,
`_RunRequestInterceptors` short-circuits — so `_LogRequest` never runs — but hobby
then builds a `ResponseContext` and *does* call `_RunResponseInterceptors`, so
`_LogResponse` runs. Under `--log-requests` the result is a `<--` line with no
`-->` before it, inverting the invariant `_LogRequest`'s own docstring establishes
as the way to read this log ("a request which never completes is visible as a
`-->` line with no `<--` after it"). Nothing tells an operator how to read an
unmatched `<--`, and the one class of request that produces it is the one they
would most want to see arrive.

**Fix**: register `_ContainedPath` *after* the two logging interceptors. The
stated invariant is "nothing outside `--asset-root` is ever reached by a
handler", and `_LogRequest` is an interceptor, not a handler — it returns
`InterceptPass` unconditionally and touches no file — so this preserves the
property exactly.

### L-8 — The Element tarball is committed to its final name before its checksum is checked

**Location**: `Makefile:69-79`

**Personas**: Wildcard 10 (sole finder)

The `.tmp`-then-`mv` makes the download atomic; it does not make it verified. The
checksum lives in a different rule, and by the time it runs a
complete-but-wrong tarball already occupies the final path. Once it exists,
`$(ELEMENT_TARBALL)` is satisfied and make never re-runs `curl`, so
`sha256sum -c` fails on every subsequent `make run` forever, with no suggestion
that the fix is `rm element-source/element-v1.12.25.tar.gz`. `clean` and
`realclean` both stay inside `build/`, which is correct for a 40 MB artefact and
completes the trap.

Two smaller notes on the same rules: `build/element` does not depend on the
`Makefile`, so correcting `ELEMENT_SHA256` alone leaves `build/element` newer
than the tarball and the corrected checksum is never checked; and the SHA-256 has
no recorded provenance.

**Fix**: move `sha256sum -c` into the download rule, between `curl` and `mv`.
Then the retry story is "run make again".

### L-9 — `RoomEvent.render`'s `match` block is mis-indented in the shipped source

**Location**: `marilwyd/room_event.pony:70-74`

**Personas**: API/Design 23

The arm body sits at the `match`'s own indentation and the `end` sits two columns
further left than the block it closes. It compiles and lints clean, and it reads
as though the conditional ended at `| let k: String =>` and the two appends are
unconditional — in the one function that decides what a client sees for every
event in the system. Every other `match` in the file and the surrounding files is
indented normally.

### L-10 — `SyncView` takes eight positional arguments, two of them the same type and adjacent

**Location**: `marilwyd/sync_view.pony:1-31`, constructed at
`device.pony:473-481`

**Personas**: API/Design 20

`events'` and `state'` are both `Array[RoomEvent] val` and adjacent. Swapping
them compiles and produces a sync document rendering the room's state as its
timeline and its timeline as its state — which a client shows as a room full of
membership events and no messages. One construction site, so the risk is
contained, but the project's own comment at `config.pony:208-209` sets the
standard: "Named arguments: `bind_host'` and `bind_port'` are adjacent strings in
the constructor, and this is the one place they are supplied."

Same class: `_JoinRoom`/`_LeaveRoom` pass a bare positional `Bool` in sixth
position (`rooms.pony:344-424`) where the same file 300 lines later does the job
properly with `type _StateReading is (AllState | MembersOnly)`.

### L-11 — `_JSONDepth.exceeded` is the only public mutable field in the package

**Location**: `marilwyd/jsondepth.pony:41`

**Personas**: API/Design 26

The other two fields are private; `exceeded` is a writable public field so
`_JSONDeeperThan` can read it. The type is package-private so the blast radius is
one package, but grep confirms it is the only public mutable field in
`marilwyd/`, and it is writable as well as readable by anything holding the
object. Worth fixing while C-1 is being fixed in the same file.

**Fix**: `var _exceeded: Bool = false` plus `fun exceeded(): Bool => _exceeded`.

### L-12 — `DisplayName`'s docstring describes un-escaping it does not do

**Location**: `marilwyd/profile.pony:31-68`

**Personas**: Correctness 12

The docstring says a bridged participant's id "carries the escaped form of a
nickname, so `@irc_fussake_bob=5bm=5d` reads back as `bob[m]`". The body extracts
`user_id.substring(1, colon)` and returns it unchanged; there is no inverse of
`GhostLocalpart` anywhere in the repository. `ProfileFor`'s docstring thirty
lines above says the opposite and is correct. **Two docstrings in one file assert
contradictory behaviour for the same value**, and the code matches the correct
one. Pattern D.

### L-13 — `LocalpartOf` returns the sigil when there is no colon

**Location**: `marilwyd/link_directory.pony:115-133`

**Personas**: API/Design 27

With a colon it strips the leading `@`; without one it does not. So
`LocalpartOf("@alice:x")` is `alice` and `LocalpartOf("@alice")` is `@alice`. The
function's contract is "give me the local part" and one of its two branches gives
back something that is not one. The result feeds `NameMapping.irc_nick`, so a
stray `@` would become an IRC nickname the network would refuse. Unreachable
today — session user ids always come from `Homeserver.user_id`.

### L-14 — `NoSecureRandom`'s one message talks about tokens, and reaches clients that asked for a room

**Location**: `marilwyd/access_token.pony:48-53`; used at `rooms.pony:332-334`
and `main.pony:95`

**Personas**: API/Design 17

"the system CSPRNG is unavailable, so no token could be issued" is the failure
value of `MakeAccessToken`, `MakeRoomId`, `MakeDeviceId`, `MakeEventId` and
`MakeStreamEpoch`. A client whose `createRoom` fails is answered `M_UNKNOWN` with
"no token could be issued", and the operator sees the same line when the *stream
epoch* cannot be minted at startup. The right shape is one file away:
`NoEventId.message()` is "The CSPRNG is unavailable, so no event could be
recorded."

### L-15 — `membership_refused(why: NotInvited)` and `state_refused(why: NotInRoom)` take a parameter with one possible value

**Location**: `marilwyd/membership_receiver.pony:14`, `state_receiver.pony:10`

**Personas**: API/Design 22

Both parameters are single-primitive types, so the argument carries no
information — and both handlers ignore it and name the primitive directly
(`rooms.pony:565-568`, `:825-828`, `:951-954`; `user_link.pony:812-815` returns
`None`). Grepping for `why.` across `marilwyd/` finds no call on either
parameter. `EventReceiver.event_refused` earns its parameter — four variants,
matched `\exhaustive\`. These two do not.

### L-16 — `_ResolveAliasHandler`'s `is` list omits an interface it satisfies

**Location**: `marilwyd/directory_http.pony:34-36`, `:93-96`

**Personas**: API/Design 21

It implements `room_identified(id: RoomId)` and passes `this` to
`room.identify(this)`, which takes a `RoomIdReceiver tag`. Structural typing makes
it work; the declaration does not say so. Checked mechanically across every
handler actor — this is the only occurrence, which is what makes it a slip rather
than a convention. The `is` list is the codebase's self-documenting record of
which contracts a handler participates in.

### L-17 — `--credentials` help text says JSON; the file is YAML

**Location**: `marilwyd/config.pony:101-104`

**Personas**: API/Design 1, which rated it Medium. **Low here** because the
operator who follows it is stopped immediately by a named `credentials-malformed`
startup refusal, and the README's worked example one page away is correct — the
cost is minutes of confusion, not a wrong deployment.

`ReadCredentials` parses with `YamlLoad` (`credentials.pony:137`),
`hash-password` emits YAML, the README example is YAML, and the Makefile default
is `credentials.yaml`. The one place an operator reads the format from the
program itself — `marilwyd --help` — names the wrong format, and an operator who
follows it gets `credentials-malformed`. The `--bridges` help immediately below is
correct, which makes this a stale line rather than a convention.

### L-18 — `README.md` says three routes carry a marker; six do

**Location**: `README.md:325`, against `marilwyd/routes.pony:66`, `:68`, `:89`,
`:214`, `:215`, `:216`

**Personas**: Editor F5, which rated it Medium. **Low here** because nothing a
reader does depends on the number — the paragraph's point survives it intact, and
the `hobby#1` marker itself is the grep that finds the set.

The source has the count right (`routes.pony:16-19`: three namespace roots, and
`/_matrix` needs one companion per method, which is four). The README counted
namespaces and wrote routes. Best fix is to drop the count — it is the detail most
likely to go stale again and the paragraph works without it.

### L-19 — `SECURITY.md` names a stdlib type that does not exist, and spells it two ways

**Location**: `SECURITY.md:148` (`JsonParser`) and `:159` (`JSONParser`)

**Personas**: Editor F11

The stdlib type is `JSONParser`; `marilwyd/` names it twelve times and never as
`JsonParser`. `Json*` is the pre-0.69 spelling, and `README.md:100-103` records
the rename that removed it.

Same file, same class: `SECURITY.md` names the same constants two ways —
`MaxRoomMembers()` at `:246` and `MaxRoomMembers` at `:450`; `MaxIrcLines()` at
`:246` and bare at `:461`; `IrcLineBudget` and `MaxEventBody` bare throughout
while eight others carry parens (Editor F12). They are primitives with an
`apply`, so the parenthesised form is the one matching how they are called.

### L-20 — Measurement provenance and version-stamped numbers in comments and docstrings

**Location**: ~20 sites. Version-pinned: `marilwyd/sync.pony:13`, `:21`, `:117`;
`published_keys.pony:7`; `routes.pony:174-175`, `:203`; `keys_http.pony:80`,
`:268`; `key_documents.pony:23`; `key_http_tests.pony:127`. Unstamped provenance:
`session_registry.pony:19`, `:59`; `login.pony:61-62`; `room_event.pony:17-19`;
`login_limits.pony:13`; `room.pony:78`; `SECURITY.md:37`, `:75`, `:142`, `:152`,
`:162`, `:178`, `:190`; `Makefile:61`.

**Personas**: Editor F9, which rated it Medium. **Low here** because the numbers
themselves are correct and useful — no reader is misled today. What rots is the
framing and the version stamps, which is a cost that arrives on the next Element
bump rather than now.

The numbers are often the fact that changes a reader's decision; the provenance
verb is not, and the version stamps rot with nothing to catch them.
`docs/next-increment.md` and `docs/completion.md` carry the version stamp once at
the top of the file, where it can be updated in one place — that is the right
shape.

**Fix**: keep the number, cut the provenance verb — "36 syncs a second" rather
than "measured at 36 syncs a second". For the version-stamped figures, either
carry the stamp with the number or point at `docs/next-increment.md`.

### L-21 — Docstrings that explain how the thing works

**Location**: `marilwyd/room_event.pony:12-21`, `marilwyd/pending.pony:31-35`,
`marilwyd/session_registry.pony:19-25`

**Personas**: Editor F21

`pony-comments`: "A docstring gives a caller what they need to use the thing
correctly… It says nothing about how it works." `RoomEvent` spends ten lines on
why `content` is printed text; the caller's fact is the first sentence.
`Pending` states its internal representation in a class docstring (and the
rationale is also wrong — see H-6). `SessionRegistry` carries a performance
projection ("roughly 7,500 concurrent sessions saturate a core") and a proposed
alternative design, neither of which is a fact a caller uses.

**Fix**: keep the guarantee in the docstring, move the decision to a comment at
the code it explains. In `SessionRegistry`, keep the constant-time property and
the linear cost — a caller does need to know verification is linear in stored
sessions.

### L-22 — Prose defects with a smaller cost, grouped

**Personas**: Editor F13, F15, F16, F17, F18, F19, F20, F22

Each cites a broken rule, so each is a defect; they are last because the cost to
a reader is smallest, not because they can be skipped.

- **`README.md`'s `## Status` carries the entire feature narrative** — 857 words
  under a heading `pony-library-readme` defines as a short maturity statement, so
  a reader looking for "is this usable?" reads eight paragraphs to find out. The
  material is good and belongs in the README, under headings that name it. The
  README passes on all four "must not have" items (no badges, no Contributing, no
  License section, no table of contents).
- **Non-persons given knowledge, intent and obligation** — narrower than the
  codebase's voice, which is fine: `README.md:280` ("a client with no position is
  **owed** everything it **can already see**"), `README.md:26-27` /
  `SECURITY.md:253-254` ("asking to be found is asking for people to arrive
  uninvited"), `SECURITY.md:226-227` ("the honest field to set"),
  `docs/architecture.md:209` and `:654` ("answered with a corpse" / "a dead one" —
  the same idea, two metaphors, neither naming the mechanism),
  `ephemeral.pony:115-116`, `link_directory.pony:58-59`.
- **"Capability" carries four senses, one colliding with Pony's** —
  `room_id.pony:11` bolds "**It is half of a capability**" in the object-capability
  sense, which is never introduced, in a Pony codebase where the unmodified word
  means reference capability. `config.pony:227` uses the `FileCaps` sense;
  `session_tests.pony:355` the plain-English one; and `/capabilities` is a Matrix
  endpoint. Fix: "**A room id is half of the access control.**"
- **Wrapping breaks where a paragraph was edited without rewrapping** —
  `README.md:84` at 110 columns and `:44` at 31 mid-paragraph, in a file wrapped
  at 76; `room_id.pony:17-18` the same shape in a docstring.
- **Comments duplicated verbatim**, which is how one of them goes stale —
  `marilwyd_test/main.pony:403-405` and `:526-528`;
  `link_tests.pony:135-136` and `user_link.pony:494-495` across the package
  boundary; `room.pony:45-48`, `:223-224` and `docs/architecture.md:705-706`.
  `ephemeral_http.pony:203-205` shows the fix — name the other end, don't restate
  it.
- **Fifteen section banners in the test suite**, whose labels the `fun name()`
  declarations beneath already carry. Two are worse than decorative because they
  are relative to a development state a reader cannot see: `sync_tests.pony:365`
  ("the halves that were missing") and `:418` ("the rest of the catch-all rows").
  `tests.pony:238-242` is the one to keep — collapse the dashes, keep the prose.
- **Two `TODO`s written as prose with no issue link** — `rooms.pony:586-589`
  ("the first observed duplicate is the trigger for building one") and
  `SECURITY.md:209-212` ("The bound to add first, if this becomes real"). Both are
  honest and useful; they are the two places a reader is told work is pending with
  no way to check whether it has happened. Whether they should be issues is the
  owner's call.
- **Operator-facing drift in two documents** (API/Design 28). The README's route
  table spells two routes' path parameters differently from `routes.pony` —
  `send/:type/:txn` and `sendToDevice/:type/:txn` against the registered
  `:eventType/:txnId`. Harmless to a client, but the table is presented as *the*
  route list, so it is the one place a reader would take the spelling from. And
  `LoginSuccess.apply(user_id, access_token', device_id', server_name')`
  (`documents.pony:87-101`) is four bare `String`s, three of them carrying the
  `'` suffix Pony reserves for constructor parameters shadowing fields — there
  are no fields here, and `user_id` does not carry it. `WhoamiSuccess` beside it
  takes the typed `DeviceId`. The one call site (`login.pony:82-86`) uses named
  arguments, which is what saves four adjacent same-typed strings from L-10's
  problem.
- **`docs/architecture.md`, small batch** — `:293-295` states "**exactly one**
  `reveal()` in production" as a count in prose, where `SECURITY.md:61-62` states
  the same fact in the form that cannot rot ("grepping for it lists every place a
  token leaves marilwyd"); `:779-781` narrates "**Several defects in this codebase
  came from assuming otherwise**"; `:197-199` "was a real defect"; `:771-772`
  names `bridges.yaml` as though it were the configuration when the path comes
  from `--bridges`. The field tables at `:97-102` and four other ranges were
  checked against the source and match exactly — they are noted as where drift
  will land first, not as a defect.

### L-23 — Local waste on the bridge's per-line paths

**Location**: `marilwyd/line_split.pony:61-80` (`_Lines`), `:87-112` (`_Sized`);
`marilwyd/ghost.pony:1-33`, `:73-146`; `marilwyd/contained_path.pony:42-47`;
`marilwyd/device.pony:248-256`; `marilwyd/documents.pony:212-232`, `:270-300`

**Personas**: Performance 6, 7, 8, 9

Four small ones, each with a stated fix:

- **Byte-by-byte accumulation with a trailing `.clone()`.** `_Lines`, `ValidUtf8`
  and `GhostLocalpart` all build a `String ref` a byte at a time and clone it into
  a `String val`. `pony-ref` calls this out directly, and names the cause: the
  refcaps don't line up for a bulk operation. The fix is `recover val`, which this
  codebase already uses for exactly this shape in `RoomEvent.render`,
  `StateEvents`, `RoomMembers`, `PublicRooms` and `SyncDocument`. `_Lines` can go
  further and take one `substring` per line. `ValidUtf8` runs on every inbound IRC
  line and every nickname, so it is the most frequently paid.
- **Quadratic remainder copying** in `_Sized`: for a 32 kB line with no newlines,
  ~77 iterations each copying a shrinking ~32 kB tail — roughly 1.2 MB copied to
  produce 77 lines of 425 bytes. Walking an index over one buffer is O(n).
  M-28 means this runs twice per message.
- **`Device.sync`'s guard builds and discards two arrays on every parked sync.**
  `_describing` and `_ephemeral_since` each allocate a `recover iso Array`, walk
  the device's rooms, and are called only to ask whether the result is empty; on
  the answered path `_answer` calls both again. The parked path is the
  most-run path in the program. Fix: `_has_describing(since): Bool` and
  `_has_ephemeral(since): Bool` returning on the first hit.
- **`SyncDocument` renders in O(rooms × state events)** — the rendering pass walks
  the whole of `view.state` per grouped room, and `RoomId.string()` clones, so
  every comparison heap-allocates. The state could be bucketed in the pass
  immediately above that already visits it. Only fires on a fresh sync.

Also `_Upward` splits every request path with `String.split` (allocating an
`Array[String]` plus one `String` per segment) on an interceptor that runs for
every request including every asset during an Element page load. A single index
scan answers the same question without allocating, preserving the
segment-not-substring semantics the docstring correctly insists on.

### L-24 — Path parameters are stored and fanned out with no length bound of their own

**Location**: `marilwyd/rooms.pony:649` (`_kind`),
`marilwyd/ephemeral_http.pony:14` (receipt `eventId`),
`marilwyd/account_data.pony:50` (`type`)

**Personas**: Adversarial F11

`_PathParam` percent-decodes and returns whatever the route matched. The only
ceiling is stallion's `max_request_line_size`, default **8192**, which marilwyd
does not override (`ServerLimits` sets `max_body_size` only). `eventType` becomes
`RoomEvent.kind`, cloned into every member's `Device._pending` and retained until
acknowledged; `PendingLimit()` bounds the *count* at 1000, not the bytes, so
1000 × (32 kB content + ~8 kB kind) ≈ 40 MB per offline device. `SECURITY.md`'s
"Cost of a room" states the count bound and not the byte consequence. Escaping is
correct everywhere, so this is size, not injection. Confidence Medium.

### L-25 — Roughly half the public methods have no docstring, and the split is inconsistent inside single types

**Location**: repository-wide. Sharpest pairs: `room_state.pony:52` (`join`,
undocumented) against `:63` (`invite`) and `:70` (`withdraw`);
`room.pony:284` (`leave`) and `:562` (`state`) against `:197`, `:232`, `:380`;
`user.pony:285`, `:348` against `:100`, `:114`, `:122`; `main.pony:173`, `:180`
against `:138`, `:152`; `config.pony:221` against `:270`.

**Personas**: Principles F8

Public **types** are 100% documented — zero public `primitive`/`class`/`actor`/
`trait`/`interface`/`type` lacks a docstring. Public **methods**: 173 documented,
~157 not (count from a purpose-written parser, corrected twice; the specific
pairs cited were each verified by reading).

Most of the 157 are defensible as a convention — a single-`apply` primitive whose
type docstring states exactly what `apply` does. What is not defensible is the
split *inside* one type, where nothing distinguishes the documented member from
the undocumented one. `RoomState.join` is the sharpest: a non-obvious side effect
(an invitation is spent by being accepted) explained in a `//` comment where
`invite` two methods below puts the same class of explanation in a `"""`.
`Room.state` is second: its neighbour `Room.members` documents the authorisation
rule by pointing at it — "Members only, **like `state`**" — and `Room.state` has
no docstring for that reference to land on, so the rule is stated once, in the
method that does not implement it.

**Fix**: decide the convention and state it once — "a type whose only public
method is `apply` documents it on the type" is fine — then make the eight in-type
mismatches match their neighbours. `Main.listening` and `Main.listen_failed` need
only their `//` turned into `"""`.

### L-26 — Test-suite weaknesses not covered above

**Personas**: Tests M4–M9 (rated Medium), L1–L3, L5, L6, L7, L9

**Grouped at Low rather than filed at Medium beside H-8, and the reason is the
line H-8 draws**: each of these is a real gap and several close in one line, but
none of them guards a *stated written guarantee* the way H-8's five do. They are
coverage debt; H-8's five are enforcing branches for sentences in `SECURITY.md`
and `docs/architecture.md`. Ranked below H-8, not dismissed — M4, M6 and M9 each
protect a documented behaviour and each is cheap.

- **`UserLink`'s early-membership buffer has no test** (M4). `grep -rn
  "MaxEarlyMembers\|_early" marilwyd_test/` returns nothing. All three test
  drivers call `carries(_room)` *before* feeding any IRC line, so the `else`
  branch that fills `_early` is dead in every test. The whole mechanism can be
  deleted with 260 tests green, and its docstring says what that costs: "the list
  a person most wants, the one they arrive to, is the one always missed" — a
  shipped bug report. Fixing it is a one-line reordering in an existing test: feed
  the `353` name list before `carries(_room)`.
- **An outbound `m.notice` never leaves as a NOTICE** (M5). The only test that
  drives `UserLink.deliver` end to end sends `m.text` only, so
  `_OutboundRelay.notice` is never reached and the `notice` branch can be deleted
  with the suite green. One extra line and one assertion closes it.
- **`sendToDevice`'s "the sender is the token, not the body" is untested** (M6).
  No test has a sending and receiving account that differ, so stamping `_sender`
  from the addressed user id, or from a body field, leaves the suite green.
  `_ServeTwoAccounts` already provides what this needs.
- **`GhostLocalpart` injectivity is asserted by three examples where a property
  belongs** (M7). Both `SECURITY.md` and `docs/architecture.md` state injectivity
  as a guarantee. The round-trip law — `unescape(GhostLocalpart(n)) == fold(n)` —
  proves it for free and checks from a second angle. The suite already shows it can
  do this well: `_SplittableText` (`line_split_tests.pony:77-113`) is a textbook
  weighted generator with boundary cases enumerated. The rigour did not carry
  across to the neighbouring escaping function.
- **Four routed endpoints have no HTTP test at all** (M8): `GET
  /_matrix/client/versions` (the first request every Matrix client makes),
  `POST /rooms/{roomId}/leave` (which is H-3's endpoint, and which drives
  `LinkDirectory.close`), and both `account_data` methods. Every other endpoint
  has at least a missing-token test, so a route-table mistake on any of these
  ships unnoticed — and `tests.pony:32-46` records that this failure mode is real.
- **`HashPassword` and `Chomp` are untested, and the fixture forks their format**
  (M9). `Chomp` is a public pure primitive with a nested off-by-one over `\r\n`;
  changing it to strip all trailing newlines leaves the suite green and silently
  changes what password a hash corresponds to. Worse, `_WriteFixtures._entry` is a
  **second, independent implementation** of the credentials-entry format that
  already differs from the shipped one — which is exactly the drift
  `hash_password.pony`'s docstring says cannot be allowed, and the mechanism
  behind M-1.
- **Two tests assert only a negation and pass on an empty response** (L1) —
  `_TestADeeplyNestedDeviceDeleteIsRefused` and
  `_TestADotDotFilenameIsNotRefused`. Both fire for the breakage they target, so
  neither is worthless, but both pass vacuously for anything that stops the server
  answering, and both have siblings in the same file that assert status *and*
  errcode.
- **Depth boundaries are tested from one side only, except for login** (L2).
  `CheckLoginShape` has both sides with the second explicitly justified. The four
  other depth-bounded paths are tested only from above, so an off-by-one in
  `_JSONDeeperThan` or a blanket refusal of nesting would go unseen.
- **`MaxAlgorithmName` and `_WantedEncryption`'s three fallbacks are untested**
  (L3) — deleting the length guard leaves the suite green, and the value is
  written into room state every member reads.
- **`_SyncHandler.dispose` and `Device.abandon` are untested** (L4) — see M-8.
- **The rest of `UserLink`** (L5): `expired()` and the `JoinDeadline()` timer,
  `part()`/`departed()` → `_close()`, `irc_registered`'s `InvalidName` branch,
  `irc_dropped`, `irc_unparseable`, and `relay`'s `else`. None high-value alone;
  together the untested half of an 815-line actor whose other half is unusually
  well tested.
- **Request logging is untested, including its stated token-safety property**
  (L6). `_TestConfig` never passes `--log-requests`, so `_LogRequest`/`_LogResponse`
  are never constructed. Nothing checks that a token in a query string stays out of
  the log line, and nothing checks `_LogClock.stamp`'s zero-padding arithmetic,
  which does an `isize` subtraction that would abort on a four-digit millis value.
- **`_ExpectWoken` re-syncs from a counter, not the position it was given** (L9,
  `wake_tests.pony:169-177`). It works today because the positions are small
  integers — a coincidence rather than a protocol. `_LinkUnderTest.synced` does it
  correctly and is the model.

### L-27 — No LICENSE, and `corral.json`'s `info` block is entirely empty

**Location**: repository root; `corral.json:16-23`

**Personas**: Wildcard 11

No `LICENSE`, no `COPYING`, no license statement, and every field `corral.json`
offers is blank — including `name` and `license`. `SECURITY.md` closes with "This
is a personal project and not yet released", which makes the absence internally
consistent. Two things sit awkwardly against that: the repository's own
dependencies are fetched from `github.com/contact-red/*` by tag, and it ships a
`corral.json`, which is the file that makes it consumable as a Pony dependency.
Anyone who does consume it has no grant to do so. One commit to fix, either way —
if "not released" is the intent, saying so in `description` beats six empty
strings.

### L-28 — The Element pin has no review trigger

**Location**: `Makefile:1-3`; absence of `.github/dependabot.yml`

**Personas**: Wildcard 13

Element is the largest body of third-party code this project ships, it executes
in the user's browser, and it is served from the **same origin** as the Matrix
API — which is the point of the design, and also means an Element vulnerability
is a vulnerability against the tokens marilwyd issues. Nothing tracks the pin: no
dependabot, no renovate, no scheduled workflow, and no note recording when it was
last reviewed. `SECURITY.md` discusses `--asset-root` exposure at length and does
not mention that the served application is a frozen third-party bundle. The pin
also anchors the project's own evidence — `completion.md` and
`next-increment.md` are both explicitly scoped to "Element 1.12.25 — the version
the Makefile pins" — which is a second reason for it to be deliberate and dated.

**Fix**: one sentence in `SECURITY.md`, plus a `.github/dependabot.yml` for
`github-actions` (which would also have caught the `checkout@v4.1.1` /
`super-linter:v3.8.3` drift in M-12). Dependabot cannot watch a `Makefile`
variable, so the Element pin itself needs the sentence rather than the tool.

### L-29 — Unused package alias, and `pony-lint` does not catch it

**Location**: `marilwyd/main.pony:5` (`use irc = "irc"`)

**Personas**: Wildcard 14

`main.pony` contains no `irc.` reference; the `irc` package reaches the build
through `connect.pony` and `link_directory.pony`. Every `use x = "y"` alias in
both packages was swept and this is the only unused one, which is a good result
for 21,000 lines. The second half matters more: `make lint` is green, so
pony-lint has no unused-import check. That is a blind spot in the gate, not a
defect in this file.

### L-30 — `docs/architecture.md`'s bridged-join diagram attributes cleanup the handler does not do

**Location**: `docs/architecture.md`, "Join a bridged channel", against
`marilwyd/rooms.pony:550-558`

**Personas**: Correctness 10, Adversarial F9

The diagram shows `MH->>LD: close(...)` and `MH->>R: leave(user_id, this)` on the
refusal path. `_MembershipHandler.join_refused` does only the 403. The cleanup is
real but lives in `UserLink._finished` (`user_link.pony:182-202`), which every
`join_refused` path calls. The shipped behaviour is correct and the diagram
misattributes it — which matters because the diagram is what somebody reads
before changing this path, and it invites a "fix" that would double-close.

### L-31 — `SyncDocument` builds JSON by hand while the rest of `documents.pony` uses `JSONObject`

**Location**: `marilwyd/documents.pony:190-327`

**Personas**: API/Design 25 — filed by that reviewer as a note rather than a
defect, and I agree.

Fifteen of the sixteen document primitives build their body with
`JSONObject`/`JSONPrinter`. `SyncDocument` is 130 lines of `out.append` with five
`var first = true` flags and the only out-parameter in the repository. The root
cause is deliberate and documented: `RoomEvent.content` is already-printed JSON
text for a stated ORCA reason, so pre-rendered text cannot be nested into a
`JSONObject`. **That decision is right.** Its cost is that every document
*containing* an event has to be concatenated, and that cost is not recorded
anywhere. Recorded here because the next person to touch `/sync`'s output will
meet it, and because the tradeoff deserves a sentence in `RoomEvent`'s docstring
saying what it costs upstream, not only what it saves.

---

## Passes

Checked across nine lenses and correct. This is not a courtesy list — several of
these were attacked directly and held.

**Security boundaries.**
- **Path traversal.** `_ContainedPath` is registered before every other
  interceptor, `_Upward` compares whole `/`-separated segments, and neither
  stallion nor hobby percent-decodes the request target — verified by grep over
  both dependency trees. `%2e%2e` arrives as six characters naming a directory,
  `..config` is served, `..` is refused, and an absolute `filepath` is caught by
  `FilePath.from`'s own containment. The symlink caveat in `SECURITY.md` is
  documented and accurate.
- **Authorization is present on every route and correctly scoped.** All 34 rows of
  `routes.pony` walked. The unauthenticated set is exactly `GET /`, `/element`,
  `/element/config*.json`, the two `ServeFiles` mounts,
  `/_matrix/client/versions`, and `GET`/`POST /login`. `revoke_devices` matches
  device id **and** user id; `_remove_device`'s cleanup is keyed by that user id
  too; `published_keys(receiver, own)` withholds the user-signing key from
  everyone but its owner; the `:userId` path parameter is ignored everywhere with
  an explicit note that it is the client repeating itself; `Room` enforces
  membership itself, so a leaked room tag grants nothing.
- **Injection, both directions.** Every hand-built document puts client text
  through `JSONPrinter.print`, and every stored `content` was printed at the
  boundary — each concatenation site was checked individually. Outbound,
  `SplitForIrc` splits on CR and LF first and always, and the `irc` package splits
  again and strips NUL and `\x01`, so a Matrix message cannot become a second IRC
  command or forge a CTCP. A client cannot forge room state either: `Room.send`
  passes `state_key = None`, so `RoomState.apply_state` ignores whatever
  `eventType` the path names.
- **`AccessToken` is structurally unprintable.** No `is Stringable`, no
  `string()`, one `reveal()` with a single production call site.
  `ConstantTimeCompare` rejects on length before reading a byte and accumulates
  with `or`/`xor`.
- **Credentials at rest.** PBKDF2-HMAC-SHA256 at 600,000; `_Entry` validates the
  algorithm, the iteration floor, the salt length and — the one that matters — a
  hash whose length is *exactly* `Pbkdf2KeyLength()`, so a truncated entry cannot
  narrow its own comparison. `hash-password` reads stdin, not `argv`. Both YAML
  files are gitignored, untracked and mode 600.
- **CSPRNG discipline** fails closed at all five mint sites, and every caller
  propagates the refusal rather than falling back.
- **Bridge TLS.** `set_client_verify(true)` *and* `set_authority(store)`, with the
  hostname traced through `irc_connection.pony:455` → `lori/tcp_connection.pony:149`
  → `_MakeTLS.client(ssl_ctx, host)`, which is what turns on `SSL_set1_host`. A
  cert for the wrong name is rejected.
- **The per-sender to-device queue** is keyed by `session.user_id` from a resolved
  token, never anything a body chose. A flood evicts only the flooder's own queue,
  and neither `sendToDevice` nor `keys/claim` enumerates accounts.
- **Request logging** prints `request.uri.path` and never `request.uri.query`, so
  a Matrix-style `?access_token=` cannot reach the log.

**Correctness.**
- `Pending[A]`'s semantics: `push` drops exactly the excess, `paired`/`since`
  filter on `at <= given`, `acknowledged` removes exactly the counted prefix, and
  the `else` branches return the queue unchanged rather than losing it.
- `Device._to_device_since`'s k-way merge over per-sender slices, including the
  `best is None` seed and the genuinely-unreachable `else`.
- `ReadStreamPosition` collapses every failure mode to the same documented
  answer, and checks the epoch before parsing the index.
- `ValidUtf8`/`_WellFormed`: `0xc0`/`0xc1` and continuation first bytes fall to
  width 0; overlong three-byte, surrogate and above-U+10FFFF forms are all
  rejected; the single-advance loop cannot spin. The `continue`-in-`while` bug the
  comment records is genuinely fixed.
- `GhostLocalpart` is injective as claimed *within the ghost space* — `=` escapes
  to `=3d` so decoding is unambiguous, and the plain set is a subset of
  `Localpart.check`'s. (M-10 is about the boundary with the real space, not this.)
- `SplitForIrc`/`_Sized`/`_Break` always make progress; `_Break` can never return
  0 for the production budget, each piece is at most `budget`, and `_TooLongToRelay`
  measures the same thing `relay` sends.
- `SessionRegistry._remove_device`'s `break` after `Array.delete` is load-bearing,
  done, and documented.
- `Credential.verify` derives at the fixed key length and never at `hash.size()`.
- The fan-in counters in `_QueryKeysHandler`/`_ClaimKeysHandler`/
  `_PublicRoomsHandler` cannot underflow — each decrement is matched one-for-one
  and duplicate user ids cannot occur.
- `Homeserver._colon` correctly refuses to read an IPv6 literal's colons as a
  port separator.
- `Room._admit`'s ordering, and the docstring recording why the reverse was wrong.
- `JSONPrinter` is iterative, so a deep document cannot overflow the scheduler
  stack on the way out.

**Design and principles.**
- **Errors are data**, throughout: every fallible operation returns a union of
  concrete types with a text renderer, and `EventTooDeep`'s docstring argues
  explicitly for a distinct error rather than reusing `MalformedEvent`.
- **Default to immutability**: 73 of 77 `class` declarations are `class val`, and
  each of the three exceptions is justified and single-owner.
- **No speculative abstraction**: reference counts taken for all 299 declared
  types; none is declared and never used, and there is no plugin surface, no
  config-driven dispatch, and no abstract base with one implementor.
  `LoginFlows`' docstring is the model case — it hard-codes one flow and says in
  terms when that must change.
- **Don't patch around architectural problems**: `SECURITY.md`'s reasoning about
  the `"limited"` gap ("answering a client with a pointer to nothing is the
  failure mode this codebase has already been bitten by") is the principle
  written down.
- **Actor constructors cannot fail** — the supply-chain pattern is applied
  correctly at `SessionRegistry._actors_for` and `RoomDirectory.create_room`, both
  with explicit fail-closed `else` arms.
- `Any` appears only as a generic constraint; zero `fun tag`; no interface
  declares a default body; `\nodoc\` is applied to all 256 `is UnitTest` classes
  and omitted from the 74 private helpers.
- **The receiver protocol earns its size** — 28 interfaces / 52 behaviours for 35
  endpoints, each naming one ask and its outcomes, each documented, each checked
  by the compiler through the `is` list. A handler that misspells or omits a
  behaviour does not compile. The Promise alternative was considered and correctly
  rejected.
- **`_SyncHandler`** is the best-designed actor in the repository — `_disposed`
  guards the one ordering that matters, `_cancel` uses a destructive read so
  double-cancel is safe, and its `_respond` cancels first.
- **`Config`/`Configure`/`StartupError`** is a clean boundary, with the union
  return matched `\exhaustive\` at the call site.
- **Error bodies are Matrix-shaped everywhere**, and the reasoning about what a
  client can *act on* (`alias_taken` versus `room_refused`, `EventTooDeep` versus
  `MalformedEvent`) is unusually careful.
- **The large public surface is a stated, justified cost** — checked against the
  README's own justification, and it does not exceed it apart from L-6.

**Performance.**
- **The fan-out path really does avoid the shared actors.** Nothing on the
  per-message path touches `RoomDirectory`, `LinkDirectory` or `SessionRegistry`.
  This is the load-bearing claim in `docs/architecture.md` and it holds.
- Events are shared, not copied — `class val` throughout, one object per event
  held by reference by every member and device.
- Content is stored as printed text rather than `JSONObject`, uniformly, with the
  measured reasoning recorded.
- `RoomState` reads are keyed, not scanned, and `MembersOnly` is its own reading
  rather than a filter over `AllState`.
- Unauthenticated work is genuinely deferred: every handler captures its raw query
  string and defers decoding and parsing until `token_resolved`, and
  `_SyncHandler` refuses to arm a timer before the token resolves.
- The login PBKDF2 cost, and the held-sync memory cost, are both measured, stated,
  and accepted explicitly.
- `ToDeviceLimit()` is per sender, not per device, and both factors of the merge
  are bounded.
- `_ServeJSON` and `_Redirect` render their bodies and headers once at startup.

**Tests.**
- **The harness cannot pass by never asserting** — `_TestClient` calls the check
  lambda from both `_on_closed` and `_on_connection_failure`, so an unanswered
  request fails rather than passes (except the two negative-only tests in L-26).
- **The async ordering discipline is unusually careful and correct** —
  `_StepRunner` sequences explicitly, `_LinkLifecycle.print`'s docstring records a
  real race the counter fixes, `_LinkUnderTest` feeds a sentinel last rather than
  sleeping, and `_RevokeOne`/`_PairDevices` use `expect_action`/`complete_action`
  because PonyTest records on first `complete`.
- **Mutation-derived tests are real** — two tests say in their docstrings that the
  guard they cover was found deletable-with-the-suite-green, and both are
  correctly constructed to catch it now.
- **`_TestEveryBodyLimitCanFire`** is a cross-cutting invariant over six constants
  that caught two limits set above the transport cap. It is the best test in the
  suite and it is the model for what the numeric claims in `SECURITY.md` need.
- **The property tests are built to the skill** — `_SplittableText` uses weighted
  `Generators.frequency` with boundary buckets, and its three properties are
  complementary rather than redundant.
- **The alias namespace is tested in both directions.**
- **Test names are accurate** — no test was found whose name or docstring
  misdescribes what it asserts, and several are honest about what they cannot
  cover.
- **Test isolation** — shared fixtures written once with the reason given,
  per-test fixture paths where they matter, `_Hex` fixed rather than random
  explicitly because concurrent tests share files. No order dependencies found.

**Toolchain and hygiene.**
- Every action and container image is pinned to a specific version rather than a
  floating tag, except the ponylang builder images' `:release` tags, which are the
  ponylang convention. `lock.json` covers the full transitive closure.
- No `TODO`, `FIXME`, `XXX`, `HACK` or `WIP` anywhere in either package or in the
  shipped prose. No commented-out code. No tabs in any `.pony` file, no trailing
  whitespace. Three lines over 80 columns in 21,000.
- The leaked-artifact sweep over every tracked text file — finding IDs,
  remediation slugs, round markers, back-references to review material, internal
  codenames, agent or session references — returns nothing outside the excluded
  `reviews/` directory.
- **Docstring openers are clean**: across ~483 docstrings, no "Names the",
  "Represents the", "Holds the", "Stores the" or "This method" opener. That is
  unusual and worth saying.
- `README.md` carries none of the four things a Pony README must not have, and its
  endpoint count and credentials example both check out against the source.
- **Every numeric bound in `SECURITY.md` except the two in H-2 is correct**,
  including the at-least/exactly distinctions in the credential-validation claims.

---

## Uncertainties

Things needing the owner's input — genuinely hard questions no reviewer could
resolve, and design decisions that are the owner's to make rather than defects.

**Questions no reviewer could settle:**

1. **The per-request memory figures in C-1 and H-1 inside marilwyd.** Both sets
   were measured in isolated harnesses holding the parsed values. In the server
   the handler actor's heap holds them for the duration of `token_resolved` and is
   reclaimed when the actor dies. The peak under N concurrent requests should be
   close to N × the per-body figure, but nobody drove the running binary. The
   *mechanism* is verified twice; the *magnitude in situ* is not.

2. **Whether M-7's client half holds.** Whether matrix-js-sdk on a soft-logout
   re-login really retains the room and crypto stores is inference from protocol
   intent, not observation. The falsity of the `soft_logout` assertion does not
   depend on it; the severity does. The fifteen-minute probe is written out in the
   finding, and it settles the question.

3. **M-5's reachability.** Whether Element ever has two `/sync` requests
   outstanding against one device id. `SECURITY.md`'s pipelining measurement says
   the common path does not, but nobody drove a client. A hostile or buggy client
   trivially can.

4. **M-6's ORCA consequence.** The refcap reasoning is straightforward, but nobody
   measured a `UserLink` surviving its death, and no reviewer could exhaust every
   path that might clear `RoomState._members` for a ghost.

5. **How quickly a real device reaches `PendingLimit()`** (H-6). It is 1000
   events, so it needs sustained traffic in a room the account is in; on a busy
   bridged channel that is hours, on a quiet personal server it may never happen.
   H-6's severity is about the cliff; nobody could establish the frequency from
   the code.

6. **Whether the per-IP IRC connection limit bites** (Wildcard 9, rated Medium;
   **placed here rather than in the findings, and the reason is stated**: its
   severity depends entirely on a third-party network's policy no reviewer could
   test, the configured network appears to be the owner's own where it does not
   apply, and the remedy Wildcard proposes is a paragraph of prose rather than
   code — so it is a question for the owner before it is a defect. If the answer
   is "yes, a public network", it becomes a Medium documentation finding
   immediately.) The bouncer design opens one TCP+TLS socket per user per
   channel, all from one IP, with no cap, no pacing and no per-network accounting
   anywhere in `link_directory.pony` or `connect.pony`. Most public IRC networks
   limit connections per host — commonly three to five without an exemption — and
   answer the excess with a reject or a temporary host ban. Nothing sends `QUIT`
   on shutdown (there is no signal handling in `main.pony`), so a restart drops
   every bridged socket abruptly and every user rejoining afterwards opens a
   fresh connection within seconds of the others — the reconnect burst from one
   IP that networks throttle hardest. `SECURITY.md`'s bridge sections reason
   carefully about K-lines from message *rate* and never mention connection
   *count*, which is a hole in the shape of its own strongest section. For a
   personal server with one to three accounts this is a non-issue today; it is
   the first thing that breaks when a second person is given an account and the
   channel is on a public network, which is precisely the deployment that section
   is written for.

7. **Whether `hobby#1` names a real upstream issue.** Nothing in the repository
   links it. The marker earns its keep as a grep anchor either way; if it is meant
   as an issue reference, a link would make it checkable.

8. **Whether the measured figures in the docstrings were accurate when taken.**
   None was re-verified. The findings about them concern framing and version
   stamps only.

**Design decisions that are yours:**

9. **Whether M-2's three unbounded stores are in scope**, given `SECURITY.md`'s
   standing position that authenticated costs are left to a rate limiter in front.
   The reviewers' reading, which I share, is that they are — because the document
   affirmatively claims two of the three are bounded. But if the cost is
   acceptable, the document has to change either way.

10. **Whether `RoomId` should propagate through the receiver protocol** (M-21).
    The map keys need `Equatable`/`Hashable`, which is the real cost. This is not
    a small change and the alternative — amending `docs/architecture.md` to stop
    implying the validated form propagates — is legitimate.

11. **Whether `Pending` should stay a persistent structure** (H-6). It is owned by
    one actor and never shared, so it does not need one; but if the persistent
    shape is wanted for its own sake, dropping a block rather than one entry
    lowers the constant without changing the asymptotics.

12. **The Mixin remedy in M-8** is a design proposal that was not compiled. Pony
    traits can supply default behaviour bodies, but nobody verified that such a
    trait can be intersected with `hobby.HandlerReceiver` in an actor's `is` list
    alongside the receiver interfaces without a conformance problem. The
    duplication counts are verified; the fix is not.

13. **Whether the two prose `TODO`s should be issues** (L-22). Both are honest and
    useful as prose; they are the two places a reader is told work is pending with
    no way to check whether it has happened.

14. **Whether `SECURITY.md`'s fix-history narration is deliberate** (M-19). A
    security document listing past vulnerabilities is normal and useful. The
    finding is that these sentences sit inside the paragraphs stating current
    bounds rather than under their own heading, so the fix proposed is separation
    rather than deletion.

15. **Whether "a single-`apply` primitive documents `apply` on the type" is an
    accepted project convention** (L-25). With no `AGENTS.md` or `CLAUDE.md` in
    the repository, no reviewer could settle it, so the finding is scoped to the
    in-type inconsistencies, which are indefensible under either reading. Worth
    settling once and writing down — the same absence made several other
    convention questions unanswerable.

16. **The LICENSE question** (L-27). "Not released" is a coherent position; six
    empty `corral.json` strings is not a way of stating it.

**Coverage gaps to be aware of.** Nobody read `hobby`, `stallion`, `lori`, `irc`
or `yaml` in full — claims resting on them (that `respond_with_headers` is
idempotent, that `ctx.params` arrives percent-encoded, that `JSONObject` keys are
unique) were taken from the codebase's own comments except where a reviewer names
the dependency file it read. Nobody assessed whether the test suite's own helpers
constitute a good API for the next test author. Nobody ran `pony-lint` or read its
rule set, so L-29's claim that it has no unused-import check is inferred from the
baseline being green.
