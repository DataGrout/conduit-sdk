"""WebSocket transport for ``datagrout-jsonrpc.v1``.

Recommended for any client that needs bidirectional push (server-initiated
notifications) without a polling loop.  A single ``wss://`` connection is
multiplexed for all in-flight requests; concurrent calls are correlated by
JSON-RPC ``id`` with no head-of-line blocking.

Subscriptions
-------------
Call :meth:`WsTransport.subscribe` to open a server-side push subscription.
The returned :class:`Subscription` exposes an async-iterable interface::

    sub = await transport.subscribe("agents.my-id.events")
    async for event in sub:
        print(event.event, event.data)
    await transport.unsubscribe(sub.id)

Wire protocol
-------------
- Subprotocol: ``datagrout-jsonrpc.v1`` (negotiated at upgrade)
- Connect URL: ``wss://<gateway>/servers/<uuid>/ws``
- Frame format: JSON-RPC 2.0, text frames only
- Auth: ``Authorization: Bearer <token>`` in the upgrade headers

Reconnection
------------
Reconnect is caller-driven.  After a disconnect,
:meth:`WsTransport.send_request` raises :class:`RuntimeError` with the
message *"WS transport not connected"*.  Active subscriptions do not survive
reconnects; callers must re-subscribe after calling :meth:`connect` again.
"""

from __future__ import annotations

import asyncio
import base64
import json
import ssl
import tempfile
import os
import uuid
from dataclasses import dataclass
from typing import Any, AsyncIterator, Dict, Optional, Tuple

try:
    import websockets
    from websockets.asyncio.client import connect as ws_connect, ClientConnection
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "The 'websockets' package is required for the WebSocket transport. "
        "Install it with: pip install 'datagrout-conduit[ws]'"
    ) from exc

from .base import Transport

SUBPROTOCOL = "datagrout-jsonrpc.v1"

# Maximum events buffered per subscription before the oldest is dropped.
_SUBSCRIPTION_BUFFER = 256


# ── Public types ──────────────────────────────────────────────────────────────


@dataclass
class SubscriptionEvent:
    """A single server-pushed notification."""

    subscription: str
    """The subscription id this event belongs to."""
    event: str
    """Server-named event slug (e.g. ``"agent.thought"``)."""
    data: Any
    """Free-form payload from the server."""


class Subscription:
    """Handle for an active server-push subscription.

    Consume events with :meth:`recv` or by iterating asynchronously::

        async for event in sub:
            handle(event)
    """

    def __init__(self, sub_id: str, topic: str) -> None:
        self.id = sub_id
        self.topic = topic
        self._queue: asyncio.Queue[Optional[SubscriptionEvent]] = asyncio.Queue(
            maxsize=_SUBSCRIPTION_BUFFER
        )

    async def recv(self) -> SubscriptionEvent:
        """Wait for the next event from this subscription.

        Raises :class:`RuntimeError` if the subscription has been closed.
        """
        ev = await self._queue.get()
        if ev is None:
            raise RuntimeError("Subscription closed")
        return ev

    def __aiter__(self) -> "Subscription":
        return self

    async def __anext__(self) -> SubscriptionEvent:
        try:
            return await self.recv()
        except RuntimeError:
            raise StopAsyncIteration

    # ── Internal ──────────────────────────────────────────────────────────────

    def _enqueue(self, event: SubscriptionEvent) -> None:
        try:
            self._queue.put_nowait(event)
        except asyncio.QueueFull:
            pass  # drop on overflow

    def _close(self) -> None:
        try:
            self._queue.put_nowait(None)
        except asyncio.QueueFull:
            pass


# ── WsTransport ───────────────────────────────────────────────────────────────


