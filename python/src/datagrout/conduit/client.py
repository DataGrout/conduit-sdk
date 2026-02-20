"""DataGrout Conduit client implementation."""

import logging
import warnings
from typing import Any, Dict, List, Optional, Union

from .identity import ConduitIdentity
from .transports import Transport, MCPTransport, JSONRPCTransport
from .types import DiscoverResult, PerformResult, GuideState, GuideOptions
from .registration import Receipt

logger = logging.getLogger(__name__)


def is_dg_url(url: str) -> bool:
    """Return ``True`` when *url* points at a DataGrout-managed endpoint."""
    return "datagrout.ai" in url or "datagrout.dev" in url


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
        # Logic Cell — symbolic persistent memory
        "data-grout/logic.remember",
        "data-grout/logic.query",
        "data-grout/logic.forget",
        "data-grout/logic.constrain",
        "data-grout/logic.reflect",
    ]

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        use_intelligent_interface: bool = False,
        transport: str = "jsonrpc",  # Default to jsonrpc since it's simpler
        identity: Optional[ConduitIdentity] = None,
        identity_auto: bool = False,
        disable_mtls: bool = False,
        # Convenience shorthand for OAuth 2.1 client_credentials auth.
        client_id: Optional[str] = None,
        client_secret: Optional[str] = None,
        oauth_scope: Optional[str] = None,
        token_endpoint: Optional[str] = None,
        **kwargs: Any,
    ):
        """Initialize DataGrout Conduit client.

        Args:
            url: Server URL (e.g., https://gateway.datagrout.ai/servers/{uuid}/mcp)
            auth: Authentication config dict.  Supported keys:
                - ``{"bearer": "token"}`` — static Bearer token.
                - ``{"basic": {"username": "...", "password": "..."}}`` — Basic auth.
                - ``{"client_credentials": {"client_id": "...", "client_secret": "..."}}``
                  — OAuth 2.1 client credentials (see also *client_id* / *client_secret*).
            use_intelligent_interface: When ``True``, ``list_tools()`` returns only the
                DataGrout semantic discovery / execution tools instead of the raw MCP tool
                list.  Mirrors ``use_intelligent_interface`` on the server side.
            transport: Transport mode ("mcp" or "jsonrpc").
            identity: Explicit mTLS identity (client certificate + key).
            identity_auto: Auto-discover an mTLS identity from env vars / ~/.conduit/.
            disable_mtls: Opt out of automatic mTLS even for DataGrout URLs.
                Normally, DG URLs silently attempt auto-discovery of an mTLS identity.
                Set this to ``True`` to use token-only auth.
            client_id: Shorthand for OAuth ``client_credentials`` auth — client ID.
            client_secret: Shorthand for OAuth ``client_credentials`` auth — secret.
            oauth_scope: Optional scope for OAuth token requests.
            token_endpoint: Override the derived token endpoint URL.
            **kwargs: Additional transport-specific options.
        """
        self.url = url
        self.use_intelligent_interface = use_intelligent_interface
        self._is_dg = is_dg_url(url)
        self._dg_warned = False

        # Merge convenience client_id/client_secret kwargs into auth dict.
        if client_id and client_secret:
            cc: Dict[str, Any] = {
                "client_id": client_id,
                "client_secret": client_secret,
            }
            if oauth_scope:
                cc["scope"] = oauth_scope
            if token_endpoint:
                cc["token_endpoint"] = token_endpoint
            auth = dict(auth or {})
            auth["client_credentials"] = cc

        self.auth = auth

        # Resolve identity: explicit > identity_auto flag > DG URL auto-discover.
        # For DG URLs, silently try auto-discovery unless disabled or already set.
        resolved_identity = identity
        if resolved_identity is None and identity_auto:
            resolved_identity = ConduitIdentity.try_default()
        if resolved_identity is None and self._is_dg and not disable_mtls:
            resolved_identity = ConduitIdentity.try_default()

        # Initialize transport
        if transport == "mcp":
            self._transport: Transport = MCPTransport(url, auth=auth, **kwargs)
        elif transport == "jsonrpc":
            self._transport = JSONRPCTransport(url, auth=auth, identity=resolved_identity, **kwargs)
        else:
            raise ValueError(f"Unknown transport: {transport}")

    async def __aenter__(self) -> "Client":
        """Async context manager entry."""
        await self._transport.connect()
        return self

    async def __aexit__(self, *args: Any) -> None:
        """Async context manager exit."""
        await self._transport.disconnect()

    # ===== Bootstrap / seamless mTLS =====

    @classmethod
    async def bootstrap_identity(
        cls,
        url: str,
        api_key: str,
        name: str,
        substrate_endpoint: str,
        **client_kwargs: Any,
    ) -> "Client":
        """Create a :class:`Client` with an mTLS identity bootstrapped automatically.

        Checks the auto-discovery chain first (env vars → ``~/.conduit/``).
        If an existing identity is found and not within 7 days of expiry it is
        reused.  Otherwise a new keypair is generated, registered with DataGrout,
        and saved to ``~/.conduit/`` for future runs.

        This is the zero-friction path — call it once with the Arbiter API key
        and the client handles certificate management on every subsequent run.

        Args:
            url: MCP server URL.
            api_key: Arbiter API key (used only for the first registration).
            name: Human-readable label for this Substrate instance.
            substrate_endpoint: DataGrout identity API base URL,
                e.g. ``https://app.datagrout.ai/api/v1/substrate/identity``.
            **client_kwargs: Additional keyword arguments passed to :class:`Client`.

        Returns:
            A :class:`Client` configured with the bootstrapped mTLS identity.

        Example::

            client = await Client.bootstrap_identity(
                url="https://app.datagrout.ai/servers/{uuid}/mcp",
                api_key=os.environ["ARBITER_API_KEY"],
                name="my-agent",
                substrate_endpoint="https://app.datagrout.ai/api/v1/substrate/identity",
            )
        """
        from .registration import (
            ConduitIdentity,
            DEFAULT_IDENTITY_DIR,
            generate_keypair,
            register_identity,
            save_identity,
        )

        # Fast path: existing valid identity.
        existing = ConduitIdentity.try_default()
        if existing is not None and not existing.needs_rotation(7):
            return cls(url, identity=existing, **client_kwargs)

        # Slow path: generate, register, persist.
        keypair = generate_keypair(name)
        identity, _resp = await register_identity(
            keypair,
            endpoint=substrate_endpoint,
            api_key=api_key,
            name=name,
        )
        save_identity(identity, DEFAULT_IDENTITY_DIR)
        return cls(url, identity=identity, **client_kwargs)

    # ===== Standard MCP API (Drop-in Compatible) =====

    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available tools.

        When ``use_intelligent_interface=True``, filters out third-party
        integration tools (those whose name contains ``@``) and returns only
        DataGrout's own meta-tools (arbiter, governor, etc.).  Agents using the
        intelligent interface call :meth:`discover` instead of enumerating raw
        integrations.

        Returns:
            List of tool definitions.
        """
        tools = await self._transport.list_tools(**kwargs)
        if self.use_intelligent_interface:
            # Third-party integration tools use the integration@version/tool@version
            # naming scheme. DG's own tools (arbiter_*, governor_*) do not contain "@".
            tools = [t for t in tools if "@" not in t.get("name", "")]
        return tools

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

    # ===== Logic Cell Extensions =====

    async def remember(
        self,
        statement: str,
        tag: str = "default",
        facts: Optional[List[Dict[str, Any]]] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """
        Store facts in the agent's persistent logic cell.

        Converts natural language to symbolic Prolog facts and stores them
        durably. Facts persist across sessions and can be queried zero-token.

        Args:
            statement: Natural language statement to remember
            tag: Tag/namespace for grouping facts (e.g. 'crm', 'project')
            facts: Optional pre-structured fact list instead of NL statement

        Returns:
            Dict with handles, facts, and count
        """
        params: Dict[str, Any] = {"tag": tag, **kwargs}
        if facts is not None:
            params["facts"] = facts
        else:
            params["statement"] = statement

        return await self._transport.call_tool("data-grout/logic.remember", params)

    async def query_cell(
        self,
        question: str,
        limit: int = 50,
        patterns: Optional[List[Dict[str, Any]]] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """
        Query the agent's logic cell with natural language.

        Translates question to Prolog patterns and queries the cell.
        Retrieval itself uses zero tokens.

        Args:
            question: Natural language question
            limit: Maximum results
            patterns: Optional pre-built pattern list

        Returns:
            Dict with results, total, and description
        """
        params: Dict[str, Any] = {"limit": limit, **kwargs}
        if patterns is not None:
            params["patterns"] = patterns
        else:
            params["question"] = question

        return await self._transport.call_tool("data-grout/logic.query", params)

    async def forget(
        self,
        handles: Optional[List[str]] = None,
        pattern: Optional[str] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """
        Retract facts from the agent's logic cell.

        Args:
            handles: Specific fact handles to retract
            pattern: NL pattern — retract all facts mentioning this text

        Returns:
            Dict with retracted count and handles
        """
        params: Dict[str, Any] = {**kwargs}
        if handles:
            params["handles"] = handles
        if pattern:
            params["pattern"] = pattern

        return await self._transport.call_tool("data-grout/logic.forget", params)

    async def reflect(
        self,
        entity: Optional[str] = None,
        summary_only: bool = False,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """
        Reflect on the agent's logic cell — full snapshot or per-entity view.

        Args:
            entity: Optional entity name to scope reflection
            summary_only: If True, return only counts

        Returns:
            Dict with full cell summary or entity-scoped facts
        """
        params: Dict[str, Any] = {"summary_only": summary_only, **kwargs}
        if entity:
            params["entity"] = entity

        return await self._transport.call_tool("data-grout/logic.reflect", params)

    async def constrain(
        self,
        rule: str,
        tag: str = "constraint",
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """
        Store a logical rule or policy in the agent's logic cell.

        Args:
            rule: Natural language rule (e.g. 'VIP customers have ARR > $500K')
            tag: Tag/namespace for this constraint

        Returns:
            Dict with handle, name, and Prolog rule text
        """
        params: Dict[str, Any] = {"rule": rule, "tag": tag, **kwargs}
        return await self._transport.call_tool("data-grout/logic.constrain", params)

    # ===== DG-awareness helpers =====

    def _warn_if_not_dg(self, method: str) -> None:
        """Emit a one-time warning when a DG-specific method is used on a non-DG server."""
        if not self._is_dg and not self._dg_warned:
            self._dg_warned = True
            warnings.warn(
                f"`{method}` is a DataGrout-specific extension. "
                f"The connected server may not support it. "
                f"Standard MCP methods (list_tools, call_tool, …) work on any server.",
                stacklevel=3,
            )

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
        self._warn_if_not_dg("discover")
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
        self._warn_if_not_dg("perform")
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
        self._warn_if_not_dg("guide")
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
        self._warn_if_not_dg("flow_into")
        params = {
            "plan": plan,
            "validate_ctc": validate_ctc,
            "save_as_skill": save_as_skill,
            **kwargs,
        }

        if input_data:
            params["input_data"] = input_data

        result = await self._transport.call_tool("data-grout/flow.into", params)

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
        self._warn_if_not_dg("prism_focus")
        params = {
            "data": data,
            "source_type": source_type,
            "target_type": target_type,
            **kwargs,
        }

        return await self._transport.call_tool("data-grout/prism.focus", params)

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
        # Receipt is embedded in result["_meta"]["receipt"] — callers can use
        # extract_meta(result) to access it without any client-side state.
        return result

    async def _get_datagrout_tools_stub(self) -> List[Dict[str, Any]]:
        """Stub — not called. List is fetched from server and filtered."""
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
            {
                "name": "data-grout/logic.remember",
                "description": "Store facts in the agent's persistent logic cell using natural language",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "statement": {"type": "string"},
                        "tag": {"type": "string", "default": "default"},
                        "facts": {"type": "array"},
                    },
                },
            },
            {
                "name": "data-grout/logic.query",
                "description": "Query the agent's logic cell with natural language",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string"},
                        "limit": {"type": "integer", "default": 50},
                        "patterns": {"type": "array"},
                    },
                },
            },
            {
                "name": "data-grout/logic.forget",
                "description": "Retract facts from the agent's logic cell",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "handles": {"type": "array", "items": {"type": "string"}},
                        "pattern": {"type": "string"},
                    },
                },
            },
            {
                "name": "data-grout/logic.constrain",
                "description": "Store a logical rule or policy in the agent's logic cell",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "rule": {"type": "string"},
                        "tag": {"type": "string", "default": "constraint"},
                    },
                    "required": ["rule"],
                },
            },
            {
                "name": "data-grout/logic.reflect",
                "description": "Reflect on the agent's logic cell — full snapshot or per-entity view",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "entity": {"type": "string"},
                        "summary_only": {"type": "boolean", "default": False},
                    },
                },
            },
        ]
