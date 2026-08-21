use "json"

class val KeyBackup
  """
  One version of a room key backup, as the client described it.

  marilwyd stores the description and nothing else. The backup itself —
  `/room_keys/keys` — is not implemented, so a version here is a place a
  client may write keys to that holds none, and `count` says so.

  It is not optional decoration. Element creates a backup version during
  `Setting up keys`, and a client that cannot create one stops there: with
  `POST /room_keys/version` answering `M_NOT_FOUND`, the whole session ends
  at "Unable to set up keys" and never reaches the app.
  """
  let algorithm: String
  let auth_data: String

  new val create(algorithm': String, auth_data': String) =>
    algorithm = algorithm'
    auth_data = auth_data'

  fun val render(version: String): String =>
    """
    The body of `GET /_matrix/client/v3/room_keys/version`.

    `count` and `etag` are constants because nothing can change them:
    without an endpoint to upload room keys to, a backup holds none and its
    contents never change.
    """
    recover val
      String(auth_data.size() + 128)
        .> append("{\"algorithm\":")
        .> append(JSONPrinter.print(algorithm))
        .> append(",\"auth_data\":")
        .> append(auth_data)
        .> append(",\"version\":")
        .> append(JSONPrinter.print(version))
        .> append(",\"count\":0,\"etag\":\"0\"}")
    end

primitive KeyNamed
  """
  Whether a stored key object publishes the given key id.

  A cross-signing key is identified by its own public key rather than by a
  device id, so this is how an upload keyed by `ed25519:<public key>` is
  matched to the one of the three it signs.
  """
  fun apply(stored: String, key_id: String): Bool =>
    let published =
      match JSONParser.parse(stored)
      | let o: JSONObject => o
      else
        return false
      end
    try
      match published("keys")?
      | let keys: JSONObject => return keys.contains(key_id)
      end
    end
    false
