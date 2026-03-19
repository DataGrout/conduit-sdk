"""Prism namespace — data transformation, charting, rendering, and export."""

from typing import Any, Dict, List, Optional


class PrismNamespace:
    """Data transformation, charting, rendering, and type bridging."""

    def __init__(self, client: Any):
        self._client = client

    async def refract(
        self,
        goal: str,
        payload: Any,
        *,
        verbose: bool = False,
        chart: bool = False,
        **kwargs: Any,
    ) -> Any:
        """AI-driven data transformation (`data-grout/prism.refract`)."""
        self._client._warn_if_not_dg("prism.refract")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {
            "goal": goal,
            "payload": payload,
            "verbose": verbose,
            "chart": chart,
            **kwargs,
        }
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/prism.refract", params)
        )

    async def chart(
        self,
        goal: str,
        payload: Any,
        **kwargs: Any,
    ) -> Any:
        """AI-driven charting (`data-grout/prism.chart`)."""
        self._client._warn_if_not_dg("prism.chart")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"goal": goal, "payload": payload, **kwargs}
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/prism.chart", params)
        )

    async def render(
        self,
        goal: str,
        payload: Optional[Any] = None,
        *,
        format: str = "markdown",
        sections: Optional[List[str]] = None,
        **kwargs: Any,
    ) -> Any:
        """Generate a document toward a natural-language goal (`data-grout/prism.render`)."""
        self._client._warn_if_not_dg("prism.render")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"goal": goal, "format": format, **kwargs}
        if payload is not None:
            params["payload"] = payload
        if sections is not None:
            params["sections"] = sections
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/prism.render", params)
        )

    async def export(
        self,
        content: Any,
        format: str,
        *,
        style: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """Convert content to another format (`data-grout/prism.export`)."""
        self._client._warn_if_not_dg("prism.export")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"content": content, "format": format, **kwargs}
        if style is not None:
            params["style"] = style
        if metadata is not None:
            params["metadata"] = metadata
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/prism.export", params)
        )

    async def focus(
        self,
        data: Any,
        source_type: str,
        target_type: str,
        **kwargs: Any,
    ) -> Any:
        """Semantic type transformation (`data-grout/prism.focus`)."""
        self._client._warn_if_not_dg("prism.focus")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {
            "data": data,
            "source_type": source_type,
            "target_type": target_type,
            **kwargs,
        }
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/prism.focus", params)
        )
