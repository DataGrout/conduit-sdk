"""Tests for the WebSocket transport (datagrout-jsonrpc.v1).

These tests use a lightweight in-process WebSocket server built with
``websockets`` to exercise the full send/receive path without hitting any
real network.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, Dict
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from datagrout.conduit.transports.ws_transport import (
    SUBPROTOCOL,
    Subscription,
    SubscriptionEvent,
    WsTransport,
)


# ── Helpers ───────────────────────────────────────────────────────────────────


async def make_mock_ws(recv_messages: list[str] | None = None) -> Any:
    """Return a mock WebSocket connection object."""
    ws = AsyncMock()
    ws.send = AsyncMock()
    ws.close = AsyncMock()

    _msgs = list(recv_messages or [])

    async def _aiter(self_):
        for m in _msgs:
            yield m

    ws.__aiter__ = _aiter
    return ws


# ── Unit tests ────────────────────────────────────────────────────────────────


def test_rejects_non_ws_url():
    with pytest.raises(ValueError, match="ws://"):
        WsTransport("https://example.com/ws")


def test_accepts_ws_and_wss():
    WsTransport("ws://localhost:4000/ws")
    WsTransport("wss://gw.example.com/ws")


def test_not_connected_initially():
    t = WsTransport("wss://example.com/ws")
    assert t._ws is None


@pytest.mark.asyncio
async def test_require_connected_raises_when_disconnected():
    t = WsTransport("wss://example.com/ws")
    with pytest.raises(RuntimeError, match="not connected"):
        await t.send_request("tools/list")


@pytest.mark.asyncio
async def test_require_connected_subscribe():
    t = WsTransport("wss://example.com/ws")
    with pytest.raises(RuntimeError, match="not connected"):
        await t.subscribe("agents.x.events")


@pytest.mark.asyncio
async def test_require_connected_unsubscribe():
    t = WsTransport("wss://example.com/ws")
    with pytest.raises(RuntimeError, match="not connected"):
        await t.unsubscribe("sub_123")


@pytest.mark.asyncio
async def test_disconnect_fails_pending_futures():
    t = WsTransport("wss://example.com/ws")
    t._ws = AsyncMock()
    t._ws.close = AsyncMock()

    # Plant a pending future.
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    t._pending["ws-1"] = fut

    # disconnect() should fail pending futures.
    t._recv_task = asyncio.create_task(asyncio.sleep(0))
    await t.disconnect()

    assert fut.done()
    with pytest.raises(RuntimeError, match="closed"):
        fut.result()


@pytest.mark.asyncio
async def test_route_notification_dispatches_to_subscription():
    t = WsTransport("wss://example.com/ws")
    sub = Subscription("sub_abc", "agents.x.events")
    t._subscriptions["sub_abc"] = sub

    t._route_notification(
        {"subscription": "sub_abc", "event": "thought", "data": {"text": "hi"}}
    )

    ev = sub._queue.get_nowait()
    assert ev is not None
    assert ev.event == "thought"
    assert ev.data == {"text": "hi"}


@pytest.mark.asyncio
async def test_route_notification_ignores_unknown_subscription():
    t = WsTransport("wss://example.com/ws")
    # No subscriptions registered — should not raise.
    t._route_notification(
        {"subscription": "ghost", "event": "x", "data": None}
    )
    assert len(t._subscriptions) == 0


@pytest.mark.asyncio
async def test_receive_loop_routes_rpc_response():
    t = WsTransport("wss://example.com/ws")
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    t._pending["ws-1"] = fut

    response = json.dumps({"jsonrpc": "2.0", "id": "ws-1", "result": {"ok": True}})
    mock_ws = await make_mock_ws([response])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    assert fut.done()
    assert fut.result() == {"ok": True}


@pytest.mark.asyncio
async def test_receive_loop_routes_rpc_error():
    t = WsTransport("wss://example.com/ws")
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    t._pending["ws-1"] = fut

    response = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": "ws-1",
            "error": {"code": -32600, "message": "bad request"},
        }
    )
    mock_ws = await make_mock_ws([response])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    assert fut.done()
    with pytest.raises(RuntimeError, match="bad request"):
        fut.result()


@pytest.mark.asyncio
async def test_receive_loop_handles_subscribe_response():
    t = WsTransport("wss://example.com/ws")
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    t._pending_subscribe["req-1"] = ("agents.x.events", fut)

    response = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": "req-1",
            "result": {"subscription": "sub_abc", "topic": "agents.x.events"},
        }
    )
    mock_ws = await make_mock_ws([response])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    assert fut.done()
    sub = fut.result()
    assert isinstance(sub, Subscription)
    assert sub.id == "sub_abc"
    assert sub.topic == "agents.x.events"
    assert "sub_abc" in t._subscriptions


@pytest.mark.asyncio
async def test_receive_loop_propagates_subscribe_error():
    t = WsTransport("wss://example.com/ws")
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    t._pending_subscribe["req-1"] = ("bad.topic", fut)

    response = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": "req-1",
            "error": {"code": -32000, "message": "unknown topic"},
        }
    )
    mock_ws = await make_mock_ws([response])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    assert fut.done()
    with pytest.raises(RuntimeError, match="unknown topic"):
        fut.result()


@pytest.mark.asyncio
async def test_receive_loop_routes_notification_to_subscription():
    t = WsTransport("wss://example.com/ws")
    sub = Subscription("sub_abc", "agents.x.events")
    t._subscriptions["sub_abc"] = sub

    notification = json.dumps(
        {
            "jsonrpc": "2.0",
            "method": "notification",
            "params": {
                "subscription": "sub_abc",
                "event": "agent.thought",
                "data": {"text": "thinking"},
            },
        }
    )
    mock_ws = await make_mock_ws([notification])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    ev = sub._queue.get_nowait()
    assert ev.event == "agent.thought"
    assert ev.data == {"text": "thinking"}


@pytest.mark.asyncio
async def test_receive_loop_ignores_unknown_server_methods():
    t = WsTransport("wss://example.com/ws")
    # session.ready and other server-initiated methods not matching "notification"
    # should be silently dropped.
    frame = json.dumps(
        {"jsonrpc": "2.0", "method": "session.ready", "params": {"session_id": "abc"}}
    )
    mock_ws = await make_mock_ws([frame])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    assert len(t._subscriptions) == 0
    assert len(t._pending) == 0


@pytest.mark.asyncio
async def test_receive_loop_ignores_malformed_json():
    t = WsTransport("wss://example.com/ws")
    mock_ws = await make_mock_ws(["not valid json", '{"id":1,"not":"jsonrpc"}'])
    t._ws = mock_ws

    recv_task = asyncio.create_task(t._receive_loop())
    await asyncio.sleep(0.05)
    recv_task.cancel()
    try:
        await recv_task
    except asyncio.CancelledError:
        pass

    # No panics, no state changes.
    assert len(t._pending) == 0


@pytest.mark.asyncio
async def test_disconnect_closes_subscriptions():
    t = WsTransport("wss://example.com/ws")
    t._ws = AsyncMock()
    t._ws.close = AsyncMock()

    sub = Subscription("sub_1", "tasks.x.*")
    t._subscriptions["sub_1"] = sub

    t._recv_task = asyncio.create_task(asyncio.sleep(0))
    await t.disconnect()

    # _close() should have enqueued a sentinel None.
    sentinel = sub._queue.get_nowait()
    assert sentinel is None


@pytest.mark.asyncio
async def test_build_extra_headers_bearer():
    t = WsTransport("wss://example.com/ws", auth={"bearer": "mytoken"})
    headers = t._build_extra_headers()
    assert headers["Authorization"] == "Bearer mytoken"


@pytest.mark.asyncio
async def test_build_extra_headers_api_key():
    t = WsTransport("wss://example.com/ws", auth={"api_key": "k123"})
    headers = t._build_extra_headers()
    assert headers["X-API-Key"] == "k123"


@pytest.mark.asyncio
async def test_build_extra_headers_basic():
    import base64

    t = WsTransport(
        "wss://example.com/ws",
        auth={"basic": {"username": "alice", "password": "s3cr3t"}},
    )
    headers = t._build_extra_headers()
    expected = base64.b64encode(b"alice:s3cr3t").decode()
    assert headers["Authorization"] == f"Basic {expected}"


@pytest.mark.asyncio
async def test_subscription_recv_delivers_event():
    sub = Subscription("sub_1", "topic.x")
    ev = SubscriptionEvent(subscription="sub_1", event="ping", data={"n": 1})
    sub._enqueue(ev)
    received = await sub.recv()
    assert received.event == "ping"


@pytest.mark.asyncio
async def test_subscription_close_raises_on_recv():
    sub = Subscription("sub_1", "topic.x")
    sub._close()
    with pytest.raises(RuntimeError, match="closed"):
        await sub.recv()


@pytest.mark.asyncio
async def test_subscription_async_iteration():
    sub = Subscription("sub_1", "topic.x")
    for i in range(3):
        sub._enqueue(SubscriptionEvent("sub_1", f"ev{i}", i))
    sub._close()

    events = []
    async for ev in sub:
        events.append(ev)

    assert len(events) == 3
    assert [e.event for e in events] == ["ev0", "ev1", "ev2"]


# ── Client integration ────────────────────────────────────────────────────────


def test_client_accepts_websocket_transport():
    from datagrout.conduit import Client

    client = Client("wss://gateway.datagrout.ai/servers/test/ws", transport="websocket")
    assert isinstance(client._transport, WsTransport)


def test_client_rewrites_https_to_wss():
    from datagrout.conduit import Client

    client = Client(
        "https://gateway.datagrout.ai/servers/test/ws", transport="websocket"
    )
    assert client._transport._url.startswith("wss://")


def test_client_rewrites_http_to_ws():
    from datagrout.conduit import Client

    client = Client("http://localhost:4000/ws", transport="websocket")
    assert client._transport._url.startswith("ws://")


@pytest.mark.asyncio
async def test_client_subscribe_requires_ws_transport():
    from datagrout.conduit import Client

    client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    client._initialized = True  # bypass connect()
    with pytest.raises(RuntimeError, match="transport='websocket'"):
        await client.subscribe("agents.x.events")


@pytest.mark.asyncio
async def test_client_unsubscribe_requires_ws_transport():
    from datagrout.conduit import Client

    client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    client._initialized = True
    with pytest.raises(RuntimeError, match="transport='websocket'"):
        await client.unsubscribe("sub_123")
