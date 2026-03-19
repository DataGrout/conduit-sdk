"""Deliverables namespace — work product tracking and retrieval."""

from typing import Any, Dict, Optional


class DeliverablesNamespace:
    """Work product registration, listing, and retrieval."""

    def __init__(self, client: Any):
        self._client = client

    async def register(self, params: Dict[str, Any]) -> Any:
        """Register a work product (`data-grout/deliverables.register`)."""
        self._client._warn_if_not_dg("deliverables.register")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/deliverables.register", params)
        )

    async def list(self, params: Optional[Dict[str, Any]] = None) -> Any:
        """List deliverables with optional semantic search (`data-grout/deliverables.list`)."""
        self._client._warn_if_not_dg("deliverables.list")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/deliverables.list", params or {})
        )

    async def get(self, ref_id: str) -> Any:
        """Get a specific deliverable by reference (`data-grout/deliverables.get`)."""
        self._client._warn_if_not_dg("deliverables.get")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/deliverables.get", {"ref": ref_id})
        )
