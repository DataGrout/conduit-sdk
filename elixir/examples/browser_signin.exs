# Browser-consent sign-in with OAuth 2.1 authorization code + PKCE.
#
# Run once and it prints a consent URL, captures the redirect on 127.0.0.1, and
# writes the grant to disk. Run again and it reuses what it saved.
#
#     mix run examples/browser_signin.exs
#
# Two things this example exists to demonstrate, both of which are easy to get
# wrong and only fail later:
#
#  1. The registered client id is persisted *with its redirect URI*, and the
#     listener re-binds that exact port on the next run. Authorization servers
#     match redirect URIs exactly, with no loopback-port exemption.
#  2. DataGrout rotates refresh tokens, so a refreshed grant is written back. A
#     grant that is refreshed and not persisted leaves a consumed token on disk,
#     and the next run fails with `invalid_grant`.

alias DatagroutConduit.AuthCode

defmodule BrowserSignin do
  @gateway "https://gateway.datagrout.ai/connect"

  # Where this example keeps its credentials.
  #
  # A file, and deliberately called out as such: it holds a refresh token, which
  # is a long-lived credential. A real application should prefer the OS keychain
  # or a vault. The SDK does not choose for you.
  @store Path.join([System.user_home!(), ".config", "conduit-example", "signin.json"])

  def gateway, do: @gateway

  def load do
    with {:ok, raw} <- File.read(@store),
         {:ok, saved} <- Jason.decode(raw) do
      {AuthCode.RegisteredClient.from_map(saved["registered"]),
       AuthCode.Grant.from_map(saved["grant"])}
    else
      _ -> nil
    end
  end

  def save(registered, grant) do
    File.mkdir_p!(Path.dirname(@store))

    File.write!(
      @store,
      Jason.encode!(
        %{
          "registered" => AuthCode.RegisteredClient.to_map(registered),
          "grant" => AuthCode.Grant.to_map(grant)
        },
        pretty: true
      )
    )

    File.chmod!(@store, 0o600)
    @store
  end

  # Run the full consent flow and return something worth persisting.
  def sign_in(existing \\ nil) do
    # Bind first: the real port has to be known before the redirect URI is
    # registered. Reusing a saved registration means re-binding its exact port.
    listener = bind_listener(existing)

    {:ok, flow} = AuthCode.discover(@gateway)

    # A saved registration is only reusable if the listener came back on its
    # port; otherwise register anew rather than authorize against a URI the
    # server will reject.
    redirect_uri = AuthCode.Loopback.redirect_uri(listener)

    {registered, flow} =
      if existing && redirect_uri == existing.redirect_uri do
        {existing, AuthCode.with_registered_client(flow, existing)}
      else
        {:ok, registered, flow} = AuthCode.register(flow, "Conduit Example", redirect_uri)
        {registered, flow}
      end

    {:ok, url, pending} = AuthCode.authorize_url(flow)
    IO.puts("\nOpen this URL to sign in:\n\n  #{url}\n")

    {:ok, redirect} = AuthCode.Loopback.wait(listener, 300_000)
    {:ok, grant} = AuthCode.exchange(flow, pending, redirect.code, redirect.state)

    {registered, grant}
  end

  defp bind_listener(nil) do
    {:ok, listener} = AuthCode.Loopback.bind()
    listener
  end

  defp bind_listener(existing) do
    case AuthCode.Loopback.bind_for(existing.redirect_uri) do
      {:ok, listener} ->
        listener

      {:error, _} ->
        IO.puts("port for #{existing.redirect_uri} is taken — registering a fresh client")
        bind_listener(nil)
    end
  end
end

{registered, grant} =
  case BrowserSignin.load() do
    nil ->
      {registered, grant} = BrowserSignin.sign_in()
      path = BrowserSignin.save(registered, grant)
      IO.puts("signed in; credentials written to #{path}")
      {registered, grant}

    saved ->
      IO.puts("using the saved sign-in")
      saved
  end

# Own the provider so a rotated refresh token can be written back.
{:ok, provider} = AuthCode.Provider.start_link(grant: grant)

{:ok, client} =
  DatagroutConduit.Client.start_link(
    url: BrowserSignin.gateway(),
    auth: {:authorization_code, provider}
  )

try do
  {:ok, tools} = DatagroutConduit.Client.list_tools(client)
  IO.puts("\n#{length(tools)} tools available on this server:")
  tools |> Enum.take(5) |> Enum.each(&IO.puts("  - #{&1.name}"))
after
  case AuthCode.Provider.take_if_dirty(provider) do
    {:ok, rotated} ->
      BrowserSignin.save(registered, rotated)
      IO.puts("\n(the grant was refreshed and re-saved)")

    :clean ->
      :ok
  end
end
