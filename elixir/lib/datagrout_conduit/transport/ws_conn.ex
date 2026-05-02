defmodule DatagroutConduit.Transport.Ws.Conn do
  @moduledoc false

  # Low-level WebSocket connection process using WebSockex.
  # Forwards incoming text frames to the parent WS GenServer.

  use WebSockex

  @doc false
  def start_link(url, opts) do
    parent = Keyword.fetch!(opts, :parent)
    headers = Keyword.get(opts, :headers, [])
    _identity = Keyword.get(opts, :identity)

    ws_opts = [
      extra_headers: headers,
      handle_initial_conn_failure: true
    ]

    WebSockex.start_link(url, __MODULE__, %{parent: parent}, ws_opts)
  end

  @doc "Send a text or binary frame over the WebSocket."
  def send_frame(pid, frame), do: WebSockex.send_frame(pid, frame)

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
