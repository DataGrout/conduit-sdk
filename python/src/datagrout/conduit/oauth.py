"""
OAuth 2.1 ``client_credentials`` token provider for Conduit.

Fetches short-lived JWTs from the DataGrout machine-client token endpoint
and caches them, refreshing proactively before they expire.

Example::

    from datagrout.conduit import Client

    client = Client(
        url="https://app.datagrout.ai/servers/{uuid}/mcp",
        client_id="my_client_id",
        client_secret="my_client_secret",
    )
    await client.connect()
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Optional

import httpx

logger = logging.getLogger(__name__)


def derive_token_endpoint(mcp_url: str) -> str:
    """Derive the token endpoint URL from a DataGrout MCP URL.

    >>> derive_token_endpoint('https://app.datagrout.ai/servers/abc/mcp')
    'https://app.datagrout.ai/servers/abc/oauth/token'
    """
    idx = mcp_url.find("/mcp")
    base = mcp_url[:idx] if idx != -1 else mcp_url.rstrip("/")
    return f"{base}/oauth/token"


@dataclass
class _CachedToken:
    access_token: str
    expires_at: float  # monotonic time (seconds)


class OAuthTokenProvider:
    """Lazy, caching OAuth 2.1 ``client_credentials`` token fetcher.

    Thread-safe for use with :mod:`asyncio` — a single in-flight fetch
    is shared across concurrent callers.
    """

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        token_endpoint: str,
        scope: Optional[str] = None,
    ) -> None:
        self._client_id = client_id
        self._client_secret = client_secret
        self._token_endpoint = token_endpoint
        self._scope = scope

        self._cached: Optional[_CachedToken] = None
        self._fetch_lock = asyncio.Lock()

    # ─── Public API ───────────────────────────────────────────────────────────

    async def get_token(self, http_client: httpx.AsyncClient) -> str:
        """Return the current bearer token, fetching a fresh one if necessary.

        Refreshes proactively when the cached token has less than 60 seconds
        remaining.
        """
        now = time.monotonic()
        if self._cached and self._cached.expires_at - now > 60:
            return self._cached.access_token

        async with self._fetch_lock:
            # Re-check after acquiring the lock.
            now = time.monotonic()
            if self._cached and self._cached.expires_at - now > 60:
                return self._cached.access_token

            cached = await self._fetch_token(http_client)
            self._cached = cached
            return cached.access_token

    def invalidate(self) -> None:
        """Invalidate the cached token (call after receiving a 401)."""
        self._cached = None

    # ─── Private ──────────────────────────────────────────────────────────────

    async def _fetch_token(self, http_client: httpx.AsyncClient) -> _CachedToken:
        data: dict[str, str] = {
            "grant_type": "client_credentials",
            "client_id": self._client_id,
            "client_secret": self._client_secret,
        }
        if self._scope:
            data["scope"] = self._scope

        try:
            resp = await http_client.post(self._token_endpoint, data=data)
            resp.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise RuntimeError(
                f"OAuth token endpoint returned {exc.response.status_code}: "
                f"{exc.response.text}"
            ) from exc
        except httpx.RequestError as exc:
            raise RuntimeError(f"OAuth token request failed: {exc}") from exc

        body = resp.json()
        access_token: str = body["access_token"]
        expires_in: int = int(body.get("expires_in", 3600))

        logger.debug(
            "conduit: fetched OAuth token client_id=%s expires_in=%ds scope=%r",
            self._client_id,
            expires_in,
            body.get("scope"),
        )

        return _CachedToken(
            access_token=access_token,
            # Subtract 60 s so we refresh before the token actually expires.
            expires_at=time.monotonic() + max(expires_in - 60, 30),
        )
