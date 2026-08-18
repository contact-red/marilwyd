use "collections"
use "json"

primitive ElementConfig
  """
  Element's `config.json`, generated from marilwyd's own configuration rather
  than shipped as a file, so there is nothing to keep in step.

  Only `default_server_config` is required; every other key in Element's
  `config.sample.json` is optional.
  """
  fun apply(homeserver: Homeserver): String =>
    let homeserver_config = JsonObject
      .update("base_url", homeserver.base_url())
      .update("server_name", homeserver.server_name)

    // `disable_custom_urls` is written explicitly rather than omitted.
    // Element defaults it to false anyway, but stating it keeps the decision
    // visible: an operator may want to point this client at another
    // homeserver for comparison, and the "Edit" affordance it controls is
    // also the only way to recover from a marilwyd started with the wrong
    // --server-name.
    JsonPrinter.print(
      JsonObject
        .update(
          "default_server_config",
          JsonObject.update("m.homeserver", homeserver_config))
        .update("disable_custom_urls", false))

primitive ClientVersions
  """
  `GET /_matrix/client/versions`.

  Claims the least a client will accept. Validated against **Element
  1.12.25**: matrix-js-sdk gates a dozen feature paths on versions above this
  one, and claiming them would make the client call endpoints that do not
  exist. Re-check when the Element version in the Makefile changes.
  """
  fun apply(): String =>
    JsonPrinter.print(JsonObject.update("versions", JsonArray.push("v1.1")))

primitive LoginFlows
  """
  `GET /_matrix/client/v3/login`.

  Naming `m.login.password` is an **assertion, not a derivation** — marilwyd
  implements no flows at all yet. The day a second flow exists is the day this
  must be computed from the flows marilwyd actually has.

  Validated against Element 1.12.25: without this document the login view
  never populates its flow list and falls back to an unsupported-client
  message instead of rendering a form.
  """
  fun apply(): String =>
    let password = JsonObject.update("type", "m.login.password")
    JsonPrinter.print(
      JsonObject.update("flows", JsonArray.push(password)))

primitive UnrecognizedRequest
  """
  The body for any `/_matrix/` path marilwyd does not implement.

  matrix-js-sdk keys its prefix negotiation on `errcode`, so an unimplemented
  endpoint has to answer in Matrix's vocabulary. Without this the request
  falls through to the static file handler and gets a plain-text 404, which
  the client treats as a transport failure rather than a known answer.
  """
  fun apply(): String =>
    JsonPrinter.print(JsonObject
      .update("errcode", "M_UNRECOGNIZED")
      .update("error", "Unrecognized request"))

primitive MatrixError
  """
  A Matrix error body. `errcode` is what clients branch on; `error` is for a
  person reading a log or a dialog.
  """
  fun apply(errcode: String, message: String): String =>
    JsonPrinter.print(JsonObject
      .update("errcode", errcode)
      .update("error", message))

