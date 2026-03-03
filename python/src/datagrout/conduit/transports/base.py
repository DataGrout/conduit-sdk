"""Base transport interface."""

from abc import ABC, abstractmethod
from typing import Any, Dict, List, Optional


class Transport(ABC):
    """Abstract base class for transport implementations."""

    @abstractmethod
    async def connect(self) -> None:
        """Establish connection to server."""
        pass

    @abstractmethod
    async def disconnect(self) -> None:
        """Close connection to server."""
        pass

    @abstractmethod
    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available tools."""
        pass

    @abstractmethod
    async def call_tool(
        self, name: str, arguments: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """Call a tool with arguments."""
        pass

    @abstractmethod
    async def list_resources(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available resources."""
        pass

    @abstractmethod
    async def read_resource(self, uri: str, **kwargs: Any) -> Any:
        """Read a resource by URI."""
        pass

    @abstractmethod
    async def list_prompts(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available prompts."""
        pass

    @abstractmethod
    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> Any:
        """Get a prompt with optional arguments."""
        pass

    async def send_request(self, method: str, params: Any = None) -> Any:
        """Send a raw JSON-RPC request. Implemented by transports that support it."""
        raise NotImplementedError("This transport does not support send_request()")
