use "json"

primitive ToDeviceLimit
  """
  How many undelivered to-device messages one device accumulates.

  Its own bound rather than `PendingLimit()`, because what is lost differs.
  A dropped room event costs a client one message it can see it is missing;
  a dropped to-device message costs it half of a handshake, and neither end
  is told which half. Smaller for that reason: a device far enough behind
  to drop these is a device whose sessions have to be rebuilt anyway, and a
  large backlog only delays discovering that.
  """
  fun apply(): USize => 100

primitive MaxToDeviceBody
  """
  The largest `sendToDevice` request marilwyd will read.

  Equal to `MaxKeysBody()`, which it did not used to be: one request may
  name many devices, so it was set four times higher. Both were above
  `MaxRequestBody()`, so neither could fire and the difference between
  them decided nothing. Under a 64 kB transport cap there is no room for
  a meaningful difference, and a number that pretends otherwise reads as
  a decision that was made.
  """
  fun apply(): USize => 49_152

primitive AllDevices
  """
  The device id a client sends to mean every device of an account.
  """
  fun apply(): String => "*"

class val ToDeviceEvent
  """
  One message sent from one device to another, which marilwyd carries and
  does not read.

  The content is almost always an Olm ciphertext. marilwyd cannot decrypt
  it, has no reason to, and does not look inside — the sender and the type
  are the whole of what it needs to route one.

  No room, no event id, and no place in any timeline: a to-device message
  is delivered once to the device it names and then forgotten, which is why
  it is queued separately from the events a room fans out.
  """
  let sender: String
  let kind: String
  let content: String

  new val create(sender': String, kind': String, content': String) =>
    sender = sender'
    kind = kind'
    content = content'

  fun val render(): String =>
    recover val
      String(content.size() + 64)
        .> append("{\"sender\":")
        .> append(JsonPrinter.print(sender))
        .> append(",\"type\":")
        .> append(JsonPrinter.print(kind))
        .> append(",\"content\":")
        .> append(content)
        .> append("}")
    end
