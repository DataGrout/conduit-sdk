"""Ephemerals namespace — cache management and inspection."""

from typing import Any, Dict, Optional


class EphemeralsNamespace:
    """Cache listing and inspection for ephemeral (cached) tool results."""

    def __init__(self, client: Any):
        self._client = client

    async def list(self, params: Optional[Dict[str, Any]] = None) -> Any:
        """List cached results (`data-grout/ephemerals.list`)."""
        self._client._warn_if_not_dg("ephemerals.list")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/ephemerals.list", params or {})
        )

    async def inspect(self, cache_ref: str) -> Any:
        """Inspect a specific cache entry (`data-grout/ephemerals.inspect`)."""
        self._client._warn_if_not_dg("ephemerals.inspect")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/ephemerals.inspect", {"cache_ref": cache_ref})
        )
