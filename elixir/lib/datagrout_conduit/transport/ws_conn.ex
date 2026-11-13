defmodule DatagroutConduit.Transport.Ws.Conn do
  @moduledoc false

  # Low-level WebSocket connection process using WebSockex.
  # Forwards incoming text frames to the parent WS GenServer.

  use WebSockex

  alias DatagroutConduit.TLS

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
  # Every `wss://` connection carries explicit `:ssl_options`. WebSockex's own
  # default is `insecure: true` — no peer verification at all — which neither the
  # Finch-backed HTTP transports nor the Rust reference (`build_connector`, webpki
  # roots) ever accept. Supplying `:ssl_options` replaces that default, so the
  # trust store, SNI and hostname check are named here for identity-less and
  # identity-carrying connections alike; an mTLS identity additionally presents
  # its cert and key, and its CA joins the public roots (see `TLS`).
  @doc false
  def build_ws_opts(url, headers, identity) do
    base = [extra_headers: headers, handle_initial_conn_failure: true]

    case ssl_options(url, identity) do
      [] -> base
      ssl_opts -> Keyword.put(base, :ssl_options, ssl_opts)
    end
  end

  defp ssl_options("wss://" <> _ = url, identity) do
    [
      verify: :verify_peer,
      depth: 3,
      server_name_indication: String.to_charlist(URI.parse(url).host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
    |> Keyword.merge(TLS.identity_opts(identity))
    |> default_trust()
  end

  defp ssl_options(_url, _identity), do: []

  # Passing `:ssl_options` replaces WebSockex's own TLS defaults, so without an
  # identity CA the trust store still has to be named: the same CA bundle the
  # Finch-backed transports verify against.
  defp default_trust(opts) do
    if Keyword.has_key?(opts, :cacerts),
      do: opts,
      else: Keyword.put(opts, :cacertfile, CAStore.file_path())
  end

  # ── WebSockex callbacks ────────────────────────────────────────────────────

  @impl WebSockex
  def handle_frame({:text, msg}, %{parent: parent} = state) do
    send(parent, {:ws_frame, msg})
    {:ok, state}
  end

  def handle_frame({:binary, _}, state), do: {:ok, state}
  def handle_frame({:ping, _}, state), do: {:ok, state}

  def handle_frame({:pong, _}, %{parent: parent} = state) do
    send(parent, :ws_pong)
    {:ok, state}
  end

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
