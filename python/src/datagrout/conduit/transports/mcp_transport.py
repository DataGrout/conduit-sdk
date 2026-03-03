"""MCP Streamable HTTP transport — RFC-compliant, no external MCP SDK required."""

import json
import logging
from typing import Any, Dict, List, Optional

import httpx

from .base import Transport
from ..errors import (
    AuthError,
    NetworkError,
    RateLimitError as _BaseRateLimitError,
)
from ..oauth import OAuthTokenProvider, derive_token_endpoint
from ..types import RateLimitPerHour, RateLimitStatus

logger = logging.getLogger(__name__)


class RateLimitError(_BaseRateLimitError):
    """Raised when the MCP gateway returns HTTP 429."""

    def __init__(self, status: RateLimitStatus) -> None:
        self.status = status
        if status.limit == "unlimited":
            limit_str = "unlimited"
        else:
            assert isinstance(status.limit, RateLimitPerHour)
            limit_str = f"{status.limit.per_hour}/hour"
        super().__init__(
            f"Rate limit exceeded ({status.used} / {limit_str} calls this hour)"
        )


def _parse_rate_limit_status(response: httpx.Response) -> RateLimitStatus:
    used = int(response.headers.get("X-RateLimit-Used", "0") or "0")
    limit_str = response.headers.get("X-RateLimit-Limit", "50") or "50"
    return RateLimitStatus.from_headers(used, limit_str)


def _parse_sse_body(body: str, request_id: int) -> Any:
    """Extract the JSON-RPC result from an SSE body matching request_id."""
    for line in body.splitlines():
        if line.startswith("data:"):
            data = line[5:].strip()
            if not data or data == "[DONE]":
                continue
            try:
                msg = json.loads(data)
                if msg.get("id") == request_id and "result" in msg:
                    return msg["result"]
                if msg.get("id") == request_id and "error" in msg:
                    raise Exception(f"MCP Error: {msg['error']}")
            except json.JSONDecodeError:
                continue
    return None


