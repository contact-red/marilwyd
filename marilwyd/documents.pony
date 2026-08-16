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

  `home_server` is deprecated in the spec but still read by clients in the
  wild, and costs one field.
  """
  fun apply(
    user_id: String,
    access_token: String,
    device_id: String,
    server_name: String)
    : String
  =>
    JsonPrinter.print(JsonObject
      .update("user_id", user_id)
      .update("access_token", access_token)
      .update("device_id", device_id)
      .update("home_server", server_name))

primitive WhoamiSuccess
  """
  The body of `GET /_matrix/client/v3/account/whoami`.
  """
  fun apply(user_id: String): String =>
    JsonPrinter.print(JsonObject.update("user_id", user_id))
