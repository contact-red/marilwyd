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

  be token_issued(token: AccessToken, device: DeviceId) =>
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

  be token_issued(token: AccessToken, device: DeviceId) =>
    let device_id = device.string()
    _h.assert_false(device_id == token.reveal())
    _h.assert_true(device_id.size() > 0)
    // A device id must not be accepted as a token.
    _registry.resolve(consume device_id, _ExpectRejected(_h))

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

actor _ExpectResolved is UserReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be token_resolved(user_id: String, device: DeviceId) =>
    _h.assert_eq[String]("@alice:example.test", user_id)
    _h.assert_true(device.string().size() > 0, "resolved without a device")
    _h.complete(true)

  be token_rejected() =>
    _h.fail("a token the registry issued did not resolve")
    _h.complete(false)

actor _ExpectRejected is UserReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be token_resolved(user_id: String, device: DeviceId) =>
    _h.fail("resolved a token that was never issued: " + user_id)
    _h.complete(false)

  be token_rejected() =>
    _h.complete(true)

class \nodoc\ iso _TestTwoLoginsAreTwoDevices is UnitTest
  """
  The point of device ids: one account signed in from two clients is two
  sessions, each with its own token and its own device, and neither knows
  about the other.
  """
  fun name(): String => "sessions/two logins for one user are two devices"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    _TwoDevices(h)

class \nodoc\ iso _TestRevokeEndsOnlyThatSession is UnitTest
  """
  Logging one client out leaves the other signed in. Without the device
  distinction there would be nothing to log out but the account.

  The *second* session is the one revoked, so the removal happens at an
  index other than zero — a `_remove(0)` would pass otherwise.

  Both outcomes are registered actions. Two receiver actors report here,
  and `pony_test` reports a test the moment one of them completes it, so
  without this the surviving-session assertion could arrive after the
  result was already recorded.
  """
  fun name(): String => "sessions/revoking one session spares the other"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    h.expect_action("revoked token is refused")
    h.expect_action("surviving token still resolves")
    _RevokeOne(h)

class \nodoc\ iso _TestDeviceRevocationIsScopedToItsOwner is UnitTest
  """
  A device id is a public label, so the token deciding the deletion has to
  be the one that owns the device. Without the ownership check, ten hex
  characters would end another account's session.
  """
  fun name(): String => "sessions/one user cannot delete another's device"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    _CrossUser(h)