class MCPTransport(Transport):
    """
    MCP Streamable HTTP transport.

    Implements the MCP Streamable HTTP protocol directly using httpx — no
    external MCP SDK required. Handles the session handshake, SSE response
    parsing, auth headers, and retry logic.
    """

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        identity: "Optional[Any]" = None,
        **kwargs: Any,
    ):
        self.url = url
        self.auth = auth or {}
        self.identity = identity
        self.kwargs = kwargs
        self._client: Optional[httpx.AsyncClient] = None
        self._session_id: Optional[str] = None
        self._request_id = 0

        self._oauth: Optional[OAuthTokenProvider] = None
        if "client_credentials" in self.auth:
            cc = self.auth["client_credentials"]
            endpoint = cc.get("token_endpoint") or derive_token_endpoint(url)
            self._oauth = OAuthTokenProvider(
                client_id=cc["client_id"],
                client_secret=cc["client_secret"],
                token_endpoint=endpoint,
                scope=cc.get("scope"),
            )

        if identity is not None and identity.needs_rotation(30):
            logger.warning(
                "conduit: mTLS certificate expires within 30 days — consider rotating"
            )

    async def _build_auth_headers(self) -> Dict[str, str]:
        """Build per-request auth headers (async to support OAuth token fetch)."""
        if self._oauth is not None:
            assert self._client is not None
            token = await self._oauth.get_token(self._client)
            return {"Authorization": f"Bearer {token}"}
        if "bearer" in self.auth:
            return {"Authorization": f"Bearer {self.auth['bearer']}"}
        if "api_key" in self.auth:
            return {"X-API-Key": self.auth["api_key"]}
        if "basic" in self.auth:
            import base64
            creds = base64.b64encode(
                f"{self.auth['basic']['username']}:{self.auth['basic']['password']}".encode()
            ).decode()
            return {"Authorization": f"Basic {creds}"}
        if "custom" in self.auth:
            return dict(self.auth["custom"])
        return {}

    async def connect(self) -> None:
        """Establish an MCP session via the Streamable HTTP handshake."""
        client_kwargs: Dict[str, Any] = {"timeout": 60.0}

        if self.identity is not None:
            ssl_ctx = self.identity.build_ssl_context()
            client_kwargs["verify"] = ssl_ctx

        self._client = httpx.AsyncClient(**client_kwargs)

        # Send initialize request and capture mcp-session-id
        self._request_id += 1
        init_id = self._request_id
        auth_headers = await self._build_auth_headers()
        init_request = {
            "jsonrpc": "2.0",
            "id": init_id,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "datagrout-conduit", "version": "0.1.0"},
            },
        }

        try:
            response = await self._client.post(
                self.url,
                json=init_request,
                headers={
                    **auth_headers,
                    "Accept": "application/json, text/event-stream",
                },
            )
        except httpx.ConnectError as exc:
            raise NetworkError(f"Connection failed: {exc}") from exc
        except httpx.TimeoutException as exc:
            raise NetworkError(f"Request timed out: {exc}") from exc

        response.raise_for_status()

        # Capture session ID (case-insensitive)
        self._session_id = response.headers.get("mcp-session-id")

        # Send initialized notification (no response expected)
        notification = {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {},
        }
        notif_headers: Dict[str, str] = {
            **auth_headers,
            "Accept": "application/json, text/event-stream",
        }
        if self._session_id:
            notif_headers["Mcp-Session-Id"] = self._session_id

        try:
            await self._client.post(self.url, json=notification, headers=notif_headers)
        except Exception:
            # Notification delivery is best-effort; ignore errors
            pass

    async def disconnect(self) -> None:
        """Close the session and HTTP client."""
        if self._client and self._session_id:
            try:
                auth_headers = await self._build_auth_headers()
                await self._client.delete(
                    self.url,
                    headers={**auth_headers, "Mcp-Session-Id": self._session_id},
                )
            except Exception:
                pass

        if self._client:
            await self._client.aclose()
            self._client = None

        self._session_id = None

    async def send_request(self, method: str, params: Any = None) -> Any:
        """Send a raw JSON-RPC request and return the result."""
        return await self._send_with_retry(method, params, is_retry=False)

    async def _send_with_retry(
        self, method: str, params: Any, is_retry: bool
    ) -> Any:
        if not self._client:
            await self.connect()

        assert self._client is not None
        self._request_id += 1
        req_id = self._request_id

        auth_headers = await self._build_auth_headers()
        request_headers: Dict[str, str] = {
            **auth_headers,
            "Accept": "application/json, text/event-stream",
        }
        if self._session_id:
            request_headers["Mcp-Session-Id"] = self._session_id

        payload = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params if params is not None else {},
        }

        try:
            response = await self._client.post(
                self.url, json=payload, headers=request_headers
            )
        except httpx.ConnectError as exc:
            raise NetworkError(f"Connection failed: {exc}") from exc
        except httpx.TimeoutException as exc:
            raise NetworkError(f"Request timed out: {exc}") from exc
        except httpx.TransportError as exc:
            raise NetworkError(f"Network error: {exc}") from exc

        if response.status_code == 202:
            return {"accepted": True}

        if response.status_code == 429:
            raise RateLimitError(_parse_rate_limit_status(response))

        if response.status_code == 401:
            if self._oauth is not None and not is_retry:
                self._oauth.invalidate()
                return await self._send_with_retry(method, params, is_retry=True)
            raise AuthError(
                "Authentication failed (HTTP 401). Check your credentials and try again."
            )

        response.raise_for_status()

        content_type = response.headers.get("content-type", "")

        if content_type.startswith("text/event-stream"):
            result = _parse_sse_body(response.text, req_id)
            return result

        # application/json
        data = response.json()
        if "error" in data:
            raise Exception(f"MCP Error: {data['error']}")
        return data.get("result")

    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List tools via tools/list."""
        result = await self.send_request("tools/list", kwargs if kwargs else None)
        if result is None:
            return []
        if isinstance(result, list):
            return result
        return result.get("tools", [])

    async def call_tool(
        self, name: str, arguments: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """Call a tool via tools/call."""
        import json as _json

        params = {"name": name, "arguments": arguments, **kwargs}
        result = await self.send_request("tools/call", params)

        # MCP tool responses wrap the actual result in a content envelope:
        # {"content": [{"type": "text", "text": "<json>"}], "isError": false}
        # Unwrap one level so callers receive the actual tool output.
        if isinstance(result, dict):
            content = result.get("content")
            if isinstance(content, list) and content:
                first = content[0]
                if isinstance(first, dict) and isinstance(first.get("text"), str):
                    try:
                        return _json.loads(first["text"])
                    except _json.JSONDecodeError:
                        return {"text": first["text"]}

        return result

    async def list_resources(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List resources via resources/list."""
        result = await self.send_request("resources/list", kwargs if kwargs else None)
        if result is None:
            return []
        if isinstance(result, list):
            return result
        return result.get("resources", [])

    async def read_resource(self, uri: str, **kwargs: Any) -> Any:
        """Read a resource via resources/read."""
        params = {"uri": uri, **kwargs}
        return await self.send_request("resources/read", params)

    async def list_prompts(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List prompts via prompts/list."""
        result = await self.send_request("prompts/list", kwargs if kwargs else None)
        if result is None:
            return []
        if isinstance(result, list):
            return result
        return result.get("prompts", [])

    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> Any:
        """Get a prompt via prompts/get."""
        params = {"name": name, "arguments": arguments or {}, **kwargs}
        return await self.send_request("prompts/get", params)
