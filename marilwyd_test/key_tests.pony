use "json"
use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestSignaturesAreMergedNotSubstituted is UnitTest
  """
  The security property of `keys/signatures/upload`, stated as a test.

  A signature upload carries the whole key object it signs, so the easy
  implementation stores what arrives. That would let any device of an
  account republish another device's identity keys — and other users
  encrypt to whatever `keys` says. Only the signatures may cross.
  """
  fun name(): String => "keys/a signature upload cannot replace a key"

  fun apply(h: TestHelper) =>
    let stored =
      "{\"device_id\":\"AAA\",\"keys\":{\"ed25519:AAA\":\"real\"},"
        + "\"signatures\":{}}"
    let uploaded =
      match JSONParser.parse(
        "{\"device_id\":\"AAA\",\"keys\":{\"ed25519:AAA\":\"forged\"},"
          + "\"signatures\":{\"@a:x\":{\"ed25519:M\":\"sig\"}}}")
      | let o: JSONObject => o
      else
        h.fail("the fixture is not JSON")
        return
      end

    let merged = MergeSignatures(stored, uploaded)
    h.assert_true(merged.contains("real"), merged)
    h.assert_false(merged.contains("forged"), merged)
    h.assert_true(merged.contains("\"sig\""), merged)

class \nodoc\ iso _TestSignaturesAccumulate is UnitTest
  """
  A second signature does not displace the first. Two devices signing the
  same key is the ordinary case, not an edge one.
  """
  fun name(): String => "keys/signatures from two signers both survive"

  fun apply(h: TestHelper) =>
    let stored =
      "{\"keys\":{\"ed25519:AAA\":\"k\"},"
        + "\"signatures\":{\"@a:x\":{\"ed25519:ONE\":\"first\"}}}"
    let uploaded =
      match JSONParser.parse(
        "{\"signatures\":{\"@a:x\":{\"ed25519:TWO\":\"second\"}}}")
      | let o: JSONObject => o
      else
        h.fail("the fixture is not JSON")
        return
      end

    let merged = MergeSignatures(stored, uploaded)
    h.assert_true(merged.contains("first"), merged)
    h.assert_true(merged.contains("second"), merged)

class \nodoc\ iso _TestAQueryAlwaysAnswersAboutTheAsker is UnitTest
  """
  The request storm, as a property. A client asks about itself constantly,
  and an answer that omits an account it asked about is read as a query
  that did not resolve — which is retried at once, forever.
  """
  fun name(): String => "keys/a query always covers the account asking"

  fun apply(h: TestHelper) =>
    let asked =
      match JSONParser.parse("{\"device_keys\":{\"@other:x\":[]}}")
      | let o: JSONObject => o
      else
        h.fail("the fixture is not JSON")
        return
      end

    let wanted = QueriedUsers(asked, "@alice:x")
    h.assert_eq[USize](2, wanted.size())
    h.assert_eq[String]("@alice:x", try wanted(0)? else "" end)

class \nodoc\ iso _TestAQueryDoesNotNameTheAskerTwice is UnitTest
  """
  A client naming itself must not produce two entries for one account: the
  response is an object, and a repeated key is a document a client may read
  either way.
  """
  fun name(): String => "keys/an account named by itself appears once"

  fun apply(h: TestHelper) =>
    let asked =
      match JSONParser.parse("{\"device_keys\":{\"@alice:x\":[]}}")
      | let o: JSONObject => o
      else
        h.fail("the fixture is not JSON")
        return
      end

    h.assert_eq[USize](1, QueriedUsers(asked, "@alice:x").size())

class \nodoc\ iso _TestAnUnknownAccountStillGetsAnEntry is UnitTest
  """
  An account marilwyd holds nothing for is answered with no devices rather
  than left out. The two are different documents, and only one of them is
  an answer.
  """
  fun name(): String => "keys/an unknown account is answered with no devices"

  fun apply(h: TestHelper) =>
    let answers =
      recover val
        [ ("@nobody:x",
            PublishedKeys(
              recover val Array[DeviceKeys] end, None, None, None)) ]
      end
    let rendered = KeysQueried(answers)
    h.assert_true(rendered.contains("\"@nobody:x\":{}"), rendered)
    h.assert_false(rendered.contains("master_keys"), rendered)

class \nodoc\ iso _TestAQueryCarriesPublishedDeviceKeys is UnitTest
  fun name(): String => "keys/a query carries what a device published"

  fun apply(h: TestHelper) =>
    let answers =
      recover val
        [ ("@alice:x",
            PublishedKeys(
              recover val [DeviceKeys("AAA", "{\"k\":1}")] end,
              "{\"master\":true}",
              None,
              None)) ]
      end
    let rendered = KeysQueried(answers)
    h.assert_true(rendered.contains("\"AAA\":{\"k\":1}"), rendered)
    h.assert_true(
      rendered.contains("\"master_keys\":{\"@alice:x\":{\"master\":true}}"),
      rendered)

