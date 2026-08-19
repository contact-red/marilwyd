use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestAnAliasNamesItsServer is UnitTest
  """
  An alias for another server names a room this process could not answer
  for even in principle, since nothing here federates.
  """
  fun name(): String => "alias/an alias for another server is refused"

  fun apply(h: TestHelper) =>
    match RoomAliases("#pony:elsewhere.test", "example.test")
    | let a: RoomAlias =>
      h.fail("an alias for another server was accepted: " + a.string())
    end

class \nodoc\ iso _TestAnAliasBeginsWithHash is UnitTest
  fun name(): String => "alias/an alias begins with a hash"

  fun apply(h: TestHelper) =>
    match RoomAliases("pony:example.test", "example.test")
    | let a: RoomAlias => h.fail("accepted without a '#': " + a.string())
    end
    match RoomAliases("", "example.test")
    | let a: RoomAlias => h.fail("accepted an empty alias: " + a.string())
    end
    match RoomAliases("#pony", "example.test")
    | let a: RoomAlias => h.fail("accepted with no server: " + a.string())
    end

class \nodoc\ iso _TestAnAliasIsBuiltAndReadBack is UnitTest
  """
  What `createRoom` builds from `room_alias_name`, and what a client sends
  back to resolve it, are the same text.
  """
  fun name(): String => "alias/an alias built from a name parses back"

  fun apply(h: TestHelper) =>
    match \exhaustive\ RoomAliases.make("pony", "example.test")
    | let built: RoomAlias =>
      h.assert_eq[String]("#pony:example.test", built.string())
      match \exhaustive\ RoomAliases(built.string(), "example.test")
      | let read: RoomAlias =>
        h.assert_eq[String](built.string(), read.string())
      | let why: InvalidAlias =>
        h.fail("an alias marilwyd built did not parse: " + why.string())
      end
    | let why: InvalidAlias =>
      h.fail("could not build an alias: " + why.string())
    end

class \nodoc\ iso _TestAnAliasHoldsOnlyLocalpartCharacters is UnitTest
  """
  The same grammar as a user id's local part. An alias is offered to people
  to type, and one set of rules for both is one fewer to get wrong.
  """
  fun name(): String => "alias/an alias may hold only localpart characters"

  fun apply(h: TestHelper) =>
    match RoomAliases.make("Pony Room", "example.test")
    | let a: RoomAlias => h.fail("accepted spaces and case: " + a.string())
    end

class \nodoc\ iso _TestASummaryRendersWhatADirectoryShows is UnitTest
  fun name(): String => "alias/a room summary renders for the directory"

  fun apply(h: TestHelper) =>
    try
      let rendered =
        RoomSummary(
          _AnyRoomId()?.string(), "Pony", "#pony:example.test", 3)
          .render()
      h.assert_true(rendered.contains("\"name\":\"Pony\""), rendered)
      h.assert_true(
        rendered.contains("\"canonical_alias\":\"#pony:example.test\""),
        rendered)
      h.assert_true(rendered.contains("\"num_joined_members\":3"), rendered)
      h.assert_true(rendered.contains("\"room_id\":\"!"), rendered)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestASummaryOmitsWhatARoomLacks is UnitTest
  """
  A room with no name and no alias renders neither field rather than two
  empty ones — a client shows a room id where a name would go, which is
  true, instead of an empty heading.
  """
  fun name(): String => "alias/a summary omits a name a room does not have"

  fun apply(h: TestHelper) =>
    try
      let rendered =
        RoomSummary(_AnyRoomId()?.string(), None, None, 1).render()
      h.assert_false(rendered.contains("name"), rendered)
      h.assert_false(rendered.contains("canonical_alias"), rendered)
      h.assert_true(rendered.contains("\"num_joined_members\":1"), rendered)
    else
      _NoRandom(h)
    end

class \nodoc\ iso _TestAnEmptyDirectoryRenders is UnitTest
  fun name(): String => "alias/an empty directory renders an empty chunk"

  fun apply(h: TestHelper) =>
    h.assert_eq[String](
      "{\"chunk\":[],\"total_room_count_estimate\":0}",
      PublicRooms(recover val Array[RoomSummary] end))
