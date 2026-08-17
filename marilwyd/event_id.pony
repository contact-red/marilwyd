use "ssl/crypto"

class val EventId is Stringable
  """
  A Matrix event identifier — `$opaque`.

  Unlike `RoomId` this grants nothing: knowing an event id lets nobody read
  the event, because every read is scoped by room membership. It is a type
  for the confusion reason alone — it travels beside a room id and a user
  id, and all three are text.
  """
  let _value: String

  new val _create(value: String) =>
    _value = value

  fun string(): String iso^ =>
    _value.clone()

primitive MakeEventId
  """
  Mint an event identifier from the CSPRNG.

  Random rather than derived from the event's content, which is what a
  room version above 3 would require. marilwyd implements no version's
  rules, so a hash here would assert a conformance it does not have.
  """
  fun apply(): (EventId | NoSecureRandom) =>
    try
      EventId._create("$" + ToHexString(RandBytes(16)?))
    else
      NoSecureRandom
    end