actor _TwoDevices is TokenReceiver
  """
  Collects two sessions for one user, then compares them.
  """
  let _h: TestHelper
  let _registry: SessionRegistry
  var _first: (DeviceId | None) = None
  var _first_token: (AccessToken | None) = None

  new create(h: TestHelper) =>
    _h = h
    _registry = SessionRegistry
    _registry.issue("@alice:example.test", this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    match (_first, _first_token)
    | (let earlier: DeviceId, let earlier_token: AccessToken) =>
      _h.assert_false(
        earlier.string() == device.string(),
        "both logins were given the same device id")
      _h.assert_false(
        earlier_token.reveal() == token.reveal(),
        "both logins were given the same token")
      _h.complete(true)
    else
      _first = device
      _first_token = token
      _registry.issue("@alice:example.test", this)
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

actor _RevokeOne is (TokenReceiver & RevocationReceiver)
  """
  Two sessions for one user; revoke the first by its own token; the second
  must survive.
  """
  let _h: TestHelper
  let _registry: SessionRegistry
  var _first: (AccessToken | None) = None
  var _second: (AccessToken | None) = None

  new create(h: TestHelper) =>
    _h = h
    _registry = SessionRegistry
    _registry.issue("@alice:example.test", this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    match _first
    | let earlier: AccessToken =>
      _second = token
      // The second session, so `_remove` runs at index 1.
      _registry.revoke(token.reveal(), this)
    else
      _first = token
      _registry.issue("@alice:example.test", this)
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

  be session_revoked() =>
    match (_first, _second)
    | (let kept: AccessToken, let gone: AccessToken) =>
      _registry.resolve(
        gone.reveal(), _ExpectGone(_h, "revoked token is refused"))
      _registry.resolve(
        kept.reveal(), _ExpectLive(_h, "surviving token still resolves"))
    else
      _h.fail("both sessions were not issued")
      _h.complete(false)
    end

  be revocation_rejected() =>
    _h.fail("revoking a token the registry issued was refused")
    _h.complete(false)

actor _CrossUser is (TokenReceiver & RevocationReceiver)
  """
  Alice and Bob each sign in; Alice tries to delete Bob's device.
  """
  let _h: TestHelper
  let _registry: SessionRegistry
  var _alice: (AccessToken | None) = None
  var _bob: (AccessToken | None) = None

  new create(h: TestHelper) =>
    _h = h
    _registry = SessionRegistry
    _registry.issue("@alice:example.test", this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    match _alice
    | let _: AccessToken =>
      _bob = token
      match _alice
      | let alice: AccessToken =>
        _registry.revoke_devices(
          alice.reveal(), recover val [device.string()] end, this)
      end
    else
      _alice = token
      _registry.issue("@bob:example.test", this)
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

  be session_revoked() =>
    // Answered as success — the endpoint does not disclose whether a device
    // it declined to touch exists. What must be true is that Bob is still
    // signed in.
    match _bob
    | let bob: AccessToken => _registry.resolve(bob.reveal(), _ExpectBob(_h))
    end

  be revocation_rejected() =>
    _h.fail("alice's own token was not recognised")
    _h.complete(false)

actor _ExpectBob is UserReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be token_resolved(user_id: String, device: DeviceId) =>
    _h.assert_eq[String]("@bob:example.test", user_id)
    _h.complete(true)

  be token_rejected() =>
    _h.fail("alice deleted bob's device")
    _h.complete(false)

actor _ExpectGone is UserReceiver
  """
  Asserts a token no longer resolves, as a named action so the result is
  counted even if a sibling receiver finishes first.
  """
  let _h: TestHelper
  let _action: String

  new create(h: TestHelper, action: String) =>
    _h = h
    _action = action

  be token_resolved(user_id: String, device: DeviceId) =>
    _h.fail_action(_action)

  be token_rejected() =>
    _h.complete_action(_action)

actor _ExpectLive is UserReceiver
  """
  Asserts a token still resolves. The counterpart of `_ExpectGone`.
  """
  let _h: TestHelper
  let _action: String

  new create(h: TestHelper, action: String) =>
    _h = h
    _action = action

  be token_resolved(user_id: String, device: DeviceId) =>
    _h.complete_action(_action)

  be token_rejected() =>
    _h.fail_action(_action)

class \nodoc\ iso _TestDeletingADeviceEndsThatSession is UnitTest
  """
  The capability the endpoint exists for, and the one nothing asserted:
  ending another of your own sessions by naming its device.

  The *second* device is named, so a `_remove(0)` fails here, and the
  deletion is driven by the *first* token, so a version matching on user
  alone would end the caller's own session and fail too.
  """
  fun name(): String => "devices/deleting a device ends that session"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    h.expect_action("deleted token is refused")
    h.expect_action("deleting token still resolves")
    _DeleteSecond(h)

actor _DeleteSecond is (TokenReceiver & RevocationReceiver)
  let _h: TestHelper
  let _registry: SessionRegistry
  var _first: (AccessToken | None) = None
  var _second: (AccessToken | None) = None

  new create(h: TestHelper) =>
    _h = h
    _registry = SessionRegistry
    _registry.issue("@alice:example.test", this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    match _first
    | let earlier: AccessToken =>
      _second = token
      _registry.revoke_devices(
        earlier.reveal(), recover val [device.string()] end, this)
    else
      _first = token
      _registry.issue("@alice:example.test", this)
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

  be session_revoked() =>
    match (_first, _second)
    | (let kept: AccessToken, let gone: AccessToken) =>
      _registry.resolve(
        gone.reveal(), _ExpectGone(_h, "deleted token is refused"))
      _registry.resolve(
        kept.reveal(), _ExpectLive(_h, "deleting token still resolves"))
    else
      _h.fail("both sessions were not issued")
      _h.complete(false)
    end

  be revocation_rejected() =>
    _h.fail("alice's own token was not recognised")
    _h.complete(false)

class \nodoc\ iso _TestDevicesListsOnlyYourOwn is UnitTest
  """
  Alice signs in twice and Bob once. Alice's listing must name her two
  devices and not Bob's — the set of an account's devices is not something
  another account may enumerate.
  """
  fun name(): String => "devices/a listing covers one account only"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    _ListDevices(h)

actor _ListDevices is (TokenReceiver & DeviceReceiver)
  let _h: TestHelper
  let _registry: SessionRegistry
  var _issued: USize = 0
  var _alice: (AccessToken | None) = None
  let _alice_devices: Array[String] = _alice_devices.create()

  new create(h: TestHelper) =>
    _h = h
    _registry = SessionRegistry
    _registry.issue("@alice:example.test", this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    _issued = _issued + 1
    if _issued <= 2 then
      _alice_devices.push(device.string())
      if _issued == 1 then
        _alice = token
      end
      _registry.issue(
        if _issued == 1 then "@alice:example.test" else "@bob:example.test"
        end,
        this)
    else
      match _alice
      | let alice: AccessToken => _registry.devices(alice.reveal(), this)
      end
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

  be devices_listed(found: Array[DeviceId] val) =>
    _h.assert_eq[USize](2, found.size(), "alice should have two devices")
    for device in found.values() do
      _h.assert_true(
        _alice_devices.contains(device.string(), {(a, b) => a == b }),
        "listed a device that is not alice's")
    end
    _h.complete(true)

  be devices_refused() =>
    _h.fail("alice's own token was not recognised")
    _h.complete(false)

class \nodoc\ iso _TestATokenResolvesToItsOwnDevice is UnitTest
  """
  Two sessions for one user, and each token must come back with the device
  it was issued alongside.

  Without this, a `resolve` that answered every token with the first
  session's device would be invisible: the user id would be right, every
  status code would be right, and `whoami` would report a device that
  exists — just not the caller's.
  """
  fun name(): String => "sessions/a token resolves to its own device"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    h.expect_action("first token keeps its device")
    h.expect_action("second token keeps its device")
    _PairDevices(h)

actor _PairDevices is TokenReceiver
  let _h: TestHelper
  let _registry: SessionRegistry
  var _issued: USize = 0

  new create(h: TestHelper) =>
    _h = h
    _registry = SessionRegistry
    _registry.issue("@alice:example.test", this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    _issued = _issued + 1
    let action =
      if _issued == 1 then
        "first token keeps its device"
      else
        "second token keeps its device"
      end
    _registry.resolve(
      token.reveal(), _ExpectDevice(_h, action, device.string()))

    if _issued == 1 then
      _registry.issue("@alice:example.test", this)
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)

actor _ExpectDevice is UserReceiver
  """
  Asserts a token resolves to one particular device.
  """
  let _h: TestHelper
  let _action: String
  let _expected: String

  new create(h: TestHelper, action: String, expected: String) =>
    _h = h
    _action = action
    _expected = expected

  be token_resolved(user_id: String, device: DeviceId) =>
    if device.string() == _expected then
      _h.complete_action(_action)
    else
      _h.log("resolved to " + device.string() + ", expected " + _expected)
      _h.fail_action(_action)
    end

  be token_rejected() =>
    _h.fail_action(_action)
