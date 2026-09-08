defmodule DatagroutConduit.Transport.Ws.Conn do
  @moduledoc false

  # Low-level WebSocket connection process using WebSockex.
  # Forwards incoming text frames to the parent WS GenServer.

  use WebSockex

  @doc false
  def start_link(url, opts) do
    parent = Keyword.fetch!(opts, :parent)
    headers = Keyword.get(opts, :headers, [])
    identity = Keyword.get(opts, :identity)

    WebSockex.start_link(
      url,
      __MODULE__,
      %{parent: parent},
      build_ws_opts(url, headers, identity)
    )
  end

  @doc "Send a text or binary frame over the WebSocket."
  def send_frame(pid, frame), do: WebSockex.send_frame(pid, frame)

  # ── Connection options ─────────────────────────────────────────────────────

  # Public so the options can be asserted on without opening a socket.
  #
  # An mTLS identity rides the `wss://` handshake as WebSockex `:ssl_options`,
  # which it merges into the `:ssl.connect/4` options. The HTTP transports hand
  # the same identity to Finch as `transport_opts`; this previously discarded it,
  # so a WS connection presented no client certificate. Mirrors `build_connector`
  # in the Rust reference: present the cert, and trust the identity's CA when it
  # has one.
  @doc false
  def build_ws_opts(url, headers, identity) do
    base = [extra_headers: headers, handle_initial_conn_failure: true]

    case ssl_options(url, identity) do
      [] -> base
      ssl_opts -> Keyword.put(base, :ssl_options, ssl_opts)
    end
  end

  defp ssl_options("wss://" <> _ = url, %DatagroutConduit.Identity{} = identity) do
    [
      verify: :verify_peer,
      depth: 3,
      server_name_indication: String.to_charlist(URI.parse(url).host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
    |> Keyword.merge(trust_store(identity))
    |> maybe_add(:certfile, identity.cert_path)
    |> maybe_add(:keyfile, identity.key_path)
    |> maybe_add_pem(:cert, identity.cert_pem)
    |> maybe_add_pem(:key, identity.key_pem)
  end

  defp ssl_options(_url, _identity), do: []

  # Passing `:ssl_options` replaces WebSockex's own TLS defaults, so the trust
  # store has to be named here: the identity's CA when it has one, otherwise the
  # same CA bundle the Finch-backed transports verify against.
  defp trust_store(%{ca_path: ca_path}) when is_binary(ca_path), do: [cacertfile: ca_path]

  defp trust_store(%{ca_pem: ca_pem}) when is_binary(ca_pem) do
    case maybe_add_pem([], :cacerts, ca_pem) do
      [] -> [cacertfile: CAStore.file_path()]
      opts -> opts
    end
  end

  defp trust_store(_identity), do: [cacertfile: CAStore.file_path()]

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_pem(opts, _key, nil), do: opts

  defp maybe_add_pem(opts, :cert, pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] -> Keyword.put(opts, :cert, [{:Certificate, der}])
      _ -> opts
    end
  end

  defp maybe_add_pem(opts, :key, pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, _} | _] -> Keyword.put(opts, :key, {type, der})
      _ -> opts
    end
  end

  defp maybe_add_pem(opts, :cacerts, pem) do
    certs =
      :public_key.pem_decode(pem)
      |> Enum.filter(fn {type, _, _} -> type == :Certificate end)
      |> Enum.map(fn {:Certificate, der, _} -> der end)

    if certs != [], do: Keyword.put(opts, :cacerts, certs), else: opts
  end

  # ── WebSockex callbacks ────────────────────────────────────────────────────

  @impl WebSockex
  def handle_frame({:text, msg}, %{parent: parent} = state) do
    send(parent, {:ws_frame, msg})
    {:ok, state}
  end

  def handle_frame({:binary, _}, state), do: {:ok, state}
  def handle_frame({:ping, _}, state), do: {:ok, state}
  def handle_frame({:pong, _}, state), do: {:ok, state}

  def handle_frame({:close, _, _}, %{parent: parent} = state) do
    send(parent, :ws_disconnected)
    {:ok, state}
  end

  @impl WebSockex
  def handle_disconnect(_conn_status, %{parent: parent} = state) do
    send(parent, :ws_disconnected)
    {:ok, state}
  end
end
