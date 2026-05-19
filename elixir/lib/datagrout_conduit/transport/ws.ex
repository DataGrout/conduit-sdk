defmodule DatagroutConduit.Transport.Ws do
  @moduledoc """
  WebSocket transport for `datagrout-jsonrpc.v1`.

  Manages a single `wss://` connection with concurrent JSON-RPC request
  multiplexing and server-push subscriptions.  Concurrent requests are
  correlated by JSON-RPC `id` with no head-of-line blocking.

  ## Usage

      {:ok, ws} = DatagroutConduit.Transport.Ws.start_link(
        url: "wss://gateway.datagrout.ai/servers/<uuid>/ws",
        auth: {:bearer, "token"}
      )

      {:ok, result} = DatagroutConduit.Transport.Ws.send_request(ws, "tools/list")

  ## Push subscriptions

  Subscribe to dotted-namespace topics and receive events as messages in the
  calling process's mailbox:

      {:ok, sub_id} = DatagroutConduit.Transport.Ws.subscribe(ws, "agents.my-agent-id.events")

      receive do
        {:subscription_event, ^sub_id, event} ->
          IO.inspect(event)
      end

      :ok = DatagroutConduit.Transport.Ws.unsubscribe(ws, sub_id)

  ## Wire protocol

  - Subprotocol: `datagrout-jsonrpc.v1`
  - Connect URL: `wss://<gateway>/servers/<uuid>/ws`
  - Frame format: JSON-RPC 2.0, text frames only
  - Auth: `Authorization: Bearer <token>` in the upgrade headers
  """

  use GenServer

  require Logger

  alias DatagroutConduit.Transport.Ws.Conn

  @subprotocol "datagrout-jsonrpc.v1"

  # ── State ──────────────────────────────────────────────────────────────────

  defstruct [
    :conn_pid,
    pending: %{},
    pending_subscribe: %{},
    # sub_id => [subscriber_pid]
    subscriptions: %{},
    next_id: 0
  ]

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Start a supervised WebSocket transport process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a JSON-RPC request over the WebSocket and wait for the response.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec send_request(GenServer.server(), String.t(), map() | nil, timeout()) ::
          {:ok, term()} | {:error, term()}
  def send_request(pid, method, params \\ nil, timeout \\ 30_000) do
    GenServer.call(pid, {:send_request, method, params}, timeout)
  end

  @doc """
  Subscribe to a dotted-namespace push topic.

  Events are delivered as `{:subscription_event, subscription_id, event}` messages
  to the calling process's mailbox, where `event` is a map with `:event` and
  `:data` keys.

  Returns `{:ok, subscription_id}` on success.
  """
  @spec subscribe(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe(pid, topic, timeout \\ 10_000) do
    GenServer.call(pid, {:subscribe, topic, self()}, timeout)
  end

  @doc """
  Cancel a server-side push subscription.

  Removes the subscription locally and notifies the server.
  Returns `:ok`.
  """
  @spec unsubscribe(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def unsubscribe(pid, subscription_id, timeout \\ 10_000) do
    GenServer.call(pid, {:unsubscribe, subscription_id}, timeout)
  end

  # ── GenServer init ─────────────────────────────────────────────────────────

  # Accept a pre-built %Ws{} struct directly — used in tests to inject state
  # without going through the real WebSocket connection setup.
  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    auth = Keyword.get(opts, :auth)
    identity = Keyword.get(opts, :identity)

    ws_url = to_ws_url(url)
    headers = build_headers(auth)

    conn_opts = [
      headers: headers,
      identity: identity,
      parent: self()
    ]

    case Conn.start_link(ws_url, conn_opts) do
      {:ok, conn_pid} ->
        {:ok, %__MODULE__{conn_pid: conn_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def handle_call({:send_request, method, params}, from, state) do
    {id, state} = next_id(state)
    frame = build_request(id, method, params)

    case send_frame(state.conn_pid, frame) do
      :ok ->
        pending = Map.put(state.pending, id, from)
        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, topic, caller_pid}, from, state) do
    {id, state} = next_id(state)
    frame = build_request(id, "subscribe", %{"topic" => topic})

    case send_frame(state.conn_pid, frame) do
      :ok ->
        pending = Map.put(state.pending_subscribe, id, {topic, caller_pid, from})
        {:noreply, %{state | pending_subscribe: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, sub_id}, _from, state) do
    # Remove local subscription immediately.
    state = %{state | subscriptions: Map.delete(state.subscriptions, sub_id)}

    {id, state} = next_id(state)
    frame = build_request(id, "unsubscribe", %{"subscription" => sub_id})

    case send_frame(state.conn_pid, frame) do
      :ok ->
        # Best-effort — don't wait for the ack.
        {:reply, :ok, state}

      {:error, _reason} ->
        {:reply, :ok, state}
    end
  end

  # ── Incoming frame routing ─────────────────────────────────────────────────

  @impl true
  def handle_info({:ws_frame, raw}, state) do
    state =
      case Jason.decode(raw) do
        {:ok, msg} -> handle_message(msg, state)
        {:error, _} -> state
      end

    {:noreply, state}
  end

  def handle_info(:ws_disconnected, state) do
    Logger.warning("[Ws] WebSocket disconnected — failing pending requests")
    reason = :disconnected

    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, reason})
    end

    for {_id, {_topic, _caller, from}} <- state.pending_subscribe do
      GenServer.reply(from, {:error, reason})
    end

    {:noreply, %{state | pending: %{}, pending_subscribe: %{}, subscriptions: %{}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Message routing ────────────────────────────────────────────────────────

  defp handle_message(%{"id" => nil} = msg, state),
    do: handle_message(Map.delete(msg, "id"), state)

  defp handle_message(%{"method" => "notification", "params" => params}, state)
       when not is_map_key(state, :id) do
    route_notification(params, state)
    state
  end

  defp handle_message(msg, state) when not is_map_key(msg, "id") do
    if msg["method"] == "notification" do
      route_notification(msg["params"] || %{}, state)
    end

    state
  end

  defp handle_message(%{"id" => id} = msg, state) do
    str_id = to_string(id)

    cond do
      Map.has_key?(state.pending_subscribe, str_id) ->
        {_topic, caller_pid, from} = Map.fetch!(state.pending_subscribe, str_id)
        pending_subscribe = Map.delete(state.pending_subscribe, str_id)

        if err = msg["error"] do
          GenServer.reply(from, {:error, err["message"] || "Subscribe failed"})
          %{state | pending_subscribe: pending_subscribe}
        else
          result = msg["result"] || %{}
          sub_id = result["subscription"] || str_id
          # Register the caller as a subscriber.
          subs = Map.update(state.subscriptions, sub_id, [caller_pid], &[caller_pid | &1])
          GenServer.reply(from, {:ok, sub_id})
          %{state | pending_subscribe: pending_subscribe, subscriptions: subs}
        end

      Map.has_key?(state.pending, str_id) ->
        from = Map.fetch!(state.pending, str_id)
        pending = Map.delete(state.pending, str_id)

        if err = msg["error"] do
          GenServer.reply(from, {:error, err["message"] || "RPC error"})
        else
          GenServer.reply(from, {:ok, msg["result"]})
        end

        %{state | pending: pending}

      true ->
        Logger.debug("[Ws] response for unknown id #{inspect(str_id)}")
        state
    end
  end

  defp route_notification(%{"subscription" => sub_id} = params, state) when is_binary(sub_id) do
    event = %{
      event: params["event"] || "",
      data: params["data"]
    }

    case Map.get(state.subscriptions, sub_id) do
      nil ->
        :ok

      pids ->
        for pid <- pids, Process.alive?(pid) do
          send(pid, {:subscription_event, sub_id, event})
        end
    end
  end

  defp route_notification(_params, _state), do: :ok

  # ── Internal helpers ───────────────────────────────────────────────────────

  defp next_id(%__MODULE__{next_id: n} = state) do
    {"ws-#{n + 1}", %{state | next_id: n + 1}}
  end

  defp build_request(id, method, params) do
    base = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if params, do: Map.put(base, "params", params), else: base
  end

  defp send_frame(conn_pid, frame) do
    case Jason.encode(frame) do
      {:ok, json} -> Conn.send_frame(conn_pid, {:text, json})
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_ws_url(url) do
    url
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
  end

  defp build_headers(nil), do: [{"sec-websocket-protocol", @subprotocol}]

  defp build_headers({:bearer, token}),
    do: [{"authorization", "Bearer #{token}"}, {"sec-websocket-protocol", @subprotocol}]

  defp build_headers({:api_key, key}),
    do: [{"x-api-key", key}, {"sec-websocket-protocol", @subprotocol}]

  defp build_headers({:basic, user, pass}) do
    encoded = Base.encode64("#{user}:#{pass}")
    [{"authorization", "Basic #{encoded}"}, {"sec-websocket-protocol", @subprotocol}]
  end

  defp build_headers({:oauth, provider_pid}) do
    token = GenServer.call(provider_pid, :get_token)
    [{"authorization", "Bearer #{token}"}, {"sec-websocket-protocol", @subprotocol}]
  end
end