class \nodoc\ iso _TestACrossSigningKeyIsFoundByItsOwnKey is UnitTest
  """
  A cross-signing key is keyed by its own public key rather than by a
  device id, so this is the only way a signature upload can be matched to
  the one of the three it signs.
  """
  fun name(): String => "keys/a cross-signing key is matched by its key id"

  fun apply(h: TestHelper) =>
    let master = "{\"keys\":{\"ed25519:MMM\":\"MMM\"},\"usage\":[\"master\"]}"
    h.assert_true(KeyNamed(master, "ed25519:MMM"))
    h.assert_false(KeyNamed(master, "ed25519:OTHER"))

class \nodoc\ iso _TestOneTimeKeysAreSplitIntoPairs is UnitTest
  fun name(): String => "keys/one-time keys are read as separate keys"

  fun apply(h: TestHelper) =>
    let uploaded =
      match JSONParser.parse(
        "{\"one_time_keys\":{\"signed_curve25519:a\":{\"key\":\"1\"},"
          + "\"signed_curve25519:b\":{\"key\":\"2\"}}}")
      | let o: JSONObject => o
      else
        h.fail("the fixture is not JSON")
        return
      end

    h.assert_eq[USize](2, ReadOneTimeKeys(uploaded, "one_time_keys").size())
    h.assert_eq[USize](0, ReadOneTimeKeys(uploaded, "fallback_keys").size())

class \nodoc\ iso _TestOneTimeKeysAreCounted is UnitTest
  """
  The count a client is told is the number marilwyd is holding, because
  that is what the client uses to decide whether to send more.
  """
  fun name(): String => "keys/a device answers how many keys it holds"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      device.take_one_time_keys(
        recover val [("a", "{}"); ("b", "{}")] end,
        _ExpectKeyCount(h, 2))
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestAnUploadedKeyIsNotReplaced is UnitTest
  """
  A pool is keyed by key id, so a client re-sending a key it has already
  uploaded does not grow it. Without that, a client that resends its whole
  pool on every upload would report a rising count and stop uploading real
  keys once it passed the cap.
  """
  fun name(): String => "keys/re-uploading a key id does not grow the pool"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      Device(_AnyDeviceId()?, _AnyEpoch()?)
        .> take_one_time_keys(
          recover val [("a", "{}")] end, _IgnoreKeyCount)
        // The same id again, plus one new: the pool must be two, not
        // three, and not one.
        .> take_one_time_keys(
          recover val [("a", "{}"); ("b", "{}")] end,
          _ExpectKeyCount(h, 2))
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestTheKeyPoolIsBounded is UnitTest
  """
  A client that ignores the count it is told cannot grow the pool without
  end.
  """
  fun name(): String => "keys/the one-time key pool is capped"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      let device = Device(_AnyDeviceId()?, _AnyEpoch()?)
      let many = recover iso Array[(String, String)] end
      var i: USize = 0
      while i < (MaxOneTimeKeys() * 2) do
        many.push((i.string(), "{}"))
        i = i + 1
      end
      device.take_one_time_keys(
        consume many,
        _ExpectKeyCount(h, MaxOneTimeKeys()))
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestUserSigningIsWithheldFromOthers is UnitTest
  """
  The user-signing key is what an account uses to sign other people, so its
  owner is the only one who may read it. The other three are public by
  design — they are what everyone else encrypts to.
  """
  fun name(): String => "keys/the user-signing key is answered to its owner"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    User("@alice:example.test")
      .> publish_cross_signing(
        "{\"master\":true}", "{\"self\":true}", "{\"user\":true}")
      .> published_keys(_ExpectUserSigning(h, false), false)

class \nodoc\ iso _TestUserSigningReachesItsOwner is UnitTest
  fun name(): String => "keys/the user-signing key is withheld from others"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    User("@alice:example.test")
      .> publish_cross_signing(
        "{\"master\":true}", "{\"self\":true}", "{\"user\":true}")
      .> published_keys(_ExpectUserSigning(h, true), true)

class \nodoc\ iso _TestAPartialCrossSigningUploadKeepsTheRest is UnitTest
  """
  An upload naming one key does not clear the others. A client replacing
  its self-signing key is not saying its master key is gone.
  """
  fun name(): String => "keys/an absent cross-signing key is not a deletion"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    User("@alice:example.test")
      .> publish_cross_signing(
        "{\"master\":true}", "{\"self\":true}", "{\"user\":true}")
      .> publish_cross_signing(None, "{\"self\":2}", None)
      .> published_keys(_ExpectMasterSurvives(h), true)

class \nodoc\ iso _TestDeletingADeviceUnpublishesItsKeys is UnitTest
  """
  Keys published for a device that no longer exists tell everyone else to
  encrypt to something that can never read what they send.
  """
  fun name(): String => "keys/deleting a device unpublishes its keys"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    User("@alice:example.test")
      .> publish_keys("AAA", "{\"gone\":true}")
      .> publish_keys("BBB", "{\"kept\":true}")
      .> forget_device("AAA")
      .> published_keys(_ExpectOnlyKept(h), true)

