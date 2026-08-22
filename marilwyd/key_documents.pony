use "json"

primitive KeysUploaded
  """
  The body of `POST /_matrix/client/v3/keys/upload`.

  The count is what a client reads to decide whether to upload more keys,
  so it is the number marilwyd is holding rather than the number it was
  sent. Only `signed_curve25519` is named because that is the one algorithm
  clients upload one-time keys for; a pool of some other algorithm would be
  keys nothing asks for.
  """
  fun apply(count: USize): String =>
    "{\"one_time_key_counts\":{\"signed_curve25519\":" + count.string() + "}}"

primitive KeysQueried
  """
  The body of `POST /_matrix/client/v3/keys/query`.

  Every user asked about gets an entry even when marilwyd holds nothing for
  them. An account missing from the response is not the same as an account
  with no devices: the first tells a client's crypto machine that its query
  went unanswered, and it asks again at once, forever. Measured before
  device ids were real, that was 10,325 requests in seventy seconds.

  `failures` is always empty. It reports servers that could not be reached,
  and marilwyd federates with none.
  """
  fun apply(answers: Array[(String, PublishedKeys)] val): String =>
    recover val
      let out = String(512)
      out.append("{\"device_keys\":{")
      var first = true
      for (user_id, keys) in answers.values() do
        if not first then
          out.append(",")
        end
        first = false
        out.append(JSONPrinter.print(user_id))
        out.append(":{")
        var device_first = true
        for device in keys.devices.values() do
          if not device_first then
            out.append(",")
          end
          device_first = false
          out.append(JSONPrinter.print(device.device_id))
          out.append(":")
          out.append(device.content)
        end
        out.append("}")
      end
      out.append("}")
      _CrossSigning(out, "master_keys", answers, 0)
      _CrossSigning(out, "self_signing_keys", answers, 1)
      _CrossSigning(out, "user_signing_keys", answers, 2)
      out.append(",\"failures\":{}}")
      out
    end

primitive _CrossSigning
  """
  Append one cross-signing block, or nothing when no account has that key.

  An empty block and an absent one mean the same thing to a client, and
  omitting it keeps a response about accounts that have set up no
  cross-signing the same size it was before cross-signing existed.
  """
  fun apply(
    out: String ref,
    name: String,
    answers: Array[(String, PublishedKeys)] val,
    which: USize)
  =>
    var first = true
    for (user_id, keys) in answers.values() do
      let key =
        match which
        | 0 => keys.master
        | 1 => keys.self_signing
        else
          keys.user_signing
        end
      match key
      | let content: String =>
        if first then
          out.append(",\"")
          out.append(name)
          out.append("\":{")
        else
          out.append(",")
        end
        first = false
        out.append(JSONPrinter.print(user_id))
        out.append(":")
        out.append(content)
      end
    end
    if not first then
      out.append("}")
    end

primitive KeyBackupCreated
  """
  The body of `POST /_matrix/client/v3/room_keys/version`.
  """
  fun apply(version: String): String =>
    "{\"version\":" + JSONPrinter.print(version) + "}"

primitive NoKeyBackup
  """
  The body of `GET /_matrix/client/v3/room_keys/version` before a client
  has made one.

  `M_NOT_FOUND` rather than an empty version: a client reads this to decide
  whether to offer to set a backup up, and an empty answer would tell it
  one already exists.
  """
  fun apply(): String =>
    MatrixError("M_NOT_FOUND", "No backup has been made")

primitive SignaturesUploaded
  """
  The body of `POST /_matrix/client/v3/keys/signatures/upload`.
  """
  fun apply(): String => "{\"failures\":{}}"
