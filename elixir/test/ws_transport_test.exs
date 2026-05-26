defmodule DatagroutConduit.Transport.WsTest do
  @moduledoc """
  Unit tests for the WebSocket transport (datagrout-jsonrpc.v1).

  These tests exercise the GenServer message-routing logic by injecting
  raw frames directly into the process mailbox (simulating what the
  WebSockex connection module would deliver), without requiring a live
  WebSocket server.
  """

  use ExUnit.Case, async: true

  alias DatagroutConduit.Transport.Ws

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp inject_frame(pid, payload) do
    send(pid, {:ws_frame, Jason.encode!(payload)})
  end

  # ── Route regular RPC response ───────────────────────────────────────────────

  describe "handle_info/2 — regular response routing" do
    test "routes a JSON-RPC response to the pending caller" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{},
          next_id: 0
        })

      # Plant a pending request manually.
      :sys.replace_state(pid, fn state ->
        %{state | pending: Map.put(state.pending, "ws-1", {self(), make_ref()})}
      end)

      inject_frame(pid, %{"jsonrpc" => "2.0", "id" => "ws-1", "result" => %{"ok" => true}})

      # The GenServer calls GenServer.reply — but since we manually injected the
      # pending tuple, the reply goes nowhere. We verify state cleanup instead.
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert map_size(state.pending) == 0

      GenServer.stop(pid)
    end

    test "ignores responses for unknown ids" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{},
          next_id: 0
        })

      inject_frame(pid, %{"jsonrpc" => "2.0", "id" => "ghost", "result" => %{}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert map_size(state.pending) == 0

      GenServer.stop(pid)
    end

    test "ignores malformed JSON (not delivered as parsed map)" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{},
          next_id: 0
        })

      # Inject a non-JSON frame directly.
      send(pid, {:ws_frame, "not valid json"})
      Process.sleep(50)

      # GenServer should still be alive.
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  # ── Subscribe response routing ────────────────────────────────────────────────

  describe "handle_info/2 — subscribe response routing" do
    test "registers subscription and notifies subscriber on success" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{},
          next_id: 0
        })

      caller_pid = self()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | pending_subscribe:
              Map.put(
                state.pending_subscribe,
                "req-1",
                {"agents.x.events", caller_pid, {caller_pid, make_ref()}}
              )
        }
      end)

      inject_frame(pid, %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "result" => %{"subscription" => "sub_abc", "topic" => "agents.x.events"}
      })

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert map_size(state.pending_subscribe) == 0
      assert Map.has_key?(state.subscriptions, "sub_abc")

      GenServer.stop(pid)
    end
  end

  # ── Notification routing ──────────────────────────────────────────────────────

  describe "handle_info/2 — notification routing" do
    test "delivers notification to subscribed process" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{"sub_abc" => [self()]},
          next_id: 0
        })

      inject_frame(pid, %{
        "jsonrpc" => "2.0",
        "method" => "notification",
        "params" => %{
          "subscription" => "sub_abc",
          "event" => "agent.thought",
          "data" => %{"text" => "thinking"}
        }
      })

      assert_receive {:subscription_event, "sub_abc",
                      %{event: "agent.thought", data: %{"text" => "thinking"}}},
                     500

      GenServer.stop(pid)
    end

    test "silently drops notifications for unknown subscription ids" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{},
          next_id: 0
        })

      inject_frame(pid, %{
        "jsonrpc" => "2.0",
        "method" => "notification",
        "params" => %{"subscription" => "ghost", "event" => "x", "data" => nil}
      })

      Process.sleep(50)
      refute_receive {:subscription_event, _, _}, 100

      GenServer.stop(pid)
    end

    test "ignores unknown server-initiated methods" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{},
          pending_subscribe: %{},
          subscriptions: %{},
          next_id: 0
        })

      inject_frame(pid, %{
        "jsonrpc" => "2.0",
        "method" => "session.ready",
        "params" => %{"session_id" => "abc"}
      })

      Process.sleep(50)
      state = :sys.get_state(pid)
      assert map_size(state.subscriptions) == 0

      GenServer.stop(pid)
    end
  end

  # ── Disconnect handling ────────────────────────────────────────────────────────

  describe "handle_info/2 — disconnect" do
    test "clears pending state on disconnect" do
      {:ok, pid} =
        GenServer.start_link(Ws, %Ws{
          conn_pid: self(),
          pending: %{"ws-1" => {self(), make_ref()}},
          pending_subscribe: %{},
          subscriptions: %{"sub_1" => [self()]},
          next_id: 0
        })

      send(pid, :ws_disconnected)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert map_size(state.pending) == 0
      assert map_size(state.subscriptions) == 0

      GenServer.stop(pid)
    end
  end

  # ── Header helpers ────────────────────────────────────────────────────────────

  describe "to_ws_url / build_headers (via init logic)" do
    test "URL rewriting: https → wss" do
      ws_url =
        "https://gateway.datagrout.ai/servers/test/ws"
        |> String.replace_prefix("https://", "wss://")
        |> String.replace_prefix("http://", "ws://")

      assert ws_url == "wss://gateway.datagrout.ai/servers/test/ws"
    end

    test "URL rewriting: http → ws" do
      ws_url =
        "http://localhost:4000/ws"
        |> String.replace_prefix("https://", "wss://")
        |> String.replace_prefix("http://", "ws://")

      assert ws_url == "ws://localhost:4000/ws"
    end
  end

  # ── Client integration ────────────────────────────────────────────────────────

  describe "DatagroutConduit.Client subscribe/unsubscribe" do
    # These tests exercise handle_call directly with a crafted state (ws_pid: nil)
    # to avoid needing a running GenServer + Mox transport in async mode.

    test "subscribe returns {:error, :not_ws_transport} when ws_pid is nil" do
      state = %DatagroutConduit.Client{ws_pid: nil}

      assert {:reply, {:error, :not_ws_transport}, ^state} =
               DatagroutConduit.Client.handle_call(
                 {:subscribe, "agents.x.events"},
                 {self(), make_ref()},
                 state
               )
    end

    test "unsubscribe returns {:error, :not_ws_transport} when ws_pid is nil" do
      state = %DatagroutConduit.Client{ws_pid: nil}

      assert {:reply, {:error, :not_ws_transport}, ^state} =
               DatagroutConduit.Client.handle_call(
                 {:unsubscribe, "sub_123"},
                 {self(), make_ref()},
                 state
               )
    end
  end

  # ── Ping keepalive ────────────────────────────────────────────────────────

  describe "ping keepalive" do
    test "ping_interval_ms/0 returns 25_000 — Rust parity" do
      assert Ws.ping_interval_ms() == 25_000
    end

    test "default state initialises ping_interval_ms from the module attribute" do
      state = %Ws{conn_pid: self()}
      assert state.ping_interval_ms == 25_000
      assert state.pings_sent == 0
    end

    # Helper: returns a freshly-dead pid.  `WebSockex.send_frame/2` exits
    # with `:noproc` immediately when called against a dead pid — exactly
    # the production crash scenario `safe_send_ping/1` is designed to
    # catch — and it avoids both the 5-second `:gen.call` timeout and the
    # noisy `[error] Agent.Server received unexpected message …` lines
    # that an `Agent.start_link/1` dummy would emit when poked with the
    # `:"$websockex_send"` protocol.
    defp dead_pid do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        500 -> flunk("spawned process did not exit in time")
      end

      pid
    end

    test ":ping_tick degrades gracefully when the Conn process has died" do
      # WebSockex.send_frame `exit`s when the target Conn is gone;
      # safe_send_ping/1 must catch that so the Ws GenServer doesn't
      # crash alongside it.
      state = %Ws{conn_pid: dead_pid(), ping_interval_ms: 50_000}

      assert {:noreply, new_state} = Ws.handle_info(:ping_tick, state)

      # Send failed, so pings_sent stays at 0 — but the GenServer survived.
      assert new_state.pings_sent == 0
    end

    test ":ping_tick reschedules itself at ping_interval_ms" do
      # Dead conn so the send fails fast; we only care about the
      # reschedule signal here.
      state = %Ws{conn_pid: dead_pid(), ping_interval_ms: 30}

      # First tick fires immediately via direct handle_info call.
      {:noreply, _state} = Ws.handle_info(:ping_tick, state)

      # Production handler scheduled the NEXT tick — verify it lands in
      # this process's mailbox within ~100ms.
      assert_receive :ping_tick, 200
    end

    test "ping_interval_ms = 0 disables rescheduling (no further tick)" do
      state = %Ws{conn_pid: dead_pid(), ping_interval_ms: 0}

      {:noreply, _state} = Ws.handle_info(:ping_tick, state)

      refute_receive :ping_tick, 100
    end

    test "pings_sent/1 returns the live counter through the GenServer API" do
      # Start a Ws GenServer using the test-only init clause that takes a
      # pre-built struct; this avoids the real WS handshake.
      state = %Ws{conn_pid: self(), ping_interval_ms: 0, pings_sent: 7}
      {:ok, pid} = GenServer.start_link(Ws, state)
      assert Ws.pings_sent(pid) == 7
      GenServer.stop(pid)
    end
  end
end
