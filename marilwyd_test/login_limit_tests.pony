use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestLoginBodyWithinLimitsIsAccepted is UnitTest
  """
  A real login body, so the limits cannot pass by refusing everything.
  """
  fun name(): String => "login/a normal body is within the limits"

  fun apply(h: TestHelper) =>
    match CheckLoginShape(_Body(_PasswordLogin(_TestUser.password())))
    | None => None
    else
      h.fail("refused a login body marilwyd itself builds")
    end

class \nodoc\ iso _TestLoginBodyTooLargeIsRefused is UnitTest
  fun name(): String => "login/an oversized body is refused"

  fun apply(h: TestHelper) =>
    let oversized =
      recover val
        let s = String(MaxLoginBody() + 64)
        s.append("{\"password\":\"")
        var i: USize = 0
        while i < (MaxLoginBody() + 32) do
          s.append("x")
          i = i + 1
        end
        s.append("\"}")
        s
      end
    h.assert_true(oversized.size() > MaxLoginBody())
    match CheckLoginShape(_Body(oversized))
    | LoginBodyTooLarge => None
    else
      h.fail("accepted a body over the size limit")
    end

class \nodoc\ iso _TestLoginBodyTooDeepIsRefused is UnitTest
  """
  Nesting is refused on its own account, not as a side effect of length:
  this body is comfortably inside the size limit.
  """
  fun name(): String => "login/a deeply nested body is refused"

  fun apply(h: TestHelper) =>
    let deep = _Nested(MaxLoginDepth() + 4)
    h.assert_true(
      deep.size() < MaxLoginBody(),
      "the depth case must stay inside the size limit to mean anything")
    match CheckLoginShape(_Body(deep))
    | LoginBodyTooDeep => None
    else
      h.fail("accepted a body deeper than the limit")
    end

class \nodoc\ iso _TestLoginNestingAtTheLimitIsAccepted is UnitTest
  """
  The boundary from the other side, so the limit is a limit rather than a
  blanket refusal of nesting.
  """
  fun name(): String => "login/nesting at the limit is accepted"

  fun apply(h: TestHelper) =>
    match CheckLoginShape(_Body(_Nested(MaxLoginDepth())))
    | None => None
    else
      h.fail("refused a body exactly at the depth limit")
    end

class \nodoc\ iso _TestMalformedBodyIsLeftToTheParser is UnitTest
  """
  The shape check answers only about size and depth. What `M_NOT_JSON`
  means is decided in one place, and this is not it.
  """
  fun name(): String => "login/malformed JSON is not the shape check's answer"

  fun apply(h: TestHelper) =>
    match CheckLoginShape(_Body("{\"password\": "))
    | None => None
    else
      h.fail("the shape check answered for malformed JSON")
    end

class \nodoc\ iso _TestOversizedLoginIsRefusedOverHTTP is UnitTest
  fun name(): String => "login/an oversized body answers M_TOO_LARGE"

  fun apply(h: TestHelper) =>
    let oversized =
      recover val
        let s = String(MaxLoginBody() + 64)
        s.append("{\"type\":\"m.login.password\",\"password\":\"")
        var i: USize = 0
        while i < (MaxLoginBody() + 32) do
          s.append("x")
          i = i + 1
        end
        s.append("\"}")
        s
      end
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", oversized),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_TOO_LARGE")
      } val)

class \nodoc\ iso _TestDeeplyNestedLoginIsRefusedOverHTTP is UnitTest
  fun name(): String => "login/a nested body answers M_TOO_LARGE"

  fun apply(h: TestHelper) =>
    _Serve(
      h,
      _Post("/_matrix/client/v3/login", _Nested(MaxLoginDepth() + 4)),
      {(r) =>
        h.assert_true(r.contains("HTTP/1.1 400 Bad Request\r\n"), r)
        _AssertErrcode(h, r, "M_TOO_LARGE")
      } val)

primitive _Nested
  """
  A body nested `levels` deep. Legal JSON, and short: each level costs six
  bytes, which is what lets the depth case stay inside the size limit.
  """
  fun apply(levels: USize): String =>
    recover val
      let s = String((levels * 6) + 2)
      var i: USize = 0
      while i < levels do
        s.append("{\"a\":")
        i = i + 1
      end
      s.append("1")
      i = 0
      while i < levels do
        s.append("}")
        i = i + 1
      end
      s
    end

primitive _Body
  """
  A request body as the handlers receive one.
  """
  fun apply(text: String): Array[U8] val =>
    text.array()

