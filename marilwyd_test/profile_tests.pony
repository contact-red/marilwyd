use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestADisplayNameIsTheLocalpart is UnitTest
  """
  marilwyd stores no profile, so the only honest answer is the part of the
  id a person calls themselves by.
  """
  fun name(): String => "profile/a display name is the local part"

  fun apply(h: TestHelper) =>
    h.assert_eq[String](
      "alice",
      try
        DisplayName("@alice:example.test", "example.test") as String
      else
        ""
      end)

class \nodoc\ iso _TestABridgedNameIsLeftAsItIs is UnitTest
  """
  A bridged participant's id is answered as it stands rather than
  half-decoded.

  Undoing the escaping alone gives `irc_testnet_bob{m}` — the far-side name
  with the mapping's prefix still on it, which is nobody's name. The name a
  person reads comes from the membership event the bridge writes; this
  endpoint answers before a client has one, and the id is honest where a
  guess is not.
  """
  fun name(): String => "profile/a bridged id is answered as it stands"

  fun apply(h: TestHelper) =>
    let shown =
      try
        DisplayName(
          "@irc_testnet_bob=7bm=7d:example.test", "example.test") as String
      else
        ""
      end
    h.assert_eq[String]("irc_testnet_bob=7bm=7d", shown)

class \nodoc\ iso _TestAForeignUserHasNoProfile is UnitTest
  """
  Nothing federates, so an id this server could not have issued names
  somebody there is nowhere to ask about.
  """
  fun name(): String => "profile/an id from another server has no profile"

  fun apply(h: TestHelper) =>
    for bad in
      [ "@alice:elsewhere.test"; "alice:example.test"; "@:example.test"
        "@alice" ].values()
    do
      match DisplayName(bad, "example.test")
      | let shown: String => h.fail(bad + " answered with " + shown)
      end
    end

class \nodoc\ iso _TestAProfileRendersOnlyAName is UnitTest
  """
  No `avatar_url`. An absent field and an empty one are different to a
  client — the second is a picture it will try to fetch — and marilwyd has
  no media repository to fetch from.
  """
  fun name(): String => "profile/a profile carries a name and nothing else"

  fun apply(h: TestHelper) =>
    let rendered = ProfileFor("alice")
    h.assert_eq[String]("{\"displayname\":\"alice\"}", rendered)
    h.assert_false(rendered.contains("avatar"), rendered)

class \nodoc\ iso _TestProfileWithoutATokenIsRefused is UnitTest
  """
  Authenticated, though the specification permits otherwise: marilwyd
  federates with nothing, so the only callers are its own clients, and an
  unauthenticated endpoint that names accounts answers whether an account
  exists.
  """
  fun name(): String => "profile/asking without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send("GET", "/_matrix/client/v3/profile/%40alice%3Aexample.test", ""),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestAProfileIsAnswered is UnitTest
  fun name(): String => "profile/a local user has a profile"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Send(
          "GET",
          "/_matrix/client/v3/profile/%40" + _TestUser.localpart()
            + "%3Aexample.test",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(
          r.contains("\"displayname\":\"" + _TestUser.localpart() + "\""), r)
      } val)

class \nodoc\ iso _TestMembersWithoutATokenIsRefused is UnitTest
  fun name(): String => "members/asking without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send(
        "GET",
        "/_matrix/client/v3/rooms/%21a%3Aexample.test/members",
        ""),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestMembersListsTheRoom is UnitTest
  """
  What Element asks for the moment it renders a room, and asked twice in
  the log that prompted this.
  """
  fun name(): String => "members/a room lists who is in it"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        let room =
          match _RoomFrom(created)
          | let id: String => _Encoded(id)
          else
            "!missing"
          end
        _Send(
          "GET",
          "/_matrix/client/v3/rooms/" + room + "/members",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        // `chunk`, which is this endpoint's own spelling — a client reads
        // it through different code than `/state` and neither accepts the
        // other's field.
        h.assert_true(r.contains("\"chunk\":["), r)
        h.assert_true(r.contains("m.room.member"), r)
        h.assert_true(r.contains("@" + _TestUser.localpart() + ":"), r)
        // Membership only: the room's name is state, and not a member.
        h.assert_false(r.contains("m.room.name"), r)
        h.assert_false(r.contains("m.room.create"), r)
      } val)

class \nodoc\ iso _TestMembersOfARoomThatDoesNotExist is UnitTest
  fun name(): String => "members/an unknown room is M_NOT_FOUND"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Send(
          "GET",
          "/_matrix/client/v3/rooms/%21nope%3Aexample.test/members",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_NOT_FOUND")
      } val)

class \nodoc\ iso _TestMembersOfARoomYouAreNotIn is UnitTest
  """
  A room id is the whole of the access control, so anyone holding one may
  join and then read this — but reading it without joining would let
  somebody enumerate a room's membership from an id alone.

  Driven at the room rather than over HTTP, because the account that
  created the room is the only one a single-token test can be, and it is
  necessarily a member. An earlier version asked about a room that did not
  exist, which is answered by the lookup before the membership check is
  ever reached — so it passed with the check removed.
  """
  fun name(): String => "members/a room you are not in refuses"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      Room(_AnyRoomId()?)
        .> created_by(
          "@alice:example.test",
          User("@alice:example.test"),
          CreateRoomRequest(None, None, false),
          _IgnoreCreation)
        .> members("@bob:example.test", _ExpectMembersRefused(h))
    else
      _NoRandom(h)
    end

actor \nodoc\ _ExpectMembersRefused is StateReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be state_listed(events: Array[RoomEvent] val) =>
    _h.fail("a stranger was told who is in the room")
    _h.complete(false)

  be state_refused(why: NotInRoom) =>
    _h.complete(true)
