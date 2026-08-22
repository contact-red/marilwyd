use "json"

primitive MaxKeysBody
  """
  The largest key upload marilwyd will read.

  A real upload from Element 1.12.25 is 12,698 bytes — one device key object
  and fifty one-time keys. This leaves room for a client that batches
  differently without leaving the body unbounded.

  Under `MaxRequestBody()`, and that is the whole constraint on the
  number. It was 131,072 — twice the transport cap — so it could never
  fire: stallion refused the body first, as the bodiless `413` carrying no
  `errcode` that a per-endpoint limit exists to answer instead of.
  """
  fun apply(): USize => 49_152

primitive MaxOneTimeKeys
  """
  How many unclaimed one-time keys marilwyd holds for one device.

  Clients top the pool up towards fifty and stop when the count marilwyd
  reports says they are full. The cap is what stops a client that ignores
  that count from growing the pool without end; keys beyond it are refused,
  and the count the client is told stays true.
  """
  fun apply(): USize => 100

class val DeviceKeys
  """
  One device's published identity keys, as the device published them.

  Text rather than a parsed object, for the reason `_EventContent` gives:
  what is stored outlives the request that carried it, and a `JSONObject`
  built from the request body would pin the body, its connection and its
  handler for as long as anything held the keys.
  """
  let device_id: String
  let content: String

  new val create(device_id': String, content': String) =>
    device_id = device_id'
    content = content'

class val PublishedKeys
  """
  What `POST /_matrix/client/v3/keys/query` answers about one account.

  The cross-signing keys are separate fields rather than entries in
  `devices` because the query response puts them in separate objects, and
  because `user_signing` is the one key of the four that an account may see
  only for itself.
  """
  let devices: Array[DeviceKeys] val
  let master: (String | None)
  let self_signing: (String | None)
  let user_signing: (String | None)

  new val create(
    devices': Array[DeviceKeys] val,
    master': (String | None),
    self_signing': (String | None),
    user_signing': (String | None))
  =>
    devices = devices'
    master = master'
    self_signing = self_signing'
    user_signing = user_signing'

primitive _KeysBody
  """
  Parse a key upload and hand back the object, or say it is unusable.

  Separate from `_EventContent` because a key upload is read for its named
  fields rather than stored whole, and because it is allowed to be much
  larger than an event.
  """
  fun apply(body: Array[U8] val): (JSONObject | MalformedKeys) =>
    match _ObjectBody(body, MaxKeysBody())
    | let o: JSONObject => o
    else
      MalformedKeys
    end

primitive MalformedKeys
  """
  A key upload that is not a JSON object, or is larger than one may be.
  """
  fun message(): String => "Key uploads must be a JSON object"

primitive _PrintedField
  """
  Print one named object field of a body, or `None` if it is absent.

  Printing here is what lets everything downstream hold text: the object
  this reads belongs to the parse of a request body, and printing is how a
  copy that outlives the request is made.
  """
  fun apply(body: JSONObject, name: String): (String | None) =>
    try
      match body(name)?
      | let o: JSONObject => JSONPrinter.print(o)
      else
        None
      end
    else
      None
    end

primitive ReadOneTimeKeys
  """
  Read the `one_time_keys` field as a list of key id and printed value.

  Split into pairs rather than kept as one object so that a later upload
  tops the pool up rather than replacing it, and so that a claim can remove
  exactly one key. Values that are not objects are dropped: a one-time key
  is a signed object, and there is nothing to store in anything else.
  """
  fun apply(body: JSONObject, name: String)
    : Array[(String, String)] val
  =>
    let found = recover iso Array[(String, String)] end
    try
      match body(name)?
      | let keys: JSONObject =>
        for (id, value) in keys.pairs() do
          match value
          | let o: JSONObject => found.push((id.clone(), JSONPrinter.print(o)))
          end
        end
      end
    end
    consume found

primitive MergeSignatures
  """
  Add the signatures from an upload to a key object that is already stored.

  Only the `signatures` field of the upload is read. A signature upload
  carries the whole key object it signs, so storing what arrives would let
  one device of an account republish another device's identity keys —
  replacing what other users encrypt to. Taking only the signatures makes
  that impossible rather than merely disallowed.

  Anything that is not a signature — a key id whose value is not text, a
  signer whose value is not an object — is dropped rather than refused, so
  that one unreadable entry cannot cost a client the rest of them.
  """
  fun apply(stored: String, uploaded: JSONObject): String =>
    """
    The stored object, with the upload's signatures added to its own.
    """
    let base =
      match JSONParser.parse(stored)
      | let o: JSONObject => o
      else
        return stored
      end

    var signatures = _Nested(base, "signatures")

    for (signer, entries) in _Nested(uploaded, "signatures").pairs() do
      match entries
      | let by_key: JSONObject =>
        var into = _Nested(signatures, signer)
        for (key_id, signature) in by_key.pairs() do
          match signature
          | let text: String => into = into.update(key_id, text)
          end
        end
        signatures = signatures.update(signer, into)
      end
    end

    JSONPrinter.print(base.update("signatures", signatures))

primitive _Nested
  """
  One object field, or an empty object when there is nothing usable there.

  Absent, null and the wrong type all mean the same thing to everything
  that reads a key object: there is nothing to merge with.
  """
  fun apply(body: JSONObject, name: String): JSONObject =>
    try
      match body(name)?
      | let o: JSONObject => o
      else
        JSONObject
      end
    else
      JSONObject
    end
