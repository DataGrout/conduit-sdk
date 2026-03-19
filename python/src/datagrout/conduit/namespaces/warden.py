"""Warden namespace — safety checks, intent verification, and consensus."""

from typing import Any, Dict


class WardenNamespace:
    """Safety gates, intent verification, and multi-model consensus."""

    def __init__(self, client: Any):
        self._client = client

    async def canary(self, params: Dict[str, Any]) -> Any:
        """Run a canary safety check (`data-grout/warden.canary`)."""
        self._client._warn_if_not_dg("warden.canary")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/warden.canary", params)
        )

    async def verify_intent(self, params: Dict[str, Any]) -> Any:
        """Verify intent before executing an action (`data-grout/warden.intent`)."""
        self._client._warn_if_not_dg("warden.intent")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/warden.intent", params)
        )

    async def adjudicate(self, params: Dict[str, Any]) -> Any:
        """Adjudicate a dispute or ambiguity (`data-grout/warden.adjudicate`)."""
        self._client._warn_if_not_dg("warden.adjudicate")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/warden.adjudicate", params)
        )

    async def ensemble(self, params: Dict[str, Any]) -> Any:
        """Multi-model ensemble consensus check (`data-grout/warden.ensemble`)."""
        self._client._warn_if_not_dg("warden.ensemble")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/warden.ensemble", params)
        )