primitive LoginSuccess
  """
  The body of a successful `POST /_matrix/client/v3/login`.

  `home_server` is deprecated in the specification and still read by Element
  1.12.25, which is the client marilwyd ships.
  """
  fun apply(
    user_id: String,
    access_token': String,
    device_id': String,
    server_name': String)
    : String
  =>
    JsonPrinter.print(JsonObject
      .update("user_id", user_id)
      .update("access_token", access_token')
      .update("device_id", device_id')
      .update("home_server", server_name'))

primitive WhoamiSuccess
  """
  The body of `GET /_matrix/client/v3/account/whoami`.

  `device_id` is optional in the specification and reported here. A client
  that holds a token but not the login response it arrived in has no other
  way to learn which of an account's sessions the token belongs to.
  """
  fun apply(user_id: String, device: DeviceId): String =>
    JsonPrinter.print(JsonObject
      .update("user_id", user_id)
      .update("device_id", device.string()))

primitive ExpiredToken
  """
  The body for a token that is not live, where the caller was trying to
  stop being signed in.

  `UnknownToken` without `soft_logout`. That flag asks a client to sign in
  again and keep its local state, which is right when a session ended
  underneath a client and wrong when the client asked for it to end.
  """
  fun apply(): String =>
    MatrixError("M_UNKNOWN_TOKEN", "Unrecognised access token")

primitive DeviceList
  """
  The body of `GET /_matrix/client/v3/devices`.

  Only `device_id` is required of each entry. marilwyd records no display
  name, no last-seen address and no last-seen time, so it reports none:
  login ignores `initial_device_display_name`, and inventing values a
  client would show to a person is worse than an unnamed session.
  """
  fun apply(found: Array[DeviceId] val): String =>
    var listed = JsonArray
    for device in found.values() do
      listed = listed.push(JsonObject.update("device_id", device.string()))
    end
    JsonPrinter.print(JsonObject.update("devices", listed))

primitive RoomCreated
  """
  The body of `createRoom`, and of joining or leaving one.

  All three answer with the room's id, which is what the specification
  gives each of them.
  """
  fun apply(room: RoomId): String =>
    JsonPrinter.print(JsonObject.update("room_id", room.string()))

primitive EventSent
  """
  The body of a successful send.
  """
  fun apply(id: EventId): String =>
    JsonPrinter.print(JsonObject.update("event_id", id.string()))

primitive StateEvents
  """
  The body of `GET /rooms/{roomId}/state` — a bare array of state events.
  """
  fun apply(events: Array[RoomEvent] val): String =>
    recover val
      let out = String(256 * (events.size() + 1))
      out.append("[")
      var first = true
      for event in events.values() do
        if not first then
          out.append(",")
        end
        first = false
        out.append(event.render())
      end
      out.append("]")
      out
    end

primitive LogoutSuccess
  """
  The body of `POST /_matrix/client/v3/logout` and of deleting devices.

  The specification defines an empty object for both; there is nothing a
  client needs beyond the status.
  """
  fun apply(): String => JsonPrinter.print(JsonObject)

primitive SyncDocument
  """
  The body of `GET /_matrix/client/v3/sync`.

  An empty view renders `next_batch` and nothing else. `rooms` and
  `to_device` are both omitted when there is nothing in them.

  Omitting `to_device` matters more than it looks. matrix-js-sdk pins
  `timeout=0` while it believes it is catching up, and clears that only on
  a sync whose `to_device.events` is absent or empty — so a block that is
  never empty holds a client in a hot loop. Driven end to end, a block
  emitted on every sync and a block emitted only when it has something both
  behave: five syncs in eighty-four seconds either way. What must not
  happen is a message that is delivered and never acknowledged, which is
  what would make the block permanent.

  Events arrive in the order a device was given them, across every room it
  is in, and are grouped by room here because that is the shape a client
  reads.
  """
  fun apply(view: SyncView): String =>
    recover val
      let grouped = Map[String, Array[RoomEvent]]
      for event in view.events.values() do
        let key: String = event.room.string()
        try
          grouped(key)?.push(event)
        else
          let fresh = Array[RoomEvent]
          fresh.push(event)
          grouped(key) = fresh
        end
      end
      // A room whose only news is state still needs an entry, or a client
      // is told about a room it has never heard of.
      for event in view.state.values() do
        let key: String = event.room.string()
        if not grouped.contains(key) then
          grouped(key) = Array[RoomEvent]
        end
      end

      let out = String(512)
      out.append("{\"next_batch\":")
      out.append(JsonPrinter.print(view.next_batch))
      if view.account.size() > 0 then
        out.append(",\"account_data\":{\"events\":[")
        var account_first = true
        for datum in view.account.values() do
          if not account_first then
            out.append(",")
          end
          account_first = false
          out.append(datum.render())
        end
        out.append("]}")
      end
      if view.to_device.size() > 0 then
        out.append(",\"to_device\":{\"events\":[")
        var to_device_first = true
        for message in view.to_device.values() do
          if not to_device_first then
            out.append(",")
          end
          to_device_first = false
          out.append(message.render())
        end
        out.append("]}")
      end
      if grouped.size() > 0 then
        out.append(",\"rooms\":{\"join\":{")
        var first = true
        for (room_id, events) in grouped.pairs() do
          if not first then
            out.append(",")
          end
          first = false
          out.append(JsonPrinter.print(room_id))

          out.append(":{\"state\":{\"events\":[")
          var state_first = true
          for event in view.state.values() do
            let key: String = event.room.string()
            if key == room_id then
              if not state_first then
                out.append(",")
              end
              state_first = false
              out.append(event.render())
            end
          end

          out.append("]},\"timeline\":{\"events\":[")
          var line_first = true
          for event in events.values() do
            if not line_first then
              out.append(",")
            end
            line_first = false
            out.append(event.render())
          end
          out.append("],\"limited\":false}}")
        end
        out.append("}}")
      end
      out.append("}")
      out
    end

primitive PushRules
  """
  `GET /_matrix/client/v3/pushrules/`.

  An empty ruleset, with every rule kind present. matrix-js-sdk awaits this
  inside `SyncApi.sync()` before it will issue a first `/sync`, and retries
  forever on any errcode but `M_UNKNOWN_TOKEN` — so while this was missing,
  the sync loop never started and the client re-asked every four seconds.

  The five kinds are listed rather than omitted because the client indexes
  into them; an absent kind and an empty one are not the same to a rules
  evaluator.
  """
  fun apply(): String =>
    let kinds = JsonObject
      .update("content", JsonArray)
      .update("override", JsonArray)
      .update("room", JsonArray)
      .update("sender", JsonArray)
      .update("underride", JsonArray)

    JsonPrinter.print(JsonObject.update("global", kinds))

primitive FilterCreated
  """
  The body of `POST /_matrix/client/v3/user/{userId}/filter`.

  The other endpoint matrix-js-sdk awaits before its first `/sync`. The
  request body is not read: no filter can change an empty set of events.

  A constant id, and clients store it. The matching `GET` exists because a
  returning client sends the stored id back before deciding what to do with
  it, and matrix-js-sdk rethrows any errcode there other than `M_UNKNOWN`
  or `M_NOT_FOUND` — so answering `M_UNRECOGNIZED` would strand it.

  It will not reuse the filter, whatever this returns: reuse needs the
  stored definition to match the one being requested, and element-web asks
  for `lazy_load_members` unconditionally while `EmptyFilter` answers `{}`.
  Every session creates another. Harmless while the id is a constant.
  """
  fun apply(): String =>
    JsonPrinter.print(JsonObject.update("filter_id", "0"))

primitive EmptyFilter
  """
  The body of `GET /_matrix/client/v3/user/{userId}/filter/{filterId}`.

  An empty filter, returned for every id. matrix-js-sdk rethrows any
  errcode here other than `M_UNKNOWN` or `M_NOT_FOUND`, so answering a
  cached id with `M_UNRECOGNIZED` would deadlock a returning client.

  Answering 200 to every id means the `M_NOT_FOUND` a real implementation
  owes an unknown filter is unreachable from here. That is the trigger for
  giving filters storage rather than a constant.
  """
  fun apply(): String => JsonPrinter.print(JsonObject)

primitive MissingToken
  """
  The body for a request to an authenticated endpoint that offered no token.

  Distinct from `UnknownToken`: nothing was presented, so there is no session
  to report as gone and no `soft_logout` to offer.
  """
  fun apply(): String =>
    MatrixError("M_MISSING_TOKEN", "Missing access token")

primitive UnknownToken
  """
  The body for a token marilwyd does not recognise.

  `soft_logout` tells the client its credentials are still good and only the
  session is gone, so it offers to sign in again rather than discarding
  local state. Every marilwyd restart puts every client in exactly that
  position, because sessions are held in memory.
  """
  fun apply(): String =>
    JsonPrinter.print(JsonObject
      .update("errcode", "M_UNKNOWN_TOKEN")
      .update("error", "Unrecognised access token")
      .update("soft_logout", true))

primitive AliasResolved
  """
  The body of `GET /_matrix/client/v3/directory/room/{roomAlias}`.

  `servers` names this server alone. It is the list of servers a client
  should try when joining, and marilwyd federates with none.
  """
  fun apply(room_id: String, server_name: String): String =>
    "{\"room_id\":" + JsonPrinter.print(room_id)
      + ",\"servers\":[" + JsonPrinter.print(server_name) + "]}"

primitive PublicRooms
  """
  The body of `publicRooms`.

  `total_room_count_estimate` is the exact count rather than an estimate,
  because every published room is in the chunk — there is no next page to
  make it an estimate of. `next_batch` is absent for the same reason: a
  client reads its absence as the end of the directory, which it is.
  """
  fun apply(rooms: Array[RoomSummary] val): String =>
    recover val
      let out = String(256)
      out.append("{\"chunk\":[")
      var first = true
      for summary in rooms.values() do
        if not first then
          out.append(",")
        end
        first = false
        out.append(summary.render())
      end
      out.append("],\"total_room_count_estimate\":")
      out.append(rooms.size().string())
      out.append("}")
      out
    end