class WsTransport(Transport):
    """JSON-RPC 2.0 over WebSocket transport (``datagrout-jsonrpc.v1``).

    Multiplexes any number of in-flight requests on one socket and routes
    server-pushed notifications back to :class:`Subscription` queues.

    Args:
        url: WebSocket endpoint URL (``ws://`` or ``wss://``).
        auth: Authentication config dict.  Same format as the HTTP transports:
            ``{"bearer": "token"}``, ``{"basic": {...}}``, ``{"api_key": "..."}``.
        identity: Optional :class:`~datagrout.conduit.ConduitIdentity` for mTLS.
    """

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        identity: Optional[Any] = None,
        **_kwargs: Any,
    ) -> None:
        from urllib.parse import urlparse

        scheme = urlparse(url).scheme
        if scheme not in ("ws", "wss"):
            raise ValueError(
                f"WS transport requires a ws:// or wss:// URL, got {scheme!r}"
            )

        self._url = url
        self._auth = auth or {}
        self._identity = identity

        self._ws: Optional[ClientConnection] = None
        self._recv_task: Optional[asyncio.Task] = None

        # id → Future[result]
        self._pending: Dict[str, asyncio.Future] = {}
        # id → (topic, Future[Subscription])
        self._pending_subscribe: Dict[str, Tuple[str, asyncio.Future]] = {}
        # sub_id → Subscription
        self._subscriptions: Dict[str, Subscription] = {}

        self._next_id: int = 0

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    async def connect(self) -> None:
        """Open the WebSocket connection and start the receive loop."""
        if self._ws is not None:
            return

        extra_headers = self._build_extra_headers()
        ssl_ctx = self._build_ssl_context()

        connect_kwargs: Dict[str, Any] = {
            "additional_headers": extra_headers,
            "subprotocols": [SUBPROTOCOL],
        }
        if ssl_ctx is not None:
            connect_kwargs["ssl"] = ssl_ctx

        self._ws = await ws_connect(self._url, **connect_kwargs)
        self._recv_task = asyncio.create_task(self._receive_loop())

    async def disconnect(self) -> None:
        """Close the WebSocket connection and fail all pending operations."""
        if self._recv_task is not None:
            self._recv_task.cancel()
            try:
                await self._recv_task
            except (asyncio.CancelledError, Exception):
                pass
            self._recv_task = None

        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

        # Propagate closure to all pending callers.
        err = RuntimeError("WS connection closed")
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(err)
        self._pending.clear()

        for _topic, fut in self._pending_subscribe.values():
            if not fut.done():
                fut.set_exception(err)
        self._pending_subscribe.clear()

        for sub in self._subscriptions.values():
            sub._close()
        self._subscriptions.clear()

    # ── Subscriptions ─────────────────────────────────────────────────────────

    async def subscribe(self, topic: str) -> Subscription:
        """Open a server-side push subscription for *topic*.

        Returns a :class:`Subscription` whose :meth:`~Subscription.recv`
        method (or async-for loop) delivers server-pushed events.

        Args:
            topic: Dotted namespace topic, e.g.
                ``"agents.my-agent-id.events"`` or ``"tasks.task-123.*"``.

        Returns:
            A :class:`Subscription` handle.
        """
        self._require_connected()
        req_id = self._mint_id()
        request = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "subscribe",
            "params": {"topic": topic},
        }
        fut: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending_subscribe[req_id] = (topic, fut)
        assert self._ws is not None
        await self._ws.send(json.dumps(request))
        return await fut

    async def unsubscribe(self, subscription_id: str) -> None:
        """Cancel a server-side subscription.

        The local :class:`Subscription` queue is closed immediately so
        async-for loops exit cleanly.  A best-effort unsubscribe frame is
        sent to the server (5 s timeout).

        Args:
            subscription_id: The ``id`` field of the :class:`Subscription`
                returned by :meth:`subscribe`.
        """
        self._require_connected()

        # Close the local queue immediately.
        if sub := self._subscriptions.pop(subscription_id, None):
            sub._close()

        req_id = self._mint_id()
        request = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "unsubscribe",
            "params": {"subscription": subscription_id},
        }
        fut: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending[req_id] = fut
        assert self._ws is not None
        await self._ws.send(json.dumps(request))
        try:
            await asyncio.wait_for(fut, timeout=5.0)
        except (asyncio.TimeoutError, Exception):
            self._pending.pop(req_id, None)

    # ── Transport base implementation ─────────────────────────────────────────

    async def send_request(self, method: str, params: Any = None) -> Any:
        """Send a JSON-RPC 2.0 request and return the decoded result.

        Args:
            method: JSON-RPC method name.
            params: Optional parameters (dict or list).

        Returns:
            The ``result`` field of the server's JSON-RPC response.

        Raises:
            RuntimeError: If the connection is not open or the server returns
                an error response.
        """
        self._require_connected()
        req_id = self._mint_id()
        request: Dict[str, Any] = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            request["params"] = params

        fut: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending[req_id] = fut
        assert self._ws is not None
        await self._ws.send(json.dumps(request))
        return await fut

    async def call_tool(
        self, name: str, arguments: Dict[str, Any], **_kwargs: Any
    ) -> Any:
        return await self.send_request("tools/call", {"name": name, "arguments": arguments})

    async def list_tools(self, **kwargs: Any) -> Any:
        return await self.send_request("tools/list", kwargs or None)

    async def list_resources(self, **_kwargs: Any) -> Any:
        return await self.send_request("resources/list")

    async def read_resource(self, uri: str, **_kwargs: Any) -> Any:
        return await self.send_request("resources/read", {"uri": uri})

    async def list_prompts(self, **_kwargs: Any) -> Any:
        return await self.send_request("prompts/list")

    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **_kwargs: Any
    ) -> Any:
        return await self.send_request("prompts/get", {"name": name, "arguments": arguments})

    # ── Internal helpers ──────────────────────────────────────────────────────

    def _mint_id(self) -> str:
        self._next_id += 1
        return f"ws-{self._next_id}"

    def _require_connected(self) -> None:
        if self._ws is None:
            raise RuntimeError(
                "WS transport not connected. Call connect() first or use 'async with'."
            )

    def _build_extra_headers(self) -> Dict[str, str]:
        headers: Dict[str, str] = {}
        auth = self._auth

        if bearer := auth.get("bearer"):
            headers["Authorization"] = f"Bearer {bearer}"
        elif api_key := auth.get("api_key"):
            headers["X-API-Key"] = str(api_key)
        elif basic := auth.get("basic"):
            encoded = base64.b64encode(
                f"{basic['username']}:{basic['password']}".encode()
            ).decode()
            headers["Authorization"] = f"Basic {encoded}"

        return headers

    def _build_ssl_context(self) -> Optional[ssl.SSLContext]:
        """Build an SSL context with mTLS if an identity is configured."""
        if self._identity is None:
            return None

        ctx = ssl.create_default_context()

        ca_bytes = getattr(self._identity, "ca_pem_bytes", lambda: None)()
        if ca_bytes:
            ctx.load_verify_locations(cadata=ca_bytes.decode())

        cert_bytes = self._identity.cert_pem_bytes()
        key_bytes = self._identity.key_pem_bytes()

        # ssl.SSLContext.load_cert_chain accepts file paths only; write to tmp.
        with tempfile.NamedTemporaryFile(delete=False, suffix=".pem") as cf:
            cf.write(cert_bytes)
            cert_path = cf.name
        with tempfile.NamedTemporaryFile(delete=False, suffix=".pem") as kf:
            kf.write(key_bytes)
            key_path = kf.name
        try:
            ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)
        finally:
            os.unlink(cert_path)
            os.unlink(key_path)

        return ctx

    # ── Receive loop ──────────────────────────────────────────────────────────

    async def _receive_loop(self) -> None:
        assert self._ws is not None
        try:
            async for raw in self._ws:
                if not isinstance(raw, str):
                    continue  # binary frames are not part of the protocol
                try:
                    msg: Dict[str, Any] = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                # Notifications have no "id" field.
                if "id" not in msg:
                    if msg.get("method") == "notification":
                        self._route_notification(msg.get("params") or {})
                    continue

                msg_id = str(msg["id"])

                # Subscribe response — must register the Subscription before
                # delivering the handle so no notification can race ahead.
                if msg_id in self._pending_subscribe:
                    topic, fut = self._pending_subscribe.pop(msg_id)
                    if fut.done():
                        continue
                    if err := msg.get("error"):
                        fut.set_exception(
                            RuntimeError(err.get("message", "Subscribe failed"))
                        )
                    else:
                        result = msg.get("result") or {}
                        sub_id = result.get("subscription") or msg_id
                        sub = Subscription(sub_id, topic)
                        self._subscriptions[sub_id] = sub
                        fut.set_result(sub)
                    continue

                # Regular response.
                if msg_id in self._pending:
                    fut = self._pending.pop(msg_id)
                    if fut.done():
                        continue
                    if err := msg.get("error"):
                        fut.set_exception(
                            RuntimeError(err.get("message", "RPC error"))
                        )
                    else:
                        fut.set_result(msg.get("result"))

        except asyncio.CancelledError:
            pass
        except Exception:
            pass

    def _route_notification(self, params: Dict[str, Any]) -> None:
        sub_id = params.get("subscription")
        if not sub_id or sub_id not in self._subscriptions:
            return
        event = SubscriptionEvent(
            subscription=str(sub_id),
            event=str(params.get("event") or ""),
            data=params.get("data"),
        )
        self._subscriptions[sub_id]._enqueue(event)
