use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestCreateRoomWithoutATokenIsRefused is UnitTest
  fun name(): String => "rooms/creating one without a token is refused"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/createRoom", "{}"),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 401 Unauthorized\r\n"), r)
        _AssertErrcode(h, r, "M_MISSING_TOKEN")
      } val)

class \nodoc\ iso _TestCreateRoomAnswersARoomId is UnitTest
  fun name(): String => "rooms/creating one answers a room id"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"pony\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"room_id\":\"!"), r)
        h.assert_true(r.contains(":example.test"), r)
      } val)

class \nodoc\ iso _TestSendingToARoomThatDoesNotExist is UnitTest
  """
  A room id names nothing after a restart, since rooms do not survive one.
  A client holding an old id needs to be told that rather than guessing.
  """
  fun name(): String => "rooms/sending to an unknown room is M_NOT_FOUND"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Send(
          "PUT",
          "/_matrix/client/v3/rooms/%21nope%3Aexample.test"
            + "/send/m.room.message/1",
          "{\"body\":\"hello\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 404 Not Found\r\n"), r)
        _AssertErrcode(h, r, "M_NOT_FOUND")
      } val)

class \nodoc\ iso _TestCreateThenSend is UnitTest
  """
  The whole path over real sockets: make a room, then put a message in it.

  The room id is percent-encoded on the way back in, because `!` and `:`
  are what a room id is made of and every client encodes them.
  """
  fun name(): String => "rooms/a created room accepts a message"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{}",
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
          "PUT",
          "/_matrix/client/v3/rooms/" + room + "/send/m.room.message/1",
          "{\"body\":\"over the wire\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(r.contains("\"event_id\":\"$"), r)
      } val)

class \nodoc\ iso _TestCreateThenReadState is UnitTest
  """
  A room's state is the only thing it can answer about its past, and a
  freshly made one already has three facts in it.
  """
  fun name(): String => "rooms/a created room reports its state"

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
        _Get(
          "/_matrix/client/v3/rooms/" + room + "/state",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        // All three, because a create that wrote only one of them would
        // pass any single-type check.
        h.assert_true(r.contains("m.room.create"), r)
        h.assert_true(r.contains("m.room.member"), r)
        h.assert_true(r.contains("m.room.name"), r)
        h.assert_true(r.contains("pony"), r)
      } val)

class \nodoc\ iso _TestAMalformedRoomIdIsRefused is UnitTest
  fun name(): String => "rooms/an undecodable room id is M_INVALID_PARAM"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Get(
          "/_matrix/client/v3/rooms/%zz/state",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_INVALID_PARAM")
      } val)

class \nodoc\ iso _TestEventContentMustBeAnObject is UnitTest
  fun name(): String => "rooms/event content that is not an object is refused"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{}",
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
          "PUT",
          "/_matrix/client/v3/rooms/" + room + "/send/m.room.message/1",
          "[1,2,3]",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_BAD_JSON")
      } val)

primitive _Encoded
  """
  Percent-encode a room id the way a client does.
  """
  fun apply(id: String): String =>
    let out =
      recover val
        let s' = String(id.size() * 3)
        for c in id.values() do
          if c == '!' then
            s'.append("%21")
          elseif c == ':' then
            s'.append("%3A")
          else
            s'.push(c)
          end
        end
        s'
      end
    out
