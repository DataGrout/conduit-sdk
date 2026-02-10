"""DataGrout Conduit client implementation."""

from typing import Any, Dict, List, Optional, Union

from .transports import Transport, MCPTransport, JSONRPCTransport
from .types import Receipt, DiscoverResult, PerformResult, GuideState, GuideOptions


class GuidedSession:
    """Stateful guided workflow session."""

    def __init__(self, client: "Client", state: Dict[str, Any]):
        self._client = client
        self._state = GuideState(**state)

    @property
    def session_id(self) -> str:
        """Get session ID."""
        return self._state.session_id

    @property
    def status(self) -> str:
        """Get current status."""
        return self._state.status

    @property
    def options(self) -> List[GuideOptions]:
        """Get available options."""
        return self._state.options

    @property
    def result(self) -> Optional[Any]:
        """Get result if completed."""
        return self._state.result

    def get_state(self) -> GuideState:
        """Get full session state."""
        return self._state

    async def choose(self, option_id: str) -> "GuidedSession":
        """Choose an option and advance the workflow."""
        result = await self._client.guide(
            goal=None,  # Not needed for continuing session
            session_id=self.session_id,
            choice=option_id,
        )
        return result

    async def complete(self) -> Any:
        """Wait for workflow completion and return final result."""
        if self.status == "completed":
            return self.result

        # If not completed, this session needs more choices
        raise ValueError(
            f"Workflow not complete (status: {self.status}). "
            f"Call choose() with one of the available options."
        )


