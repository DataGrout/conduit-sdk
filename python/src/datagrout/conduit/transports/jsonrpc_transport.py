"""JSONRPC transport implementation using httpx."""

import logging
import uuid
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
    """Raised when the DataGrout gateway returns HTTP 429.

    Authenticated DataGrout users are never rate-limited. Unauthenticated
    callers that exceed the hourly cap will receive this error.

    Attributes:
        status: Parsed rate limit state from the response headers.
        retry_after: Always ``None`` for this transport (no ``Retry-After`` header).
    """

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
    """Parse ``X-RateLimit-*`` headers into a :class:`RateLimitStatus`."""
    used = int(response.headers.get("X-RateLimit-Used", "0") or "0")
    limit_str = response.headers.get("X-RateLimit-Limit", "50") or "50"
    return RateLimitStatus.from_headers(used, limit_str)


class JSONRPCTransport(Transport):
    """Transport implementation using raw JSONRPC over HTTP."""

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        identity: "Optional[Any]" = None,
        **kwargs: Any,
    ) -> None:
        self.url = url
        self.auth = auth or {}
        self.identity = identity
        self.kwargs = kwargs
        self._client: Optional[httpx.AsyncClient] = None
        self._request_id = 0

        # Set up OAuth token provider if client_credentials auth is configured.
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

    async def connect(self) -> None:
        """Establish HTTP connection."""
        client_kwargs: Dict[str, Any] = {
            "base_url": self.url,
            "timeout": 30.0,
            **self.kwargs,
        }

        if self.identity is not None:
            # Build an ssl.SSLContext with the client certificate loaded and
            # pass it to httpx as the `verify` argument.
            ssl_ctx = self.identity.build_ssl_context()
            client_kwargs["verify"] = ssl_ctx

        self._client = httpx.AsyncClient(**client_kwargs)

    async def disconnect(self) -> None:
        """Close HTTP connection."""
        if self._client:
            await self._client.aclose()

    async def _build_auth_headers(self) -> Dict[str, str]:
        """Build per-request auth headers (async to support OAuth token fetch)."""
        if self._oauth is not None:
            assert self._client is not None
            token = await self._oauth.get_token(self._client)
            return {"Authorization": f"Bearer {token}"}
        if "bearer" in self.auth:
            return {"Authorization": f"Bearer {self.auth['bearer']}"}
        if "basic" in self.auth:
            import base64
            creds = base64.b64encode(
                f"{self.auth['basic']['username']}:{self.auth['basic']['password']}".encode()
            ).decode()
            return {"Authorization": f"Basic {creds}"}
        if "custom" in self.auth:
            return dict(self.auth["custom"])
        return {}

    async def send_request(self, method: str, params: Any = None) -> Any:
        """Send a raw JSON-RPC request and return the result."""
        return await self._call_with_retry(method, params, is_retry=False)

    async def _call(self, method: str, params: Any = None) -> Any:
        """Make a JSONRPC call."""
        return await self._call_with_retry(method, params, is_retry=False)

    async def _call_with_retry(
        self, method: str, params: Any, is_retry: bool
    ) -> Any:
        if not self._client:
            await self.connect()

        assert self._client is not None
        self._request_id += 1

        auth_headers = await self._build_auth_headers()

        request = {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": params or {},
        }

        try:
            response = await self._client.post("", json=request, headers=auth_headers)
        except httpx.ConnectError as exc:
            raise NetworkError(f"Connection failed: {exc}") from exc
        except httpx.TimeoutException as exc:
            raise NetworkError(f"Request timed out: {exc}") from exc
        except httpx.TransportError as exc:
            raise NetworkError(f"Network error: {exc}") from exc

        if response.status_code == 429:
            raise RateLimitError(_parse_rate_limit_status(response))

        if response.status_code == 401:
            if self._oauth is not None and not is_retry:
                self._oauth.invalidate()
                return await self._call_with_retry(method, params, is_retry=True)
            raise AuthError(
                f"Authentication failed (HTTP 401). "
                f"Check your credentials and try again."
            )

        response.raise_for_status()

        data = response.json()

        if "error" in data:
            raise Exception(f"JSONRPC Error: {data['error']}")

        return data.get("result")

    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List tools via tools/list."""
        result = await self._call("tools/list", kwargs)
        return result.get("tools", []) if result else []

    async def call_tool(
        self, name: str, arguments: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """Call tool via tools/call."""
        import json as _json

        params = {"name": name, "arguments": arguments, **kwargs}
        result = await self._call("tools/call", params)

        # MCP tool responses (both MCP and JSONRPC transports) wrap the result in
        # a content envelope: {"content": [{"type": "text", "text": "<json>"}], ...}
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
        result = await self._call("resources/list", kwargs)
        return result.get("resources", []) if result else []

    async def read_resource(self, uri: str, **kwargs: Any) -> Any:
        """Read resource via resources/read."""
        params = {"uri": uri, **kwargs}
        return await self._call("resources/read", params)

    async def list_prompts(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List prompts via prompts/list."""
        result = await self._call("prompts/list", kwargs)
        return result.get("prompts", []) if result else []

    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> Any:
        """Get prompt via prompts/get."""
        params = {"name": name, "arguments": arguments or {}, **kwargs}
        return await self._call("prompts/get", params)
