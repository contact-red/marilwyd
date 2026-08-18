use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestResolvingWithoutATokenIsRefused is UnitTest
  fun name(): String => "alias/resolving without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send(
        "GET",
        "/_matrix/client/v3/directory/room/%23a%3Aexample.test",
        ""),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestTheDirectoryWithoutATokenIsRefused is UnitTest
  fun name(): String => "alias/the public directory needs a token"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Send("GET", "/_matrix/client/v3/publicRooms", ""),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestAnAliasResolvesToItsRoom is UnitTest
  """
  The whole point of an alias: a name a person can be given turns into the
  room id everything else takes.
  """
  fun name(): String => "alias/an alias resolves to the room it named"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"Pony\",\"room_alias_name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        _Send(
          "GET",
          "/_matrix/client/v3/directory/room/%23pony%3Aexample.test",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"room_id\":\"!"), r)
        h.assert_true(r.contains("\"servers\":[\"example.test\"]"), r)
      } val)

class \nodoc\ iso _TestAnUnknownAliasIsNotFound is UnitTest
  fun name(): String => "alias/an alias nobody holds is M_NOT_FOUND"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Send(
          "GET",
          "/_matrix/client/v3/directory/room/%23nobody%3Aexample.test",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_NOT_FOUND")
      } val)

class \nodoc\ iso _TestAPublishedRoomIsListed is UnitTest
  """
  What "already registered" means: a room made public appears in the
  directory Element's Explore dialog reads, with the name and alias a
  person recognises it by.
  """
  fun name(): String => "alias/a published room appears in the directory"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"Pony\",\"room_alias_name\":\"pony\""
            + ",\"visibility\":\"public\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        _Send(
          "GET",
          "/_matrix/client/v3/publicRooms",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"name\":\"Pony\""), r)
        h.assert_true(
          r.contains("\"canonical_alias\":\"#pony:example.test\""), r)
        h.assert_true(r.contains("\"total_room_count_estimate\":1"), r)
      } val)

class \nodoc\ iso _TestAPrivateRoomIsNotListed is UnitTest
  """
  A room made with neither an alias nor `visibility: public` stays out of
  the directory. A room id is the entire access control, so listing one
  would be the same as handing its id to everyone.
  """
  fun name(): String => "alias/a private room stays out of the directory"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"Secret\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        _Send(
          "GET",
          "/_matrix/client/v3/publicRooms",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_false(r.contains("Secret"), r)
        h.assert_true(r.contains("\"total_room_count_estimate\":0"), r)
      } val)

class \nodoc\ iso _TestTheDirectoryAnswersAPost is UnitTest
  """
  Element searches with a `POST` and lists with a `GET`; matrix-js-sdk
  picks between them by whether a filter was given. Answering only one
  leaves the directory working until somebody types in it.
  """
  fun name(): String => "alias/the directory answers a search POST"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/publicRooms",
          "{\"limit\":20,\"filter\":{\"generic_search_term\":\"po\"}}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"chunk\":"), r)
      } val)

class \nodoc\ iso _TestJoiningByAliasWorks is UnitTest
  """
  The route has been called `roomIdOrAlias` since it was written, and until
  now only half of that was true.
  """
  fun name(): String => "alias/a room can be joined by its alias"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"room_alias_name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        _Post(
          "/_matrix/client/v3/join/%23pony%3Aexample.test",
          "{}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"room_id\":\"!"), r)
      } val)

class \nodoc\ iso _TestAnAliasIsTakenOnlyOnce is UnitTest
  fun name(): String => "alias/a second room cannot take a taken alias"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"room_alias_name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"room_alias_name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 409 Conflict\r\n"), r)
        _AssertErrcode(h, r, "M_ROOM_IN_USE")
      } val)

class \nodoc\ iso _TestABadAliasNameIsRefused is UnitTest
  fun name(): String => "alias/createRoom refuses an unusable alias name"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"room_alias_name\":\"Pony Room\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_INVALID_PARAM")
      } val)

class \nodoc\ iso _TestAnAliasedRoomSaysSoInItsState is UnitTest
  """
  The directory's map resolves an alias; this event is what makes the room
  itself say it has one, so a client renders `#pony:example.test` beside it
  rather than a room id.
  """
  fun name(): String => "alias/an aliased room carries m.room.canonical_alias"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"room_alias_name\":\"pony\"}",
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
          "/_matrix/client/v3/rooms/" + room + "/state",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("m.room.canonical_alias"), r)
        h.assert_true(r.contains("#pony:example.test"), r)
      } val)

class \nodoc\ iso _TestAnAliasPublishesWithoutBeingAsked is UnitTest
  """
  A room with an alias is listed even when nothing asked for it to be.

  A deliberate divergence from Matrix, where `visibility` alone decides
  listing. Here a room id is the entire access control and an alias is a
  short, guessable name that resolves to one — so an aliased room is
  reachable by anyone who guesses it whether or not it appears in the
  directory. Listing it does not widen the exposure; it stops hiding it.
  Leaving it unlisted would offer a privacy that does not exist.
  """
  fun name(): String => "alias/an alias publishes a room on its own"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        // No `visibility`, so Matrix would default this to unlisted.
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"Pony\",\"room_alias_name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, created) =>
        _Send(
          "GET",
          "/_matrix/client/v3/publicRooms",
          "",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"name\":\"Pony\""), r)
        h.assert_true(r.contains("\"total_room_count_estimate\":1"), r)
      } val)
