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

class \nodoc\ iso _TestADeclaredChannelIsAdvertised is UnitTest
  """
  What declaring a channel does: it can be entered by its alias, and it
  appears in the directory — but it is not a room and no room exists for
  it until somebody enters.
  """
  fun name(): String => "bridges/a declared channel is advertised"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    match (RoomAliases.make("norrath", "example.test"),
      MakeHomeserver.http("example.test"))
    | (let alias: RoomAlias, let hs: Homeserver) =>
      _DeclareThenLook(
        h, BridgedChannel("#norrath", "norrath", alias), hs)
    else
      h.fail("could not build the fixture")
    end

actor \nodoc\ _DeclareThenLook is
  (DeclaredChannelReceiver & ChannelListReceiver)
  """
  Declares a channel and then asks the directory what it advertises.
  """
  let _h: TestHelper
  let _rooms: RoomDirectory

  new create(h: TestHelper, channel: BridgedChannel, hs: Homeserver) =>
    _h = h
    _rooms = RoomDirectory(hs)
    _rooms.declare(
      channel, _TestNetwork(), this)

  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    _rooms.channels(this)

  be declaration_refused(channel: String) =>
    _h.fail("declaring " + channel + " was refused")
    _h.complete(false)

  be channels_listed(channels: Array[BridgedChannel] val) =>
    _h.assert_eq[USize](1, channels.size())
    try
      _h.assert_eq[String]("#norrath", channels(0)?.channel)
      _h.assert_eq[String](
        "#norrath:example.test", channels(0)?.alias.string())
    else
      _h.fail("the channel list held nothing")
    end
    _h.complete(true)

class \nodoc\ iso _TestEachUserGetsTheirOwnRoom is UnitTest
  """
  The reason for all of this. Two people who enter one channel hold two
  rooms, because a room is what one IRC session heard — and sharing one
  between several sessions meant every message crossed the boundary once
  per member and everybody saw it that many times.
  """
  fun name(): String => "bridges/two people get two rooms for one channel"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    match (RoomAliases.make("norrath", "example.test"),
      MakeHomeserver.http("example.test"))
    | (let alias: RoomAlias, let hs: Homeserver) =>
      _TwoUsersOneChannel(
        h, BridgedChannel("#norrath", "norrath", alias), hs)
    else
      h.fail("could not build the fixture")
    end

actor \nodoc\ _TwoUsersOneChannel is
  (DeclaredChannelReceiver & BridgedRoomReceiver & RoomIdReceiver)
  let _h: TestHelper
  let _rooms: RoomDirectory
  let _alias: String
  var _first: (String | None) = None

  new create(h: TestHelper, channel: BridgedChannel, hs: Homeserver) =>
    _h = h
    _alias = channel.alias.string()
    _rooms = RoomDirectory(hs)
    _rooms.declare(channel, _TestNetwork(), this)

  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    _rooms.for_user(_alias, "@alice:example.test", this)

  be declaration_refused(channel: String) =>
    _h.fail("declaring was refused")
    _h.complete(false)

  be bridged_room(room: Room tag, network: BridgedNetwork) =>
    room.identify(this)

  be no_room_made() =>
    _h.fail("the room for a declared channel could not be made")
    _h.complete(false)

  be no_such_channel() =>
    _h.fail("the channel it just declared was not found")
    _h.complete(false)

  be room_identified(id: RoomId) =>
    match _first
    | let alice: String =>
      _h.assert_ne[String](
        alice, id.string(), "two people were given one room")
      _h.complete(true)
    else
      _first = id.string()
      _rooms.for_user(_alias, "@bob:example.test", this)
    end

class \nodoc\ iso _TestTheSamePersonKeepsTheirRoom is UnitTest
  """
  Entering twice is the same room, not a second one — otherwise a client
  reconnecting would accumulate rooms for one channel.
  """
  fun name(): String => "bridges/entering twice is the same room"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    match (RoomAliases.make("norrath", "example.test"),
      MakeHomeserver.http("example.test"))
    | (let alias: RoomAlias, let hs: Homeserver) =>
      _OneUserTwice(
        h, BridgedChannel("#norrath", "norrath", alias), hs)
    else
      h.fail("could not build the fixture")
    end

