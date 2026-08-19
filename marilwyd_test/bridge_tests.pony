use "files"
use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestBridgesAreRead is UnitTest
  """
  The whole file, read as an operator writes it.
  """
  fun name(): String => "bridges/a configuration is read"

  fun apply(h: TestHelper) =>
    match \exhaustive\ _ReadFixture(h)
    | let bridges: Bridges =>
      h.assert_eq[USize](1, bridges.networks.size())
      try
        let network = bridges.networks(0)?
        h.assert_eq[String]("testnet", network.name)
        h.assert_eq[String]("irc.example.test", network.host)
        h.assert_eq[String]("6697", network.service)
        h.assert_eq[Bool](true, network.tls)
        h.assert_eq[USize](1, network.channels.size())
        let channel = network.channels(0)?
        h.assert_eq[String]("#norrath", channel.channel)
        h.assert_eq[String]("norrath", channel.room_name)
        // Defaulted from the room's name, which is what naming it meant.
        h.assert_eq[String](
          "#norrath:example.test", channel.alias.string())
      else
        h.fail("the fixture parsed but held nothing")
      end
    | let e: StartupError =>
      h.fail("reading the fixture failed: " + e.message)
    end

class \nodoc\ iso _TestAMappingSubstitutes is UnitTest
  """
  Both directions, and they are not inverses: a Matrix user's IRC nick is
  decoration, an IRC user's Matrix id is an identity this server mints.
  """
  fun name(): String => "bridges/a mapping spells a name for the other side"

  fun apply(h: TestHelper) =>
    let mapping = NameMapping("{localpart}[marilwyd]", "irc_{network}_{nick}")
    h.assert_eq[String]("red[marilwyd]", mapping.irc_nick("red"))
    h.assert_eq[String](
      "irc_testnet_dai", mapping.matrix_localpart("testnet", "dai"))

class \nodoc\ iso _TestAGhostIdIsAddressable is UnitTest
  """
  Whatever a mapping produces has to be a user id this server can address,
  or the bridge mints senders nothing can render or reply to.
  """
  fun name(): String => "bridges/a mapped IRC name is a usable localpart"

  fun apply(h: TestHelper) =>
    let mapping = NameMapping("{localpart}[marilwyd]", "irc_{network}_{nick}")
    match Localpart.check(mapping.matrix_localpart("testnet", "dai"))
    | let why: String => h.fail("a mapped nick is not addressable: " + why)
    end

class \nodoc\ iso _TestADeclaredRoomIdIsChecked is UnitTest
  """
  Only the shape marilwyd itself mints. An id this server could not have
  produced names a room that cannot exist here.
  """
  fun name(): String => "bridges/a declared room id must be one of ours"

  fun apply(h: TestHelper) =>
    let good = "!0123456789abcdef0123456789abcdef:example.test"
    match RoomIds(good, "example.test")
    | let id: RoomId => h.assert_eq[String](good, id.string())
    else
      h.fail("a well-formed id was refused")
    end

    // Too short, not hex, another server, and no bang.
    for bad in
      [ "!0123:example.test"
        "!0123456789abcdefg123456789abcdef:example.test"
        "!0123456789abcdef0123456789abcdef:elsewhere.test"
        "?0123456789abcdef0123456789abcdef:example.test" ].values()
    do
      match RoomIds(bad, "example.test")
      | let id: RoomId => h.fail("accepted " + bad)
      end
    end

primitive \nodoc\ _ReadFixture
  fun apply(h: TestHelper): (Bridges | StartupError) =>
    let auth = FileAuth(h.env.root)
    let caps =
      recover val
        FileCaps .> set(FileLookup) .> set(FileRead) .> set(FileStat)
      end
    try
      ReadBridges(
        FilePath(auth, _BridgesFixture.path(), caps).canonical()?,
        "example.test")
    else
      StartupError("fixture", "the bridges fixture is missing")
    end

class \nodoc\ iso _TestANetworkNameMustBeAddressable is UnitTest
  """
  A network's name goes into every ghost user id it produces, so a name
  that cannot be part of a user id would mint senders nothing can render
  or reply to. Refused at startup rather than discovered when somebody
  speaks.
  """
  fun name(): String => "bridges/a network name must fit a user id"

  fun apply(h: TestHelper) =>
    let broken = _BridgesFixture.body().clone()
    broken.replace("name: testnet", "name: Fussake Net")
    match \exhaustive\ _ReadBridgesText(h, consume broken)
    | let b: Bridges =>
      h.fail("a network named 'Fussake Net' was accepted")
    | let e: StartupError =>
      h.assert_eq[String]("bridge-network-name", e.cause)
    end