class \nodoc\ iso _TestEveryBodyLimitCanFire is UnitTest
  """
  Every per-endpoint body limit is under what the transport will accept.

  A limit above `MaxRequestBody()` is not a limit: stallion refuses the
  body before routing, as the bodiless `413` with no `errcode` that a
  typed refusal exists to give instead — so the endpoint's own check never
  runs and its refusal is dead code.

  `MaxKeysBody` and `MaxToDeviceBody` were both above it, at two and four
  times the cap. Nothing said so, because nothing compared them: each was
  a reasonable number read on its own.
  """
  fun name(): String => "limits/every body limit is under the transport cap"

  fun apply(h: TestHelper) =>
    let limits: Array[(String, USize)] =
      [ ("MaxLoginBody", MaxLoginBody())
        ("MaxKeysBody", MaxKeysBody())
        ("MaxToDeviceBody", MaxToDeviceBody())
        ("MaxDeviceNamesBody", MaxDeviceNamesBody())
        ("MaxEventBody", MaxEventBody())
        ("MaxCreateBody", MaxCreateBody()) ]

    for (named, limit) in limits.values() do
      h.assert_true(
        limit <= MaxRequestBody(),
        named + " is " + limit.string() + ", above the transport cap of "
          + MaxRequestBody().string() + ", so it can never fire")
    end

class \nodoc\ iso _TestAnOversizedKeyUploadIsRefused is UnitTest
  """
  The size half of the keys bound, through the endpoint rather than the
  primitive, because the primitive is private and what matters is that the
  endpoint reaches it.
  """
  fun name(): String => "keys/an oversized upload is refused"

  fun apply(h: TestHelper) =>
    _ServeAuthed(
      h,
      {(token) =>
        _Post(
          "/_matrix/client/v3/keys/upload",
          _Padded(MaxKeysBody() + 512),
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_false(r.contains("HTTP/1.1 200 OK\r\n"), r)
        _AssertErrcode(h, r, "M_BAD_JSON")
      } val)

class \nodoc\ iso _TestADeeplyNestedKeyUploadIsRefused is UnitTest
  """
  And the shape half, which did not exist: the body here is a few hundred
  bytes, so nothing about its length refuses it.

  This is the bound that matters most of the three. A body's length is
  bounded by the transport whatever an endpoint does; its nesting is
  bounded by nothing, and it is the parser's recursion that costs.
  """
  fun name(): String => "keys/a deeply nested upload is refused"

  fun apply(h: TestHelper) =>
    let deep = _Nested(MaxBodyDepth() + 8)
    h.assert_true(
      deep.size() < MaxKeysBody(),
      "the depth case must stay inside the size limit to mean anything")
    _ServeAuthed(
      h,
      {(token)(deep) =>
        _Post(
          "/_matrix/client/v3/keys/upload",
          deep,
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_false(r.contains("HTTP/1.1 200 OK\r\n"), r)
        _AssertErrcode(h, r, "M_BAD_JSON")
      } val)

class \nodoc\ iso _TestADeeplyNestedDeviceDeleteIsRefused is UnitTest
  """
  `delete_devices` had neither bound — not size, not depth — which made it
  the cheapest unbounded parse behind a token in the server.
  """
  fun name(): String => "devices/a deeply nested delete is refused"

  fun apply(h: TestHelper) =>
    // A *valid* delete, with the nesting somewhere else in the body. A
    // body that was merely the wrong shape would be refused whatever the
    // depth rule said, and a test that cannot tell those apart proves
    // nothing — the first version of this one could not.
    let deep =
      recover val
        let s = String(256)
        s.append("{\"devices\":[\"AAA\"],\"padding\":")
        var i: USize = 0
        while i < (MaxBodyDepth() + 8) do
          s.append("{\"a\":")
          i = i + 1
        end
        s.append("1")
        i = 0
        while i < (MaxBodyDepth() + 8) do
          s.append("}")
          i = i + 1
        end
        s.append("}")
        s
      end
    _ServeAuthed(
      h,
      {(token)(deep) =>
        _Post(
          "/_matrix/client/v3/delete_devices",
          deep,
          "Authorization: Bearer " + token + "\r\n")
      } val,
      {(r, held) =>
        h.assert_false(
          r.contains("HTTP/1.1 200 OK\r\n"),
          "a delete nested past the bound was accepted: " + r)
      } val)

primitive _Padded
  """
  A JSON object of at least `bytes`, valid so that only its size refuses
  it.
  """
  fun apply(bytes: USize): String =>
    recover val
      let s = String(bytes + 32)
      s.append("{\"device_keys\":\"")
      while s.size() < bytes do
        s.append("x")
      end
      s.append("\"}")
      s
    end
