use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestIssuedTokenResolves is UnitTest
  """
  The round trip login exists to make possible: a token that comes out of
  `issue` resolves through `resolve` to the user it was minted for.

  Without this, five separate one-token changes leave the suite green while
  the feature is dead — dropping the session push, handing back the device id
  instead of the token, or making `resolve` always reject, which is what the
  two whoami failure tests already expect.
  """
  fun name(): String => "sessions/an issued token resolves to its user"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    let registry = SessionRegistry
    registry.issue("@alice:example.test", _CollectToken(h, registry))

class \nodoc\ iso _TestUnknownTokenDoesNotResolve is UnitTest
  """
  The same registry rejects a token it never minted — so the test above
  cannot pass by resolving everything.
  """
  fun name(): String => "sessions/a token the registry never minted is refused"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    let registry = SessionRegistry
    registry.resolve("not a token this registry issued", _ExpectRejected(h))

class \nodoc\ iso _TestDeviceIdIsNotTheAccessToken is UnitTest
  """
  Both are hex from the same CSPRNG, so a handler that returned the token in
  the device id field would look right in every response and hand a bearer
  secret to anything that logs a device id.
  """
  fun name(): String => "sessions/the device id is not the access token"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    let registry = SessionRegistry
    registry.issue("@alice:example.test", _CheckDeviceId(h, registry))

actor _CollectToken is TokenReceiver
  let _h: TestHelper
  let _registry: SessionRegistry tag

  new create(h: TestHelper, registry: SessionRegistry tag) =>
    _h = h
    _registry = registry

  be token_issued(token: AccessToken, device_id: String) =>
    _registry.resolve(token.reveal(), _ExpectResolved(_h))

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

actor _CheckDeviceId is TokenReceiver
  let _h: TestHelper
  let _registry: SessionRegistry tag

  new create(h: TestHelper, registry: SessionRegistry tag) =>
    _h = h
    _registry = registry

  be token_issued(token: AccessToken, device_id: String) =>
    _h.assert_false(device_id == token.reveal())
    _h.assert_true(device_id.size() > 0)
    // A device id must not be accepted as a token.
    _registry.resolve(device_id, _ExpectRejected(_h))

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

actor _ExpectResolved is UserReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be token_resolved(user_id: String) =>
    _h.assert_eq[String]("@alice:example.test", user_id)
    _h.complete(true)

  be token_rejected() =>
    _h.fail("a token the registry issued did not resolve")
    _h.complete(false)

actor _ExpectRejected is UserReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be token_resolved(user_id: String) =>
    _h.fail("resolved a token that was never issued: " + user_id)
    _h.complete(false)

  be token_rejected() =>
    _h.complete(true)
