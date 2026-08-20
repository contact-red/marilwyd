use "files"
use "ssl/net"
use irc = "irc"

primitive Connect
  """
  Open one network's connection, or say why it cannot be opened.

  Separate from `Main` because the TLS decision belongs somewhere a person
  can find it. The `irc` package gives it no default — its own reasoning is
  that the choice decides whether a password is readable in transit — so
  marilwyd makes it from the configuration and nowhere else.
  """
  fun apply(
    env: Env,
    network: BridgedNetwork,
    notify: irc.IRCNotify tag,
    nicks': (Array[String] val | None) = None)
    : (irc.IRC | StartupError)
  =>
    let tls: irc.TLS =
      if network.tls then
        // Verification on, with an authority to verify against. Both
        // halves are needed and neither is a default: `SSLContext` starts
        // with verification off, and on anything but Windows it will not
        // load the system roots by itself — so a context built without
        // this either authenticates nobody or fails every handshake.
        match \exhaustive\ _Authority(env)
        | let store: FilePath =>
          try
            _TrustingContext(store)?
          else
            // The load is checked. Verification is on, so a store that
            // did not load leaves a context trusting nobody: every
            // handshake fails and nothing says why. Refusing here names
            // the file instead.
            return StartupError(
              "bridge-tls-authority",
              "the certificate authorities for " + network.name
                + " could not be loaded from " + store.path)
          end
        | None =>
          return StartupError(
            "bridge-tls-authority",
            "no certificate authorities were found for " + network.name
              + "; looked for " + _Authority.locations())
        end
      else
        // Named, not defaulted. A bridge relaying a room to a network in
        // the clear is worth an operator having written down.
        irc.NoTLS
      end

    let config =
      match \exhaustive\ irc.IRCConfigs(
        env.root,
        network.host,
        network.service,
        tls,
        match nicks'
        | let wanted: Array[String] val => wanted
        else
          network.nicks
        end,
        "marilwyd",
        "marilwyd bridge")
      | let c: irc.IRCConfig val => c
      | let e: irc.ConfigError =>
        return StartupError(
          "bridge-config", network.name + ": " + e.string())
      end

    irc.IRC(config, notify)

primitive _Authority
  """
  The certificate store a TLS connection verifies against.

  Named here rather than left to the library because there is nothing to
  leave it to: OpenSSL loads no roots unless told, and the file this wants
  lives in a different place on every distribution. Probed rather than
  configured, because an operator who has to name their CA bundle to bridge
  a channel has been given a worse job than the one they asked for.
  """
  fun locations(): String =>
    "/etc/ssl/certs/ca-certificates.crt, /etc/pki/tls/certs/ca-bundle.crt"

  fun apply(env: Env): (FilePath | None) =>
    let caps =
      recover val
        FileCaps .> set(FileLookup) .> set(FileRead) .> set(FileStat)
      end
    for candidate in
      [ "/etc/ssl/certs/ca-certificates.crt"
        "/etc/pki/tls/certs/ca-bundle.crt" ].values()
    do
      let path = FilePath(FileAuth(env.root), candidate, caps)
      if path.exists() then
        return path
      end
    end
    None

primitive _TrustingContext
  """
  An SSL context that verifies its peer against `store`, or nothing.

  Both halves matter and neither is a default: `SSLContext` starts with
  verification off, and on anything but Windows it will not load the
  system roots by itself. A context with one half is worse than a context
  with neither, because it fails every handshake rather than obviously
  doing nothing.
  """
  fun apply(store: FilePath): SSLContext val ? =>
    recover val
      SSLContext
        .> set_client_verify(true)
        .> set_authority(store)?
    end
