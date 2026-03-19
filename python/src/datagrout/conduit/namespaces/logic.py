"""Logic Cell namespace — agent memory, facts, constraints, and hypotheticals."""

from typing import Any, Dict, List, Optional


class LogicNamespace:
    """Persistent agent memory backed by a Prolog logic cell."""

    def __init__(self, client: Any):
        self._client = client

    async def remember(
        self,
        statement: str,
        tag: str = "default",
        facts: Optional[List[Dict[str, Any]]] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """Assert facts into the logic cell (`data-grout/logic.remember`)."""
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"tag": tag, **kwargs}
        if facts is not None:
            params["facts"] = facts
        else:
            params["statement"] = statement
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.remember", params)
        )

    async def query(
        self,
        question: str,
        limit: int = 50,
        patterns: Optional[List[Dict[str, Any]]] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """Query the logic cell with natural language (`data-grout/logic.query`)."""
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"limit": limit, **kwargs}
        if patterns is not None:
            params["patterns"] = patterns
        else:
            params["question"] = question
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.query", params)
        )

    async def forget(
        self,
        handles: Optional[List[str]] = None,
        pattern: Optional[str] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """Retract facts from the logic cell (`data-grout/logic.forget`)."""
        self._client._ensure_initialized()
        params: Dict[str, Any] = {**kwargs}
        if handles:
            params["handles"] = handles
        if pattern:
            params["pattern"] = pattern
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.forget", params)
        )

    async def reflect(
        self,
        entity: Optional[str] = None,
        summary_only: bool = False,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """Reflect on the logic cell (`data-grout/logic.reflect`)."""
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"summary_only": summary_only, **kwargs}
        if entity:
            params["entity"] = entity
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.reflect", params)
        )

    async def constrain(
        self,
        rule: str,
        tag: str = "constraint",
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """Add a constraint rule (`data-grout/logic.constrain`)."""
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"rule": rule, "tag": tag, **kwargs}
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.constrain", params)
        )

    async def hydrate(self, params: Dict[str, Any]) -> Any:
        """Hydrate the logic cell from external data (`data-grout/logic.hydrate`)."""
        self._client._warn_if_not_dg("logic.hydrate")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.hydrate", params)
        )

    async def export_cell(self, params: Optional[Dict[str, Any]] = None) -> Any:
        """Export the logic cell contents (`data-grout/logic.export`)."""
        self._client._warn_if_not_dg("logic.export")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.export", params or {})
        )

    async def import_cell(self, params: Dict[str, Any]) -> Any:
        """Import facts into the logic cell (`data-grout/logic.import`)."""
        self._client._warn_if_not_dg("logic.import")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.import", params)
        )

    async def tabulate(self, params: Optional[Dict[str, Any]] = None) -> Any:
        """Tabulate logic cell contents (`data-grout/logic.tabulate`)."""
        self._client._warn_if_not_dg("logic.tabulate")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.tabulate", params or {})
        )

    async def worlds(self, params: Dict[str, Any]) -> Any:
        """Manage hypothetical worlds (`data-grout/logic.worlds`)."""
        self._client._warn_if_not_dg("logic.worlds")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/logic.worlds", params)
        )
