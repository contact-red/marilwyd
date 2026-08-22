use "collections"
use "json"

primitive KeysClaimed
  """
  The body of `POST /_matrix/client/v3/keys/claim`.

  A device with no key left is left out entirely rather than given an empty
  object. That is what the specification says, and it is also what a client
  needs: an empty object would say a key was handed over and then fail to
  name it, where an absent device says plainly that there was none.

  `failures` is always empty. It reports servers that could not be reached,
  and marilwyd federates with none.
  """
  fun apply(claimed: Array[ClaimedKey] val): String =>
    recover val
      let grouped = Map[String, Array[ClaimedKey]]
      for key in claimed.values() do
        try
          grouped(key.user_id)?.push(key)
        else
          let fresh = Array[ClaimedKey]
          fresh.push(key)
          grouped(key.user_id) = fresh
        end
      end

      let out = String(256)
      out.append("{\"one_time_keys\":{")
      var first = true
      for (user_id, keys) in grouped.pairs() do
        if not first then
          out.append(",")
        end
        first = false
        out.append(JSONPrinter.print(user_id))
        out.append(":{")
        var device_first = true
        for key in keys.values() do
          if not device_first then
            out.append(",")
          end
          device_first = false
          out.append(JSONPrinter.print(key.device_id))
          out.append(":{")
          out.append(JSONPrinter.print(key.key_id))
          out.append(":")
          out.append(key.content)
          out.append("}")
        end
        out.append("}")
      end
      out.append("},\"failures\":{}}")
      out
    end

class val ClaimedKey
  """
  One key that was spent, and who it belonged to.

  Grouped by account when rendered.
  """
  let user_id: String
  let device_id: String
  let key_id: String
  let content: String

  new val create(
    user_id': String,
    device_id': String,
    key_id': String,
    content': String)
  =>
    user_id = user_id'
    device_id = device_id'
    key_id = key_id'
    content = content'
