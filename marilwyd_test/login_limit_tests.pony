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
