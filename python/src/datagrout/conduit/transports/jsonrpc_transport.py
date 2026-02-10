"""JSONRPC transport implementation using httpx."""

import uuid
from typing import Any, Dict, List, Optional

import httpx

from .base import Transport


class JSONRPCTransport(Transport):
    """Transport implementation using raw JSONRPC over HTTP."""

    def __init__(self, url: str, auth: Optional[Dict[str, Any]] = None, **kwargs: Any):
        self.url = url
        self.auth = auth or {}
        self.kwargs = kwargs
        self._client: Optional[httpx.AsyncClient] = None
        self._request_id = 0

    async def connect(self) -> None:
        """Establish HTTP connection."""
        headers = {}

        # Handle bearer token auth
        if "bearer" in self.auth:
            headers["Authorization"] = f"Bearer {self.auth['bearer']}"

        self._client = httpx.AsyncClient(
            base_url=self.url,
            headers=headers,
            timeout=30.0,
            **self.kwargs,
        )

    async def disconnect(self) -> None:
        """Close HTTP connection."""
        if self._client:
            await self._client.aclose()

    async def _call(self, method: str, params: Any = None) -> Any:
        """Make a JSONRPC call."""
        if not self._client:
            await self.connect()

        self._request_id += 1

        request = {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": params or {},
        }

        response = await self._client.post("/", json=request)
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
        params = {"name": name, "arguments": arguments, **kwargs}
        result = await self._call("tools/call", params)
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