primitive \nodoc\ _ReadBridgesText
  """
  Parse a bridges document written for one test.

  Written beside the shared fixture rather than into it, so a test that
  needs a broken file cannot break every other test that reads a good one.
  """
  fun apply(h: TestHelper, body: String): (Bridges | StartupError) =>
    let auth = FileAuth(h.env.root)
    let path = FilePath(auth, "build/test-bridges-case.yaml")
    File(path) .> set_length(0) .> write(body) .> dispose()
    let caps =
      recover val
        FileCaps .> set(FileLookup) .> set(FileRead) .> set(FileStat)
      end
    try
      ReadBridges(
        FilePath(auth, "build/test-bridges-case.yaml", caps).canonical()?,
        "example.test")
    else
      StartupError("fixture", "the case file could not be written")
    end

class \nodoc\ iso _TestADeclaredRoomIsPublishedAndAliased is UnitTest
  """
  What declaring a room is for: it exists before any client connects, it is
  listed in the directory, and it answers to the alias in the file. A
  person joins it by clicking Explore, never by being handed an id.
  """
  fun name(): String => "bridges/a declared room is published and aliased"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    match (RoomAliases.make("norrath", "example.test"),
      MakeHomeserver.http("example.test"))
    | (let alias: RoomAlias, let hs: Homeserver) =>
      _DeclareThenLook(
        h, BridgedChannel("#norrath", "norrath", alias, None), hs)
    else
      h.fail("could not build the fixture")
    end

actor \nodoc\ _DeclareThenLook is
  (DeclaredRoomReceiver & AliasReceiver & PublishedRoomsReceiver
    & RoomSummaryReceiver)
  """
  Declares a room, then asks the directory the two questions a person's
  client asks: what is listed, and what does this name resolve to.
  """
  let _h: TestHelper
  let _rooms: RoomDirectory
  var _resolved: Bool = false

  new create(h: TestHelper, channel: BridgedChannel, hs: Homeserver) =>
    _h = h
    _rooms = RoomDirectory(hs)
    _rooms.declare(channel, "@irc_testnet_marilwyd:example.test", this)

  be room_declared(channel: BridgedChannel, id: RoomId, room: Room tag) =>
    // Only once the room says it exists, so nothing here races its
    // creation.
    _rooms.resolve_alias(channel.alias.string(), this)

  be declaration_refused(channel: String) =>
    _h.fail("declaring " + channel + " was refused")
    _h.complete(false)

  be alias_resolved(room_id: String) =>
    _resolved = true
    _h.assert_true(room_id.at("!", 0), room_id)
    _rooms.published(this)

  be alias_unknown() =>
    _h.fail("a declared room's alias resolved to nothing")
    _h.complete(false)

  be rooms_published(rooms: Array[Room tag] val) =>
    _h.assert_eq[USize](1, rooms.size(), "a declared room was not published")
    for room in rooms.values() do
      room.summarise(this)
    end

  be room_summarised(summary: RoomSummary) =>
    _h.assert_true(_resolved, "the alias never resolved")
    _h.assert_eq[String]("norrath", try summary.name as String else "" end)
    _h.assert_eq[String](
      "#norrath:example.test", try summary.alias as String else "" end)
    // Declared, not joined: a room that starts empty is the point.
    _h.assert_eq[USize](0, summary.members)
    _h.complete(true)

class \nodoc\ iso _TestADeclaredRoomKeepsItsDeclaredId is UnitTest
  """
  The whole reason `room_id` is in the file: with one, a bridged room is
  the same room after a restart, not merely a room with the same name.
  """
  fun name(): String => "bridges/a declared room keeps the id it was given"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    let wanted = "!0123456789abcdef0123456789abcdef:example.test"
    match (RoomAliases.make("norrath", "example.test"),
      RoomIds(wanted, "example.test"),
      MakeHomeserver.http("example.test"))
    | (let alias: RoomAlias, let id: RoomId, let hs: Homeserver) =>
      _DeclareWithId(
        h, BridgedChannel("#norrath", "norrath", alias, id), hs, wanted)
    else
      h.fail("could not build the fixture")
    end

actor \nodoc\ _DeclareWithId is DeclaredRoomReceiver
  let _h: TestHelper
  let _wanted: String

  new create(
    h: TestHelper,
    channel: BridgedChannel,
    hs: Homeserver,
    wanted: String)
  =>
    _h = h
    _wanted = wanted
    RoomDirectory(hs).declare(
      channel, "@irc_testnet_marilwyd:example.test", this)

  be room_declared(channel: BridgedChannel, id: RoomId, room: Room tag) =>
    _h.assert_eq[String](_wanted, id.string())
    _h.complete(true)

  be declaration_refused(channel: String) =>
    _h.fail("declaring " + channel + " with a declared id was refused")
    _h.complete(false)