actor \nodoc\ _ExpectOnlyKept is PublishedKeysReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be keys_published(user_id: String, keys: PublishedKeys) =>
    _h.assert_eq[USize](1, keys.devices.size())
    _h.assert_eq[String]("BBB", try keys.devices(0)?.device_id else "" end)
    _h.complete(true)

actor \nodoc\ _ExpectKeyCount is OneTimeKeyReceiver
  let _h: TestHelper
  let _want: USize

  new create(h: TestHelper, want: USize) =>
    _h = h
    _want = want

  be one_time_keys_held(count: USize) =>
    _h.assert_eq[USize](_want, count)
    _h.complete(true)

actor \nodoc\ _IgnoreKeyCount is OneTimeKeyReceiver
  be one_time_keys_held(count: USize) => None

actor \nodoc\ _ExpectUserSigning is PublishedKeysReceiver
  let _h: TestHelper
  let _want: Bool

  new create(h: TestHelper, want: Bool) =>
    _h = h
    _want = want

  be keys_published(user_id: String, keys: PublishedKeys) =>
    let present =
      match keys.user_signing
      | let _: String => true
      else
        false
      end
    _h.assert_eq[Bool](_want, present)
    // The public three travel either way, so a test that passed by
    // answering nothing at all would fail here.
    let public_key_present =
      match keys.master
      | let _: String => true
      else
        false
      end
    _h.assert_true(public_key_present, "the master key was withheld too")
    _h.complete(true)

actor \nodoc\ _ExpectMasterSurvives is PublishedKeysReceiver
  let _h: TestHelper

  new create(h: TestHelper) =>
    _h = h

  be keys_published(user_id: String, keys: PublishedKeys) =>
    _h.assert_eq[String](
      "{\"master\":true}", try keys.master as String else "" end)
    _h.assert_eq[String](
      "{\"self\":2}", try keys.self_signing as String else "" end)
    _h.complete(true)

class \nodoc\ iso _TestDeletingADeviceUnpublishesThroughTheRegistry
  is UnitTest
  """
  The wiring, not the behaviour: `forget_device` removing keys is tested
  above, and this is what proves deleting a device reaches it.

  Driven at the registry because it is the only thing that holds both the
  session being deleted and the `User` that published the keys.
  """
  fun name(): String => "keys/deleting a device reaches its published keys"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    try
      _DeleteThenQuery(h, _AnyEpoch()?)
    else
      _NoRandom(h)
    end

actor \nodoc\ _DeleteThenQuery is
  (TokenReceiver & UserReceiver & RevocationReceiver & UserLookupReceiver
    & PublishedKeysReceiver)
  """
  Sign in, publish a key, delete the device, then ask what is published.

  Each step waits for the one before it to be observed rather than merely
  sent. `publish_keys` and `forget_device` reach the `User` from two
  different senders — this actor and the registry — and Pony orders
  messages per sender, not globally, so without the round trip in
  `keys_published` the delete could be applied before the publish it is
  supposed to undo. The test would then pass while proving nothing.
  """
  let _h: TestHelper
  let _registry: SessionRegistry
  var _device: String = ""
  var _token: (AccessToken | None) = None
  var _published: Bool = false

  new create(h: TestHelper, epoch: StreamEpoch) =>
    _h = h
    _registry = SessionRegistry(epoch)
    _registry.issue("@alice:example.test", None, this)

  be token_issued(token: AccessToken, device: DeviceId) =>
    _device = device.string()
    _token = token
    // Resolving is how this gets the `User` to publish through, and it is
    // also what a real key upload does.
    _registry.resolve(token.reveal(), this)

  be token_resolved(session: Session) =>
    session.user.publish_keys(_device, "{\"published\":true}")
    // Ordered behind the publish, because it has the same sender.
    session.user.published_keys(this, true)

  be token_rejected() =>
    _h.fail("the token the registry issued did not resolve")
    _h.complete(false)

  be keys_published(user_id: String, keys: PublishedKeys) =>
    if not _published then
      _published = true
      _h.assert_eq[USize](1, keys.devices.size(), "the key was not published")
      match _token
      | let t: AccessToken =>
        _registry.revoke_devices(
          t.reveal(), recover val [_device] end, this)
      end
    else
      _h.assert_eq[USize](
        0,
        keys.devices.size(),
        "a deleted device's keys are still published")
      _h.complete(true)
    end

  be session_revoked() =>
    _registry.lookup_users(recover val ["@alice:example.test"] end, this)

  be revocation_rejected() =>
    _h.fail("deleting one's own device was refused")
    _h.complete(false)

  be users_found(
    known: Array[(String, User tag)] val,
    unknown: Array[String] val)
  =>
    """
    Safe to ask now: the registry sent `forget_device` to the `User` before
    it sent this, so that message is already queued ahead of the one this
    is about to send.
    """
    try
      (_, let user: User tag) = known(0)?
      user.published_keys(this, true)
    else
      _h.fail("the account that just signed in was not found")
      _h.complete(false)
    end

  be token_refused() =>
    _h.fail("the CSPRNG refused to mint a token")
    _h.complete(false)