class Client:
    """DataGrout Conduit client - drop-in replacement for MCP clients."""

    # DataGrout first-party tools that should be exposed
    _DATAGROUT_TOOLS = [
        "data-grout/discovery.discover",
        "data-grout/discovery.perform",
        "data-grout/discovery.guide",
        "data-grout/flow.into",
        "data-grout/flow.request-approval",
        "data-grout/flow.request-feedback",
        "data-grout/prism.focus",
        "data-grout/prism.refract",
    ]

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        hide_3rd_party_tools: bool = True,
        transport: str = "jsonrpc",  # Default to jsonrpc since it's simpler
        **kwargs: Any,
    ):
        """
        Initialize DataGrout Conduit client.

        Args:
            url: Server URL (e.g., https://gateway.datagrout.ai/servers/{uuid}/mcp)
            auth: Authentication config (e.g., {"bearer": "token"})
            hide_3rd_party_tools: If True, list_tools() returns only DataGrout tools
            transport: Transport mode ("mcp" or "jsonrpc")
            **kwargs: Additional transport-specific options
        """
        self.url = url
        self.auth = auth
        self.hide_3rd_party_tools = hide_3rd_party_tools
        self._last_receipt: Optional[Receipt] = None

        # Initialize transport
        if transport == "mcp":
            self._transport: Transport = MCPTransport(url, auth=auth, **kwargs)
        elif transport == "jsonrpc":
            self._transport = JSONRPCTransport(url, auth=auth, **kwargs)
        else:
            raise ValueError(f"Unknown transport: {transport}")

    async def __aenter__(self) -> "Client":
        """Async context manager entry."""
        await self._transport.connect()
        return self

    async def __aexit__(self, *args: Any) -> None:
        """Async context manager exit."""
        await self._transport.disconnect()

    # ===== Standard MCP API (Drop-in Compatible) =====

    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """
        List available tools.

        With hide_3rd_party_tools=True (default), returns only DataGrout tools.
        Agent naturally uses discovery to find specific tools.

        Returns:
            List of tool definitions
        """
        if self.hide_3rd_party_tools:
            # Return only DataGrout gateway tools
            # In a real implementation, we'd fetch these from the server
            # For now, return a minimal set
            return await self._get_datagrout_tools()
        else:
            # Return full tool list from server
            return await self._transport.list_tools(**kwargs)

    async def call_tool(
        self, name: str, arguments: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """
        Call a tool (standard MCP method).

        Automatically routes through discovery.perform for tracking.

        Args:
            name: Tool name (e.g., "salesforce@1/get_lead@1")
            arguments: Tool arguments

        Returns:
            Tool execution result
        """
        # Route through discovery.perform for tracking
        return await self._perform_with_tracking(name, arguments, **kwargs)

    async def list_resources(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available resources (standard MCP method)."""
        return await self._transport.list_resources(**kwargs)

    async def read_resource(self, uri: str, **kwargs: Any) -> Any:
        """Read a resource (standard MCP method)."""
        return await self._transport.read_resource(uri, **kwargs)

    async def list_prompts(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available prompts (standard MCP method)."""
        return await self._transport.list_prompts(**kwargs)

    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> Any:
        """Get a prompt (standard MCP method)."""
        return await self._transport.get_prompt(name, arguments, **kwargs)

    # ===== DataGrout Extensions =====

    async def discover(
        self,
        query: Optional[str] = None,
        goal: Optional[str] = None,
        limit: int = 10,
        min_score: float = 0.0,
        integrations: Optional[List[str]] = None,
        servers: Optional[List[str]] = None,
        **kwargs: Any,
    ) -> DiscoverResult:
        """
        Semantic tool discovery (DataGrout-native).

        Args:
            query: Short search query
            goal: Natural language goal (alternative to query)
            limit: Maximum tools to return
            min_score: Minimum semantic score (0-1)
            integrations: Filter by integration keys
            servers: Filter by server IDs

        Returns:
            Discovery results with matching tools
        """
        params = {
            "limit": limit,
            "min_score": min_score,
            **kwargs,
        }

        if query:
            params["query"] = query
        if goal:
            params["goal"] = goal
        if integrations:
            params["integrations"] = integrations
        if servers:
            params["servers"] = servers

        result = await self._transport.call_tool(
            "data-grout/discovery.discover", params
        )

        return DiscoverResult(**result)

    async def perform(
        self,
        tool: str,
        args: Dict[str, Any],
        demux: bool = False,
        demux_mode: str = "strict",
        **kwargs: Any,
    ) -> Any:
        """
        Direct tool execution (DataGrout-native).

        Args:
            tool: Full tool name (e.g., "salesforce@1/get_lead@1")
            args: Tool arguments
            demux: Enable demultiplexing
            demux_mode: "strict" or "fuzzy"

        Returns:
            Tool execution result
        """
        return await self._perform_with_tracking(
            tool, args, demux=demux, demux_mode=demux_mode, **kwargs
        )

    async def perform_batch(
        self, calls: List[Dict[str, Any]], **kwargs: Any
    ) -> List[Any]:
        """
        Batch tool execution (DataGrout-native).

        Args:
            calls: List of {tool, args} dicts

        Returns:
            List of results (same order as calls)
        """
        result = await self._transport.call_tool(
            "data-grout/discovery.perform", calls, **kwargs
        )

        # Extract receipts if present
        if isinstance(result, list):
            for item in result:
                if isinstance(item, dict) and "_receipt" in item:
                    # Store last receipt (could track all in future)
                    self._last_receipt = Receipt(**item["_receipt"])

        return result

    async def guide(
        self,
        goal: Optional[str] = None,
        policy: Optional[Dict[str, Any]] = None,
        session_id: Optional[str] = None,
        choice: Optional[str] = None,
        **kwargs: Any,
    ) -> GuidedSession:
        """
        Start or continue guided workflow (DataGrout-native).

        Args:
            goal: Natural language goal (for new sessions)
            policy: Policy constraints (max_steps, max_cost, etc.)
            session_id: Existing session ID (to continue)
            choice: Option ID to choose (when continuing)

        Returns:
            GuidedSession instance
        """
        params = {**kwargs}

        if goal:
            params["goal"] = goal
        if policy:
            params["policy"] = policy
        if session_id:
            params["session_id"] = session_id
        if choice:
            params["choice"] = choice

        result = await self._transport.call_tool(
            "data-grout/discovery.guide", params
        )

        return GuidedSession(self, result)

    async def flow_into(
        self,
        plan: List[Dict[str, Any]],
        validate_ctc: bool = True,
        save_as_skill: bool = False,
        input_data: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Execute multi-step workflow (DataGrout-native).

        Args:
            plan: List of workflow steps
            validate_ctc: Generate CTC for formal verification
            save_as_skill: Save validated workflow as reusable skill
            input_data: Initial input data for workflow

        Returns:
            Workflow execution result
        """
        params = {
            "plan": plan,
            "validate_ctc": validate_ctc,
            "save_as_skill": save_as_skill,
            **kwargs,
        }

        if input_data:
            params["input_data"] = input_data

        result = await self._transport.call_tool("data-grout/flow.into", params)

        # Extract receipt if present
        if isinstance(result, dict) and "_receipt" in result:
            self._last_receipt = Receipt(**result["_receipt"])

        return result

    async def prism_focus(
        self,
        data: Dict[str, Any],
        source_type: str,
        target_type: str,
        **kwargs: Any,
    ) -> Any:
        """
        Semantic type transformation (DataGrout-native).

        Args:
            data: Data to transform
            source_type: Source semantic type (e.g., "crm.lead@1")
            target_type: Target semantic type (e.g., "billing.customer@1")

        Returns:
            Transformed data
        """
        params = {
            "data": data,
            "source_type": source_type,
            "target_type": target_type,
            **kwargs,
        }

        return await self._transport.call_tool("data-grout/prism.focus", params)

    # ===== Receipt & Credit Management =====

    def get_last_receipt(self) -> Optional[Receipt]:
        """
        Get receipt from last operation.

        Returns:
            Receipt object or None
        """
        return self._last_receipt

    async def estimate_cost(self, tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Get cost estimate before execution.

        Args:
            tool: Tool name
            args: Tool arguments

        Returns:
            Cost estimate with breakdown
        """
        estimate_args = {**args, "estimate_only": True}
        return await self._transport.call_tool(tool, estimate_args)

    # ===== Internal Helpers =====

    async def _perform_with_tracking(
        self, tool: str, args: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """
        Execute tool via discovery.perform and track receipt.

        This is called by call_tool() to add tracking to standard MCP calls.
        """
        params = {"tool": tool, "args": args, **kwargs}

        result = await self._transport.call_tool(
            "data-grout/discovery.perform", params
        )

        # Extract receipt if present in structured_content
        if isinstance(result, dict):
            # Check for receipt in various possible locations
            if "_receipt" in result:
                self._last_receipt = Receipt(**result["_receipt"])
                # Return result without receipt
                return {k: v for k, v in result.items() if k != "_receipt"}
            elif "structured_content" in result and "_receipt" in result["structured_content"]:
                self._last_receipt = Receipt(**result["structured_content"]["_receipt"])
                # Return the actual result
                return result["structured_content"].get("result", result)

        return result

    async def _get_datagrout_tools(self) -> List[Dict[str, Any]]:
        """
        Get DataGrout first-party tools only.

        This is returned when hide_3rd_party_tools=True.
        """
        # In a real implementation, these would be fetched from the server
        # For now, return minimal definitions
        return [
            {
                "name": "data-grout/discovery.discover",
                "description": "Semantic tool discovery with natural language queries",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "goal": {"type": "string"},
                        "limit": {"type": "integer", "default": 10},
                    },
                },
            },
            {
                "name": "data-grout/discovery.perform",
                "description": "Direct tool execution with credit tracking",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "tool": {"type": "string"},
                        "args": {"type": "object"},
                        "demux": {"type": "boolean", "default": False},
                    },
                    "required": ["tool", "args"],
                },
            },
            {
                "name": "data-grout/discovery.guide",
                "description": "Guided workflow navigation (MUD-style)",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "goal": {"type": "string"},
                        "policy": {"type": "object"},
                        "session_id": {"type": "string"},
                        "choice": {"type": "string"},
                    },
                },
            },
            {
                "name": "data-grout/flow.into",
                "description": "Multi-step workflow orchestration with CTCs",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "plan": {"type": "array"},
                        "validate_ctc": {"type": "boolean", "default": True},
                        "save_as_skill": {"type": "boolean", "default": False},
                    },
                    "required": ["plan"],
                },
            },
            {
                "name": "data-grout/prism.focus",
                "description": "Semantic type transformation",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "data": {"type": "object"},
                        "source_type": {"type": "string"},
                        "target_type": {"type": "string"},
                    },
                    "required": ["data", "source_type", "target_type"],
                },
            },
        ]
