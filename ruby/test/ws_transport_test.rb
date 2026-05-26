# frozen_string_literal: true

require_relative "test_helper"

# Unit tests for DatagroutConduit::Transport::Ws
#
# These tests inject frames directly into the transport's handle_message method
# (via #send) and inspect state via instance_variable_get, bypassing the real
# WebSocket socket so no live server is needed.

class WsTransportTest < Minitest::Test
  # ── Helpers ───────────────────────────────────────────────────────────────

  # Build a Ws instance with @connected = true and a fake driver
  # (no real socket, no real WS handshake).
  def make_ws
    ws = DatagroutConduit::Transport::Ws.new(
      url: "wss://example.com/ws",
      auth: { bearer: "test-token" }
    )
    ws.instance_variable_set(:@connected, true)
    ws.instance_variable_set(:@next_id, 0)
    ws
  end

  # Directly invoke the private handle_message method.
  def inject(ws, payload)
    ws.send(:handle_message, JSON.generate(payload))
  end

  # Retrieve the private @pending map.
  def pending(ws)
    ws.instance_variable_get(:@pending)
  end

  def pending_subscribe(ws)
    ws.instance_variable_get(:@pending_subscribe)
  end

  def subscriptions(ws)
    ws.instance_variable_get(:@subscriptions)
  end

  # ── URL rewriting ─────────────────────────────────────────────────────────

  def test_url_rewrite_https_to_wss
    client = DatagroutConduit::Client.new(
      url: "https://gateway.datagrout.ai/servers/test/ws",
      auth: { bearer: "tok" },
      transport: :websocket
    )
    assert_equal "wss://gateway.datagrout.ai/servers/test/ws",
                 client.transport.instance_variable_get(:@url)
  end

  def test_url_rewrite_http_to_ws
    client = DatagroutConduit::Client.new(
      url: "http://localhost:4000/ws",
      auth: { bearer: "tok" },
      transport: :websocket
    )
    assert_equal "ws://localhost:4000/ws",
                 client.transport.instance_variable_get(:@url)
  end

  def test_url_already_wss_unchanged
    client = DatagroutConduit::Client.new(
      url: "wss://gateway.datagrout.ai/servers/test/ws",
      auth: { bearer: "tok" },
      transport: :websocket
    )
    assert_equal "wss://gateway.datagrout.ai/servers/test/ws",
                 client.transport.instance_variable_get(:@url)
  end

  # ── Connection guard ──────────────────────────────────────────────────────

  def test_send_request_raises_when_not_connected
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", auth: {})
    assert_raises(DatagroutConduit::NotInitializedError) { ws.send_request("tools/list") }
  end

  def test_subscribe_raises_when_not_connected
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", auth: {})
    assert_raises(DatagroutConduit::NotInitializedError) { ws.subscribe("agents.x.events") }
  end

  # ── Response routing — regular requests ──────────────────────────────────

  def test_routes_response_to_pending_caller
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    ws.instance_variable_get(:@mutex).synchronize do
      pending(ws)["ws-1"] = future
    end

    inject(ws, { "jsonrpc" => "2.0", "id" => "ws-1", "result" => { "tools" => [] } })

    result, value = future.wait(timeout: 1)
    assert_equal :ok, result
    assert_equal({ "tools" => [] }, value)
  end

  def test_routes_rpc_error_to_pending_caller
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    ws.instance_variable_get(:@mutex).synchronize do
      pending(ws)["ws-1"] = future
    end

    inject(ws, {
      "jsonrpc" => "2.0",
      "id"      => "ws-1",
      "error"   => { "code" => -32_601, "message" => "Method not found" }
    })

    result, value = future.wait(timeout: 1)
    assert_equal :error, result
    assert_includes value, "Method not found"
  end

  def test_clears_pending_after_response
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    ws.instance_variable_get(:@mutex).synchronize do
      pending(ws)["ws-2"] = future
    end

    inject(ws, { "jsonrpc" => "2.0", "id" => "ws-2", "result" => {} })
    future.wait(timeout: 1)

    assert_empty pending(ws)
  end

  def test_ignores_response_for_unknown_id
    ws = make_ws
    inject(ws, { "jsonrpc" => "2.0", "id" => "ghost", "result" => {} })
    assert_empty pending(ws)  # no crash, no state pollution
  end

  def test_ignores_malformed_json
    ws = make_ws
    ws.send(:handle_message, "not valid json{{{")
    assert_empty pending(ws)  # still alive, no error
  end

  def test_id_coercion_integer_ids
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    ws.instance_variable_get(:@mutex).synchronize do
      pending(ws)["42"] = future
    end

    # Server sends integer id — should still match string key "42"
    inject(ws, { "jsonrpc" => "2.0", "id" => 42, "result" => { "ok" => true } })

    result, _value = future.wait(timeout: 1)
    assert_equal :ok, result
  end

  # ── Subscribe response routing ────────────────────────────────────────────

  def test_subscribe_response_registers_subscription
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    ws.instance_variable_get(:@mutex).synchronize do
      pending_subscribe(ws)["req-1"] = { topic: "agents.x.events", future: future }
    end

    inject(ws, {
      "jsonrpc" => "2.0",
      "id"      => "req-1",
      "result"  => { "subscription" => "sub_abc", "topic" => "agents.x.events" }
    })

    result, value = future.wait(timeout: 1)
    assert_equal :ok, result
    assert_equal({ "subscription" => "sub_abc", "topic" => "agents.x.events" }, value)

    assert_empty pending_subscribe(ws)
  end

  def test_subscribe_error_response_rejects_future
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    ws.instance_variable_get(:@mutex).synchronize do
      pending_subscribe(ws)["req-1"] = { topic: "agents.x.events", future: future }
    end

    inject(ws, {
      "jsonrpc" => "2.0",
      "id"      => "req-1",
      "error"   => { "code" => -32_000, "message" => "Topic not found" }
    })

    result, value = future.wait(timeout: 1)
    assert_equal :error, result
    assert_includes value, "Topic not found"
  end

  # ── Notification routing ──────────────────────────────────────────────────

  def test_delivers_notification_to_subscription
    ws = make_ws
    sub = DatagroutConduit::Transport::Ws::Subscription.new("sub_abc", "agents.x.events")
    ws.instance_variable_get(:@mutex).synchronize do
      subscriptions(ws)["sub_abc"] = [sub]
    end

    inject(ws, {
      "jsonrpc" => "2.0",
      "method"  => "notification",
      "params"  => {
        "subscription" => "sub_abc",
        "event"        => "agent.thought",
        "data"         => { "text" => "thinking" }
      }
    })

    event = sub.recv(timeout: 1)
    refute_nil event
    assert_equal "sub_abc",       event.subscription
    assert_equal "agent.thought", event.event
    assert_equal({ "text" => "thinking" }, event.data)
  end

  def test_silently_drops_notification_for_unknown_subscription
    ws = make_ws
    inject(ws, {
      "jsonrpc" => "2.0",
      "method"  => "notification",
      "params"  => { "subscription" => "ghost", "event" => "x", "data" => nil }
    })
    assert_empty subscriptions(ws)
  end

  def test_ignores_notification_without_subscription_field
    ws = make_ws
    inject(ws, {
      "jsonrpc" => "2.0",
      "method"  => "notification",
      "params"  => { "event" => "x", "data" => nil }
    })
    assert_empty subscriptions(ws)  # no crash
  end

  def test_ignores_unknown_server_methods
    ws = make_ws
    inject(ws, {
      "jsonrpc" => "2.0",
      "method"  => "session.ready",
      "params"  => { "session_id" => "abc" }
    })
    assert_empty subscriptions(ws)
  end

  # ── Disconnect ────────────────────────────────────────────────────────────

  def test_disconnect_clears_pending_and_subscriptions
    ws = make_ws

    future = DatagroutConduit::Transport::Ws::RequestFuture.new
    sub    = DatagroutConduit::Transport::Ws::Subscription.new("sub_1", "test.topic")

    ws.instance_variable_get(:@mutex).synchronize do
      pending(ws)["ws-1"] = future
      subscriptions(ws)["sub_1"] = [sub]
    end

    ws.send(:fail_all_pending, :disconnected)

    result, _ = future.wait(timeout: 1)
    assert_equal :error, result
    assert_predicate sub, :closed?
  end

  def test_fail_all_pending_closes_subscriptions
    ws = make_ws

    sub1 = DatagroutConduit::Transport::Ws::Subscription.new("s1", "t1")
    sub2 = DatagroutConduit::Transport::Ws::Subscription.new("s2", "t2")

    ws.instance_variable_get(:@mutex).synchronize do
      subscriptions(ws)["s1"] = [sub1]
      subscriptions(ws)["s2"] = [sub2]
    end

    ws.send(:fail_all_pending, :disconnected)

    assert_predicate sub1, :closed?
    assert_predicate sub2, :closed?
  end

  # ── Subscription class ────────────────────────────────────────────────────

  def test_subscription_recv_returns_event
    sub   = DatagroutConduit::Transport::Ws::Subscription.new("s1", "topic")
    event = DatagroutConduit::Transport::Ws::SubscriptionEvent.new(
      subscription: "s1", event: "test", data: { "x" => 1 }
    )

    sub._enqueue(event)
    assert_equal event, sub.recv(timeout: 1)
  end

  def test_subscription_recv_times_out
    sub = DatagroutConduit::Transport::Ws::Subscription.new("s1", "topic")
    result = sub.recv(timeout: 0.05)
    assert_nil result
  end

  def test_subscription_closed_raises_stop_iteration_on_recv
    sub = DatagroutConduit::Transport::Ws::Subscription.new("s1", "topic")
    sub._close

    assert_raises(StopIteration) { sub.recv }
  end

  def test_subscription_close_is_idempotent
    sub = DatagroutConduit::Transport::Ws::Subscription.new("s1", "topic")
    sub._close
    sub._close  # should not raise or double-enqueue sentinel
    assert_predicate sub, :closed?
  end

  def test_subscription_enqueue_ignores_after_close
    sub = DatagroutConduit::Transport::Ws::Subscription.new("s1", "topic")
    sub._close
    sub._enqueue(DatagroutConduit::Transport::Ws::SubscriptionEvent.new(
      subscription: "s1", event: "x", data: nil
    ))
    # Queue has only the nil sentinel; recv raises StopIteration
    assert_raises(StopIteration) { sub.recv }
  end

  def test_subscription_each_iterates_until_closed
    sub    = DatagroutConduit::Transport::Ws::Subscription.new("s1", "topic")
    events = []
    e1 = DatagroutConduit::Transport::Ws::SubscriptionEvent.new(
      subscription: "s1", event: "a", data: nil
    )
    e2 = DatagroutConduit::Transport::Ws::SubscriptionEvent.new(
      subscription: "s1", event: "b", data: nil
    )

    sub._enqueue(e1)
    sub._enqueue(e2)
    sub._close

    sub.each { |e| events << e }
    assert_equal [e1, e2], events
  end

  # ── Client integration ────────────────────────────────────────────────────

  def test_subscribe_raises_when_not_websocket_transport
    client = DatagroutConduit::Client.new(
      url: "https://example.com/mcp",
      auth: { bearer: "tok" },
      transport: :mcp
    )
    err = assert_raises(RuntimeError) { client.subscribe("agents.x.events") }
    assert_includes err.message, "websocket"
  end

  def test_unsubscribe_raises_when_not_websocket_transport
    client = DatagroutConduit::Client.new(
      url: "https://example.com/mcp",
      auth: { bearer: "tok" },
      transport: :mcp
    )
    err = assert_raises(RuntimeError) { client.unsubscribe("sub_123") }
    assert_includes err.message, "websocket"
  end

  def test_client_websocket_transport_uses_ws_class
    client = DatagroutConduit::Client.new(
      url: "wss://example.com/ws",
      auth: { bearer: "tok" },
      transport: :websocket
    )
    assert_instance_of DatagroutConduit::Transport::Ws, client.transport
  end

  def test_client_websocket_transport_string_key
    client = DatagroutConduit::Client.new(
      url: "wss://example.com/ws",
      auth: { bearer: "tok" },
      transport: "websocket"
    )
    assert_instance_of DatagroutConduit::Transport::Ws, client.transport
  end

  def test_unknown_transport_raises
    assert_raises(DatagroutConduit::ConfigError) do
      DatagroutConduit::Client.new(
        url: "https://example.com/mcp",
        auth: { bearer: "tok" },
        transport: :grpc
      )
    end
  end

  # ── Auth header building ──────────────────────────────────────────────────

  def test_bearer_auth_header
    ws = DatagroutConduit::Transport::Ws.new(
      url: "wss://example.com/ws",
      auth: { bearer: "my-token" }
    )
    headers = ws.send(:build_upgrade_headers)
    assert_equal "Bearer my-token", headers["Authorization"]
  end

  def test_api_key_auth_header
    ws = DatagroutConduit::Transport::Ws.new(
      url: "wss://example.com/ws",
      auth: { api_key: "ak-123" }
    )
    headers = ws.send(:build_upgrade_headers)
    assert_equal "ak-123", headers["X-API-Key"]
  end

  def test_basic_auth_header
    ws = DatagroutConduit::Transport::Ws.new(
      url: "wss://example.com/ws",
      auth: { basic: { username: "user", password: "pass" } }
    )
    headers = ws.send(:build_upgrade_headers)
    expected = "Basic #{Base64.strict_encode64("user:pass")}"
    assert_equal expected, headers["Authorization"]
  end

  def test_no_auth_produces_empty_headers
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", auth: {})
    headers = ws.send(:build_upgrade_headers)
    assert_empty headers
  end

  # ── Ping keepalive ──────────────────────────────────────────────────────────

  def test_ping_interval_constant_is_25_seconds
    # Mirror of Rust PING_INTERVAL; must stay aligned for parity.
    assert_equal 25, DatagroutConduit::Transport::Ws::PING_INTERVAL_SECONDS
  end

  def test_default_ping_interval_matches_constant
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws")
    assert_in_delta DatagroutConduit::Transport::Ws::PING_INTERVAL_SECONDS, ws.ping_interval, 0.001
  end

  def test_constructor_accepts_ping_interval_override
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", ping_interval: 0.05)
    assert_in_delta 0.05, ws.ping_interval, 0.001
  end

  def test_pings_sent_starts_at_zero
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", ping_interval: 0.05)
    assert_equal 0, ws.pings_sent
  end

  def test_ping_thread_fires_pings_against_a_driver_double
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", ping_interval: 0.02)

    # Drive the ping loop without a real socket: install a driver double and
    # mark @connected so start_ping_thread keeps iterating.
    ping_calls = 0
    driver = Object.new
    driver.define_singleton_method(:ping) { ping_calls += 1; true }
    ws.instance_variable_set(:@driver, driver)
    ws.instance_variable_set(:@connected, true)

    ws.send(:start_ping_thread)
    sleep 0.08
    ws.send(:stop_ping_thread)
    ws.instance_variable_set(:@connected, false)

    assert ping_calls >= 1, "expected at least 1 ping in 80ms with 20ms interval; got #{ping_calls}"
    assert ws.pings_sent >= 1
  end

  def test_ping_thread_exits_when_driver_returns_false
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", ping_interval: 0.02)
    driver = Object.new
    driver.define_singleton_method(:ping) { false }  # simulates closing connection
    ws.instance_variable_set(:@driver, driver)
    ws.instance_variable_set(:@connected, true)

    ws.send(:start_ping_thread)
    sleep 0.08
    refute ws.instance_variable_get(:@ping_thread)&.alive?,
           "ping thread should exit when driver#ping returns false"
    ws.instance_variable_set(:@connected, false)
  end

  def test_stop_ping_thread_is_idempotent
    ws = DatagroutConduit::Transport::Ws.new(url: "wss://example.com/ws", ping_interval: 0.02)
    ws.send(:stop_ping_thread)  # nothing to stop
    ws.send(:stop_ping_thread)  # still nothing to stop
    assert true # if we got here without an exception, it's idempotent
  end
end
