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
          "/_matrix/client/v3/rooms/%21nope%3Aexample.test" +
            "/send/m.room.message/1",
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

class \nodoc\ iso _TestAnOversizedCreateIsRefused is UnitTest
  """
  `createRoom` was the one body-reading endpoint with no bound at all — it
  parsed up to the transport cap while every other path had a size limit
  and, for a login, a depth one too.
  """
  fun name(): String => "rooms/an oversized create request is refused"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        let padding =
          recover val
            String(MaxCreateBody() + 64) .> append(
              "a" * (MaxCreateBody() + 32))
          end
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"" + padding + "\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_TOO_LARGE")
      } val)

class \nodoc\ iso _TestADeeplyNestedCreateIsRefused is UnitTest
  """
  The shape half of the bound. A body can sit under the size limit and
  still cost a parser frame per level, which is the amplification the
  login limits were added to close and which this path never had.
  """
  fun name(): String => "rooms/a deeply nested create request is refused"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          _Nested(MaxCreateDepth() + 4),
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_BAD_JSON")
      } val)

class \nodoc\ iso _TestADeeplyNestedEventIsRefused is UnitTest
  """
  `MaxEventDepth` was declared, documented with the reason a shape bound
  exists at all, and then applied to nothing. Only the byte half of the
  bound was real until this test.
  """
  fun name(): String => "rooms/a deeply nested event is refused"

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
          "PUT",
          "/_matrix/client/v3/rooms/" + room + "/send/m.room.message/1",
          _Nested(MaxEventDepth() + 4),
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_BAD_JSON")
        h.assert_true(r.contains("nested more deeply"), r)
      } val)

class \nodoc\ iso _TestAClosedRoomRefusesAStranger is UnitTest
  """
  A room that was never offered to anyone is entered by invitation only.

  A room id used to be the whole of the access control: anyone who
  learned one could enter, and that reasoning was written into the type
  and into `SECURITY.md`. It is now the first half of it.
  """
  fun name(): String => "rooms/an uninvited stranger cannot join"

  fun apply(h: TestHelper) =>
    _ServeSteps(
      h,
      recover val
        [ as {(String, String, Array[String] val): String} val:
          // Made by the first account, unpublished and unaliased, so
          // invite-only.
          {(mine, theirs, before) =>
            _Post(
              "/_matrix/client/v3/createRoom",
              "{}",
              "Authorization: Bearer " + mine + "\r\n")
          }
          // The second account, holding the id and no invitation.
          {(mine, theirs, before) =>
            _Post(
              "/_matrix/client/v3/join/" + _Escaped(_IdIn(before, 0)),
              "{}",
              "Authorization: Bearer " + theirs + "\r\n")
          } ]
      end,
      {(answers) =>
        try
          h.assert_false(
            answers(1)?.contains("HTTP/1.1 200 OK\r\n"),
            "an uninvited account joined a closed room: " + answers(1)?)
          _AssertErrcode(h, answers(1)?, "M_FORBIDDEN")
        else
          h.fail("the steps did not all answer")
        end
      } val)

class \nodoc\ iso _TestAnInvitationLetsThemIn is UnitTest
  """
  Make a closed room, offer it, and accept — somebody entering a room they
  could not have entered a moment earlier.

  The half that makes the refusal above mean something. A gate that
  refuses everyone is not a gate, it is a wall.
  """
  fun name(): String => "rooms/an invitation lets somebody in"

  fun apply(h: TestHelper) =>
    _ServeSteps(
      h,
      recover val
        [ as {(String, String, Array[String] val): String} val:
          {(mine, theirs, before) =>
            _Post(
              "/_matrix/client/v3/createRoom",
              "{}",
              "Authorization: Bearer " + mine + "\r\n")
          }
          {(mine, theirs, before) =>
            _Post(
              "/_matrix/client/v3/rooms/" + _Escaped(_IdIn(before, 0)) +
                "/invite",
              "{\"user_id\":\"@" + _OtherUser.localpart() +
                ":example.test\"}",
              "Authorization: Bearer " + mine + "\r\n")
          }
          {(mine, theirs, before) =>
            _Post(
              "/_matrix/client/v3/join/" + _Escaped(_IdIn(before, 0)),
              "{}",
              "Authorization: Bearer " + theirs + "\r\n")
          } ]
      end,
      {(answers) =>
        try
          h.assert_true(
            answers(1)?.contains("HTTP/1.1 200 OK\r\n"),
            "a member could not invite: " + answers(1)?)
          h.assert_true(
            answers(2)?.contains("HTTP/1.1 200 OK\r\n"),
            "an invited account could not join: " + answers(2)?)
        else
          h.fail("the steps did not all answer")
        end
      } val)