actor \nodoc\ _OneUserTwice is
  (DeclaredChannelReceiver & BridgedRoomReceiver & RoomIdReceiver)
  let _h: TestHelper
  let _rooms: RoomDirectory
  let _alias: String
  var _first: (String | None) = None

  new create(h: TestHelper, channel: BridgedChannel, hs: Homeserver) =>
    _h = h
    _alias = channel.alias.string()
    _rooms = RoomDirectory(hs)
    _rooms.declare(channel, _TestNetwork(), this)

  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    _rooms.for_user(_alias, "@alice:example.test", this)

  be declaration_refused(channel: String) =>
    _h.fail("declaring was refused")
    _h.complete(false)

  be bridged_room(room: Room tag, network: BridgedNetwork) =>
    room.identify(this)

  be no_room_made() =>
    _h.fail("the room for a declared channel could not be made")
    _h.complete(false)

  be no_such_channel() =>
    _h.fail("the channel was not found")
    _h.complete(false)

  be room_identified(id: RoomId) =>
    match _first
    | let before: String =>
      _h.assert_eq[String](
        before, id.string(), "entering twice made two rooms")
      _h.complete(true)
    else
      _first = id.string()
      _rooms.for_user(_alias, "@alice:example.test", this)
    end

primitive \nodoc\ _TestNetwork
  """
  A network for tests that declare a channel without connecting to one.
  """
  fun apply(): BridgedNetwork =>
    BridgedNetwork(
      "testnet",
      "irc.example.test",
      "6697",
      true,
      recover val ["marilwyd"] end,
      recover val Array[BridgedChannel] end)

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

class \nodoc\ iso _TestAChannelsAliasCannotBeTaken is UnitTest
  """
  A declared channel's alias belongs to the channel, and an account
  cannot claim it.

  There is one alias namespace and it was kept in two maps: `create_room`
  checked the room aliases and `declare` checked the channels, neither
  consulting the other. After a squat the same alias named two different
  things depending on which endpoint was asked — the channel on the paths
  that resolve for a user, the squatter's room on the paths that resolve
  by alias — and the public directory listed both, with the squatter
  choosing the display name.
  """
  fun name(): String => "bridges/a channel's alias cannot be taken"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    match (
      RoomAliases("#norrath:example.test", "example.test"),
      MakeHomeserver.http("example.test"))
    | (let alias: RoomAlias, let hs: Homeserver) =>
      _AliasSquatter(h, BridgedChannel("#norrath", "norrath", alias), hs)
    else
      h.fail("could not build a fixture")
    end

actor \nodoc\ _AliasSquatter is
  (DeclaredChannelReceiver & RoomCreationReceiver)
  """
  Declares a channel, then tries to create an ordinary room under the
  channel's alias, and then the other way round.
  """
  let _h: TestHelper
  let _rooms: RoomDirectory
  let _channel: BridgedChannel
  let _user: User
  var _second: Bool = false

  new create(h: TestHelper, channel: BridgedChannel, hs: Homeserver) =>
    _h = h
    _channel = channel
    _user = User("@squatter:example.test")
    _rooms = RoomDirectory(hs)
    _rooms.declare(channel, _TestNetwork(), this)

  be channel_declared(channel: BridgedChannel, network: BridgedNetwork) =>
    _rooms.create_room(
      "@squatter:example.test",
      _user,
      CreateRoomRequest(None, _channel.alias, false),
      this,
      _user)

  be declaration_refused(channel: String) =>
    if _second then
      // The other direction, which is the half that already worked.
      _h.complete(true)
    else
      _h.fail("declaring a channel into an empty directory was refused")
      _h.complete(false)
    end

  be room_created(id: RoomId) =>
    _h.fail("an account took a declared channel's alias")
    _h.complete(false)

  be alias_taken() =>
    // Now the reverse: a channel may not take a room's alias either.
    _second = true
    match RoomAliases("#taken:example.test", "example.test")
    | let other: RoomAlias =>
      _rooms.create_room(
        "@squatter:example.test",
        _user,
        CreateRoomRequest(None, other, false),
        _ExpectRoomThen(_h, _rooms, _channel, this, other),
        _user)
    else
      _h.fail("could not build the second alias")
      _h.complete(false)
    end

  be room_refused() =>
    _h.fail("the CSPRNG is unavailable")
    _h.complete(false)

actor \nodoc\ _ExpectRoomThen is RoomCreationReceiver
  """
  Takes an alias with an ordinary room, then declares a channel wanting
  the same one.
  """
  let _h: TestHelper
  let _rooms: RoomDirectory
  let _channel: BridgedChannel
  let _then: DeclaredChannelReceiver tag
  let _alias: RoomAlias

  new create(
    h: TestHelper,
    rooms: RoomDirectory,
    channel: BridgedChannel,
    then': DeclaredChannelReceiver tag,
    alias: RoomAlias)
  =>
    _h = h
    _rooms = rooms
    _channel = channel
    _then = then'
    _alias = alias

  be room_created(id: RoomId) =>
    _rooms.declare(
      BridgedChannel(_channel.channel, _channel.room_name, _alias),
      _TestNetwork(),
      _then)

  be alias_taken() =>
    _h.fail("a free alias was reported as taken")
    _h.complete(false)

  be room_refused() =>
    _h.fail("the CSPRNG is unavailable")
    _h.complete(false)
