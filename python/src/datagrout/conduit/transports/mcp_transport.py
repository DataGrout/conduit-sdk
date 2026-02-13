"""MCP transport implementation using official mcp package."""

from typing import Any, Dict, List, Optional

try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    from mcp.client.sse import sse_client

    HAS_MCP = True
except ImportError:
    HAS_MCP = False

from .base import Transport


class MCPTransport(Transport):
    """
    Transport using official MCP Python SDK.
    
    Uses Anthropic's official `mcp` package for standards-compliant communication.
    """

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ):
        """
        Initialize MCP transport.

        Args:
            url: Server URL (supports stdio, SSE, HTTP/HTTPS)
            auth: Authentication config
            **kwargs: Additional MCP client options
        """
        if not HAS_MCP:
            raise ImportError(
                "MCP SDK not installed. Install with: pip install mcp>=1.0.0"
            )

        self.url = url
        self.auth = auth or {}
        self.options = kwargs
        self._client: Optional[Any] = None
        self._session: Optional[ClientSession] = None

    async def connect(self) -> None:
        """Connect to MCP server using official SDK."""
        # Determine transport type from URL
        if self.url.startswith("stdio://"):
            # Stdio transport (local process)
            command = self.url.replace("stdio://", "")
            parts = command.split()
            server_params = StdioServerParameters(
                command=parts[0],
                args=parts[1:] if len(parts) > 1 else [],
                env=self.options.get("env"),
            )
            self._client = stdio_client(server_params)
            read_stream, write_stream = await self._client.__aenter__()
            self._session = ClientSession(read_stream, write_stream)
            await self._session.__aenter__()

        elif self.url.startswith(("http://", "https://")):
            # SSE transport (HTTP/HTTPS)
            headers = {}
            if "bearer" in self.auth:
                headers["Authorization"] = f"Bearer {self.auth['bearer']}"
            elif "api_key" in self.auth:
                headers["X-API-Key"] = self.auth["api_key"]

            self._client = sse_client(self.url, headers=headers or None)
            read_stream, write_stream = await self._client.__aenter__()
            self._session = ClientSession(read_stream, write_stream)
            await self._session.__aenter__()

        else:
            raise ValueError(f"Unsupported MCP URL scheme: {self.url}")

    async def disconnect(self) -> None:
        """Disconnect from MCP server."""
        if self._session:
            await self._session.__aexit__(None, None, None)
        if self._client:
            await self._client.__aexit__(None, None, None)

    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available tools."""
        if not self._session:
            raise RuntimeError("Not connected. Call connect() first.")

        result = await self._session.list_tools()
        return [tool.model_dump() for tool in result.tools]

    async def call_tool(self, name: str, arguments: Dict[str, Any], **kwargs: Any) -> Any:
        """Call a tool."""
        if not self._session:
            raise RuntimeError("Not connected. Call connect() first.")

        result = await self._session.call_tool(name, arguments)
        return result.content

    async def list_resources(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available resources."""
        if not self._session:
            raise RuntimeError("Not connected. Call connect() first.")

        result = await self._session.list_resources()
        return [resource.model_dump() for resource in result.resources]

    async def read_resource(self, uri: str, **kwargs: Any) -> Any:
        """Read a resource."""
        if not self._session:
            raise RuntimeError("Not connected. Call connect() first.")

        result = await self._session.read_resource(uri)
        return result.contents

    async def list_prompts(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available prompts."""
        if not self._session:
            raise RuntimeError("Not connected. Call connect() first.")

        result = await self._session.list_prompts()
        return [prompt.model_dump() for prompt in result.prompts]

    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> Any:
        """Get a prompt."""
        if not self._session:
            raise RuntimeError("Not connected. Call connect() first.")

        result = await self._session.get_prompt(name, arguments or {})
        return result.messages
