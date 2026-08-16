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
  """
  fun apply(user_id: String): String =>
    JsonPrinter.print(JsonObject.update("user_id", user_id))

primitive EmptySync
  """
  The body of a `/sync` that has nothing to report.

  `next_batch` is a constant because there is no event stream for it to
  point into. A client sends it back as `since` and marilwyd ignores it.
  The day events exist is the day this becomes a real stream position —
  and note that clients keep it in durable storage, so a value minted now
  comes back after a restart.

  Every other key the specification defines here is optional. Validated
  against **Element 1.12.25 with no rooms**: it drives its sync loop from
  this document alone and never enters an error state. Adding
  `rooms`/`presence`/`account_data` changed nothing, so they are not here.
  Re-check when the Element version changes, or when there are rooms.
  """
  fun apply(): String =>
    JsonPrinter.print(JsonObject.update("next_batch", "s0"))

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

  A constant id, and clients store it. `getOrCreateFilter` sends it back
  on a later load rather than creating another, which is why the matching
  `GET` exists at all.
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
