"""Flow namespace — orchestration, routing, approvals, and execution history."""

from typing import Any, Dict, List, Optional


class FlowNamespace:
    """Multi-step orchestration, conditional routing, human-in-the-loop gates,
    and execution history."""

    def __init__(self, client: Any):
        self._client = client

    async def run(
        self,
        plan: List[Dict[str, Any]],
        *,
        validate_ctc: bool = True,
        save_as_skill: bool = False,
        input_data: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """Execute a multi-step workflow plan (`data-grout/flow.into`)."""
        self._client._warn_if_not_dg("flow.into")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {
            "plan": plan,
            "validate_ctc": validate_ctc,
            "save_as_skill": save_as_skill,
            **kwargs,
        }
        if input_data is not None:
            params["input_data"] = input_data
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/flow.into", params)
        )

    async def route(
        self,
        branches: List[Dict[str, Any]],
        *,
        payload: Optional[Any] = None,
        cache_ref: Optional[str] = None,
        else_target: Optional[Any] = None,
        **kwargs: Any,
    ) -> Any:
        """Conditional dispatch with predicate-based branching (`data-grout/flow.route`)."""
        self._client._warn_if_not_dg("flow.route")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"branches": branches, **kwargs}
        if payload is not None:
            params["payload"] = payload
        if cache_ref is not None:
            params["cache_ref"] = cache_ref
        if else_target is not None:
            params["else"] = else_target
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/flow.route", params)
        )

    async def request_approval(
        self,
        action: str,
        *,
        details: Optional[str] = None,
        reason: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """Pause workflow for human approval (`data-grout/flow.request-approval`)."""
        self._client._warn_if_not_dg("flow.request-approval")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {"action": action, **kwargs}
        if details is not None:
            params["details"] = details
        if reason is not None:
            params["reason"] = reason
        if context is not None:
            params["context"] = context
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/flow.request-approval", params)
        )

    async def request_feedback(
        self,
        missing_fields: List[str],
        reason: str,
        *,
        current_data: Optional[Dict[str, Any]] = None,
        suggestions: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """Request user clarification for missing fields (`data-grout/flow.request-feedback`)."""
        self._client._warn_if_not_dg("flow.request-feedback")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {
            "missing_fields": missing_fields,
            "reason": reason,
            **kwargs,
        }
        if current_data is not None:
            params["current_data"] = current_data
        if suggestions is not None:
            params["suggestions"] = suggestions
        if context is not None:
            params["context"] = context
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/flow.request-feedback", params)
        )

    async def history(
        self,
        *,
        limit: int = 20,
        offset: int = 0,
        status: Optional[str] = None,
        refractions_only: bool = False,
        **kwargs: Any,
    ) -> Any:
        """List recent tool executions (`data-grout/inspect.execution-history`)."""
        self._client._warn_if_not_dg("inspect.execution-history")
        self._client._ensure_initialized()
        params: Dict[str, Any] = {
            "limit": limit,
            "offset": offset,
            "refractions_only": refractions_only,
            **kwargs,
        }
        if status is not None:
            params["status"] = status
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool("data-grout/inspect.execution-history", params)
        )

    async def details(self, execution_id: str, **kwargs: Any) -> Any:
        """Get details for a specific execution (`data-grout/inspect.execution-details`)."""
        self._client._warn_if_not_dg("inspect.execution-details")
        self._client._ensure_initialized()
        return await self._client._send_with_retry(
            lambda: self._client._transport.call_tool(
                "data-grout/inspect.execution-details",
                {"execution_id": execution_id, **kwargs},
            )
        )