primitive \nodoc\ _IdIn
  """
  The room id from one of the answers so far.
  """
  fun apply(answers: Array[String] val, at: USize): String =>
    try
      match _RoomFrom(answers(at)?)
      | let id: String => id
      else
        ""
      end
    else
      ""
    end

primitive \nodoc\ _Escaped
  """
  A room id as it goes in a path.
  """
  fun apply(id: String): String =>
    recover val
      let out = String(id.size() * 3)
      for byte in id.values() do
        match byte
        | '!' => out.append("%21")
        | ':' => out.append("%3A")
        | '$' => out.append("%24")
        else
          out.push(byte)
        end
      end
      out
    end

class \nodoc\ iso _TestARoomAskedToBeEncryptedIsEncrypted is UnitTest
  """
  A client asking for an encrypted room gets one that says it is.

  marilwyd does no encryption — the clients do, among themselves — so
  honouring the request means writing the state event they read to decide
  whether to. Answering a client that asked for a room its server cannot
  read with an ordinary room, and saying nothing about it, was the oldest
  untruth in `createRoom`.
  """
  fun name(): String => "rooms/a room asked to be encrypted says so"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"quiet\",\"initial_state\":[{" +
            "\"type\":\"m.room.encryption\",\"state_key\":\"\"," +
            "\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}}]}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first) =>
        _Get(
          "/_matrix/client/v3/rooms/" + _Escaped(_IdIn([first], 0)) +
            "/state",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_true(
          r.contains("m.room.encryption"),
          "a room asked to be encrypted did not say it was: " + r)
        h.assert_true(
          r.contains("m.megolm.v1.aes-sha2"),
          "the algorithm the client asked for was not written: " + r)
      } val)

class \nodoc\ iso _TestAnOrdinaryRoomIsNotEncrypted is UnitTest
  """
  And a room that asked for nothing does not claim to be encrypted, which
  is the half that makes the other one mean something.
  """
  fun name(): String => "rooms/an ordinary room is not encrypted"

  fun apply(h: TestHelper) =>
    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"loud\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first) =>
        _Get(
          "/_matrix/client/v3/rooms/" + _Escaped(_IdIn([first], 0)) +
            "/state",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 200 OK\r\n"), r)
        h.assert_false(
          r.contains("m.room.encryption"),
          "a room nobody asked to encrypt claimed to be: " + r)
      } val)

class \nodoc\ iso _TestAnOrdinaryRoomTakesALongMessage is UnitTest
  """
  A room with no bridge has no line limit.

  The limit exists because a paced IRC connection carries a paragraph over
  minutes and then stops carrying it. A room that goes nowhere has no such
  cost, and applying the bound there would refuse messages for a reason
  that does not apply to them — so the check asks whether the room is
  carried before it asks how long the message is.
  """
  fun name(): String => "rooms/a room with no bridge takes a long message"

  fun apply(h: TestHelper) =>
    let many =
      recover val
        let text = String(512)
        var i: USize = 0
        while i < (MaxIrcLines() * 4) do
          text.append("line\\n")
          i = i + 1
        end
        text
      end

    _ServeAuthedChain(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/createRoom",
          "{\"name\":\"chatty\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(token, login, first)(many) =>
        _Send(
          "PUT",
          "/_matrix/client/v3/rooms/" + _Escaped(_IdIn([first], 0)) +
            "/send/m.room.message/txn1",
          "{\"msgtype\":\"m.text\",\"body\":\"" + many + "\"}",
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r) =>
        h.assert_true(
          r.contains("HTTP/1.1 200 OK\r\n"),
          "a room with no bridge refused a long message: " + r)
      } val)
