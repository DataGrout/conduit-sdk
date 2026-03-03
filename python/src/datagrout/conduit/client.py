"""DataGrout Conduit client implementation."""

import logging
import warnings
from pathlib import Path
from typing import Any, Dict, List, Optional, Union

from .identity import ConduitIdentity
from .transports import Transport, MCPTransport, JSONRPCTransport
from .types import DiscoverResult, PerformResult, GuideState, GuideOptions, ToolInfo
from .registration import Receipt

logger = logging.getLogger(__name__)


def is_dg_url(url: str) -> bool:
    """Return ``True`` when *url* points at a DataGrout-managed endpoint."""
    return (
        "datagrout.ai" in url
        or "datagrout.dev" in url
        or "CONDUIT_IS_DG" in __import__("os").environ
    )


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

    def __init__(
        self,
        url: str,
        auth: Optional[Dict[str, Any]] = None,
        use_intelligent_interface: Optional[bool] = None,
        transport: str = "mcp",
        identity: Optional[ConduitIdentity] = None,
        identity_auto: bool = False,
        identity_dir: Optional[str] = None,
        disable_mtls: bool = False,
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
                list.  Defaults to ``True`` for DataGrout URLs, ``False`` otherwise.
                Pass explicitly to override.
            transport: Transport mode ("mcp" or "jsonrpc").
            identity: Explicit mTLS identity (client certificate + key).
            identity_auto: Auto-discover an mTLS identity from env vars / ~/.conduit/.
            identity_dir: Custom directory for identity storage/discovery.  Overrides
                the default ``~/.conduit/``.  Useful for running multiple agents on
                the same machine with distinct identities.
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
        self._is_dg = is_dg_url(url)
        self.use_intelligent_interface = use_intelligent_interface if use_intelligent_interface is not None else self._is_dg
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
        self._initialized = False
        self._max_retries = kwargs.pop("max_retries", 3)

        # Resolve identity: explicit > identity_auto flag > DG URL auto-discover.
        # For DG URLs, silently try auto-discovery unless disabled or already set.
        _id_dir = Path(identity_dir) if identity_dir else None
        resolved_identity = identity
        if resolved_identity is None and identity_auto:
            resolved_identity = ConduitIdentity.try_discover(_id_dir)
        if resolved_identity is None and self._is_dg and not disable_mtls:
            resolved_identity = ConduitIdentity.try_discover(_id_dir)

        # Initialize transport
        if transport == "mcp":
            self._transport: Transport = MCPTransport(url, auth=auth, identity=resolved_identity, **kwargs)
        elif transport == "jsonrpc":
            # When the user passes an MCP URL (ending in /mcp), transparently
            # rewrite the path to the DG JSONRPC endpoint (/rpc).
            rpc_url = url[:-4] + "/rpc" if url.endswith("/mcp") else url
            self._transport = JSONRPCTransport(rpc_url, auth=auth, identity=resolved_identity, **kwargs)
        else:
            raise ValueError(f"Unknown transport: {transport}")

    async def connect(self) -> None:
        """Establish connection to the server.

        Can be used instead of the ``async with`` context manager pattern
        when explicit lifecycle control is needed.  Pair with :meth:`disconnect`.
        """
        await self._transport.connect()
        self._initialized = True

    async def disconnect(self) -> None:
        """Close the connection.

        Safe to call even if already disconnected.
        """
        if hasattr(self._transport, "disconnect"):
            await self._transport.disconnect()
        self._initialized = False

    async def __aenter__(self) -> "Client":
        """Async context manager entry."""
        await self.connect()
        return self

    async def __aexit__(self, *args: Any) -> None:
        """Async context manager exit."""
        await self.disconnect()

    def _ensure_initialized(self) -> None:
        if not self._initialized:
            raise RuntimeError(
                "Client not initialized. Call connect() first or use 'async with'."
            )

    async def _send_with_retry(self, fn: Any) -> Any:
        """Wrap a transport call with automatic retry on 'not initialized' errors.

        Retries up to ``_max_retries`` times (default 3) with 500 ms backoff
        between attempts, matching the Rust reference implementation.
        """
        import asyncio

        retries = self._max_retries
        while True:
            try:
                return await fn()
            except Exception as e:
                is_not_init = (
                    getattr(e, "code", None) == -32002
                    or "not initialized" in str(e).lower()
                )
                if is_not_init and retries > 0:
                    retries -= 1
                    await self.connect()
                    await asyncio.sleep(0.5)
                    continue
                raise

    # ===== Bootstrap / seamless mTLS =====

    @classmethod
    async def bootstrap_identity(
        cls,
        url: str,
        auth_token: str,
        name: str,
        substrate_endpoint: str = "https://app.datagrout.ai/api/v1/substrate/identity",
        identity_dir: Optional[str] = None,
        **client_kwargs: Any,
    ) -> "Client":
        """Create a :class:`Client` with an mTLS identity bootstrapped automatically.

        Checks the auto-discovery chain first (``identity_dir`` → env vars →
        ``CONDUIT_IDENTITY_DIR`` → ``~/.conduit/``).  If an existing identity
        is found and not within 7 days of expiry it is reused.  Otherwise a new
        keypair is generated, registered with DataGrout using the provided
        access token, and saved locally for future runs.

        After the first successful bootstrap the token is no longer needed —
        mTLS handles authentication on every subsequent run.

        Args:
            url: MCP server URL.
            auth_token: Any valid DG access token (used only for the first
                registration).
            name: Human-readable label for this Substrate instance.
            substrate_endpoint: DataGrout identity API base URL.
            identity_dir: Custom directory for identity persistence.  Overrides
                the default ``~/.conduit/``.
            **client_kwargs: Additional keyword arguments passed to :class:`Client`.

        Returns:
            A :class:`Client` configured with the bootstrapped mTLS identity.

        Example::

            # First run: token needed for registration
            client = await Client.bootstrap_identity(
                url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
                auth_token="my-access-token",
                name="my-laptop",
            )

            # Subsequent runs: no token needed, mTLS auto-discovered
            client = Client("https://gateway.datagrout.ai/servers/{uuid}/mcp")
        """
        from .registration import (
            ConduitIdentity,
            DEFAULT_IDENTITY_DIR,
            generate_keypair,
            register_identity,
            save_identity,
        )

        _id_dir = Path(identity_dir) if identity_dir else None

        # Fast path: existing valid identity.
        existing = ConduitIdentity.try_discover(_id_dir)
        if existing is not None and not existing.needs_rotation(7):
            return cls(url, identity=existing, identity_dir=identity_dir, **client_kwargs)

        # Slow path: generate, register, persist.
        keypair = generate_keypair(name)
        identity, _resp = await register_identity(
            keypair,
            endpoint=substrate_endpoint,
            auth_token=auth_token,
            name=name,
        )
        save_dir = _id_dir or DEFAULT_IDENTITY_DIR
        save_identity(identity, save_dir)
        return cls(url, identity=identity, identity_dir=identity_dir, **client_kwargs)

    @classmethod
    async def bootstrap_identity_oauth(
        cls,
        url: str,
        client_id: str,
        client_secret: str,
        name: str,
        identity_dir: Optional[str] = None,
        **client_kwargs: Any,
    ) -> "Client":
        """Bootstrap mTLS identity using OAuth 2.1 ``client_credentials``.

        Like :meth:`bootstrap_identity` but performs the OAuth token exchange
        inline — no pre-obtained token needed.

        Args:
            url: MCP server URL.
            client_id: OAuth client ID.
            client_secret: OAuth client secret.
            name: Human-readable label for this Substrate instance.
            identity_dir: Custom directory for identity persistence.
            **client_kwargs: Additional keyword arguments passed to :class:`Client`.

        Example::

            client = await Client.bootstrap_identity_oauth(
                url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
                client_id="my_id",
                client_secret="my_secret",
                name="my-laptop",
            )
        """
        from .oauth import OAuthTokenProvider, derive_token_endpoint

        token_endpoint = derive_token_endpoint(url)
        provider = OAuthTokenProvider(client_id, client_secret, token_endpoint)
        token = await provider.get_token()
        return await cls.bootstrap_identity(
            url, token, name, identity_dir=identity_dir, **client_kwargs
        )

    # ===== Standard MCP API (Drop-in Compatible) =====

    async def list_tools(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available tools with automatic pagination.

        When ``use_intelligent_interface=True``, filters out third-party
        integration tools (those whose name contains ``@``) and returns only
        DataGrout's meta-tools (including Arbiter, Governor).  Agents using the
        intelligent interface call :meth:`discover` instead of enumerating raw
        integrations.

        Returns:
            List of tool definitions.
        """
        self._ensure_initialized()

        async def _do() -> List[Dict[str, Any]]:
            all_tools: List[Dict[str, Any]] = []
            cursor: Optional[str] = None
            while True:
                params = {**kwargs}
                if cursor:
                    params["cursor"] = cursor
                response = await self._transport.list_tools(**params)
                if isinstance(response, list):
                    all_tools.extend(response)
                    break
                tools = response.get("tools", [])
                all_tools.extend(tools)
                cursor = response.get("nextCursor")
                if not cursor:
                    break
            if self.use_intelligent_interface:
                all_tools = [t for t in all_tools if "@" not in t.get("name", "")]
            return all_tools

        return await self._send_with_retry(_do)

    async def call_tool(
        self, name: str, arguments: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """
        Call a tool (standard MCP ``tools/call``).

        Uses the standard MCP path so non-DataGrout servers work correctly.
        For DataGrout-tracked execution, use :meth:`perform` instead.

        Args:
            name: Tool name (e.g., "salesforce@1/get_lead@1")
            arguments: Tool arguments

        Returns:
            Tool execution result
        """
        self._ensure_initialized()
        return await self._send_with_retry(
            lambda: self._transport.call_tool(name, arguments, **kwargs)
        )

    async def list_resources(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available resources (standard MCP method)."""
        self._ensure_initialized()
        return await self._send_with_retry(
            lambda: self._transport.list_resources(**kwargs)
        )

    async def read_resource(self, uri: str, **kwargs: Any) -> Any:
        """Read a resource (standard MCP method)."""
        self._ensure_initialized()
        return await self._send_with_retry(
            lambda: self._transport.read_resource(uri, **kwargs)
        )

    async def list_prompts(self, **kwargs: Any) -> List[Dict[str, Any]]:
        """List available prompts (standard MCP method)."""
        self._ensure_initialized()
        return await self._send_with_retry(
            lambda: self._transport.list_prompts(**kwargs)
        )

    async def get_prompt(
        self, name: str, arguments: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> Any:
        """Get a prompt (standard MCP method)."""
        self._ensure_initialized()
        return await self._send_with_retry(
            lambda: self._transport.get_prompt(name, arguments, **kwargs)
        )

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

        Converts natural language to symbolic facts and stores them durably.
        The server uses Prolog for storage. Facts persist across sessions and
        can be queried zero-token.

        Args:
            statement: Natural language statement to remember
            tag: Tag/namespace for grouping facts (e.g. 'crm', 'project')
            facts: Optional pre-structured fact list instead of NL statement

        Returns:
            Dict with handles, facts, and count
        """
        self._ensure_initialized()
        params: Dict[str, Any] = {"tag": tag, **kwargs}
        if facts is not None:
            params["facts"] = facts
        else:
            params["statement"] = statement

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/logic.remember", params)
        )

    async def query_cell(
        self,
        question: str,
        limit: int = 50,
        patterns: Optional[List[Dict[str, Any]]] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        """
        Query the agent's logic cell with natural language.

        Translates question to query patterns and queries the cell.
        Retrieval itself uses zero tokens.

        Args:
            question: Natural language question
            limit: Maximum results
            patterns: Optional pre-built pattern list

        Returns:
            Dict with results, total, and description
        """
        self._ensure_initialized()
        params: Dict[str, Any] = {"limit": limit, **kwargs}
        if patterns is not None:
            params["patterns"] = patterns
        else:
            params["question"] = question

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/logic.query", params)
        )

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
        self._ensure_initialized()
        params: Dict[str, Any] = {**kwargs}
        if handles:
            params["handles"] = handles
        if pattern:
            params["pattern"] = pattern

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/logic.forget", params)
        )

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
        self._ensure_initialized()
        params: Dict[str, Any] = {"summary_only": summary_only, **kwargs}
        if entity:
            params["entity"] = entity

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/logic.reflect", params)
        )

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
            Dict with handle, name, and constraint rule text
        """
        self._ensure_initialized()
        params: Dict[str, Any] = {"rule": rule, "tag": tag, **kwargs}
        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/logic.constrain", params)
        )

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
        self._ensure_initialized()
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

        result = await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/discovery.discover", params)
        )

        # DG returns "results" + "goal_used"; normalise to the SDK's field names.
        raw_tools = result.get("results") or result.get("tools") or []
        return DiscoverResult(
            query_used=result.get("goal_used") or result.get("query_used") or "",
            results=[
                ToolInfo(
                    tool_name=t.get("tool_name") or t.get("name") or "",
                    integration=t.get("integration") or "",
                    server_id=t.get("server"),
                    score=t.get("score"),
                    distance=t.get("distance"),
                    description=t.get("description"),
                    input_schema=t.get("input_contract") or t.get("input_schema"),
                    output_schema=t.get("output_contract") or t.get("output_schema"),
                )
                for t in raw_tools
            ],
            total=len(raw_tools),
            limit=limit,
        )

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
        self._ensure_initialized()
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
        self._ensure_initialized()
        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/discovery.perform", calls, **kwargs)
        )

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
        self._ensure_initialized()
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

        result = await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/discovery.guide", params)
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
        self._ensure_initialized()
        self._warn_if_not_dg("flow_into")
        params = {
            "plan": plan,
            "validate_ctc": validate_ctc,
            "save_as_skill": save_as_skill,
            **kwargs,
        }

        if input_data:
            params["input_data"] = input_data

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/flow.into", params)
        )

    async def prism_focus(
        self,
        data: Any,
        source_type: str,
        target_type: str,
        source_annotations: Optional[Dict[str, Any]] = None,
        target_annotations: Optional[Dict[str, Any]] = None,
        context: Optional[str] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Semantic type transformation (DataGrout-native).

        Args:
            data: Data to transform
            source_type: Source type annotation (e.g., "crm.lead@1")
            target_type: Target type annotation (e.g., "billing.customer@1")
            source_annotations: Optional extra annotations for the source type
            target_annotations: Optional extra annotations for the target type
            context: Optional natural language context hint for the transformation

        Returns:
            Transformed data
        """
        self._warn_if_not_dg("prism_focus")
        self._ensure_initialized()
        params: Dict[str, Any] = {
            "data": data,
            "source_type": source_type,
            "target_type": target_type,
        }
        if source_annotations:
            params["source_annotations"] = source_annotations
        if target_annotations:
            params["target_annotations"] = target_annotations
        if context:
            params["context"] = context

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/prism.focus", params)
        )

    async def plan(
        self,
        goal: Optional[str] = None,
        query: Optional[str] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Plan tool execution for a goal (DataGrout-native).

        At least one of *goal* or *query* must be provided.

        Args:
            goal: Natural language goal description
            query: Alternative short search query
            **kwargs: Optional server, k, policy, have, return_call_handles,
                expose_virtual_skills, model_overrides

        Returns:
            Planning result with suggested call sequence
        """
        if goal is None and query is None:
            raise ValueError("At least one of 'goal' or 'query' must be provided")
        self._warn_if_not_dg("plan")
        self._ensure_initialized()
        params: Dict[str, Any] = {}
        if goal is not None:
            params["goal"] = goal
        if query is not None:
            params["query"] = query
        _PLAN_OPTS = (
            "server", "k", "policy", "have",
            "return_call_handles", "expose_virtual_skills", "model_overrides",
        )
        for key in _PLAN_OPTS:
            if key in kwargs:
                params[key] = kwargs.pop(key)

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/discovery.plan", params)
        )

    async def refract(
        self,
        goal: str,
        payload: Any,
        verbose: bool = False,
        chart: bool = False,
        **kwargs: Any,
    ) -> Any:
        """
        Refract (analyse/transform) a payload toward a goal (DataGrout-native).

        Args:
            goal: Natural language transformation or analysis goal
            payload: Input data to refract
            verbose: Return intermediate reasoning steps
            chart: Include a chart in the output

        Returns:
            Refracted result
        """
        self._warn_if_not_dg("refract")
        self._ensure_initialized()
        params: Dict[str, Any] = {
            "goal": goal,
            "payload": payload,
            "verbose": verbose,
            "chart": chart,
            **kwargs,
        }
        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/prism.refract", params)
        )

    async def chart(
        self,
        goal: str,
        payload: Any,
        **kwargs: Any,
    ) -> Any:
        """
        Generate a chart from data (DataGrout-native).

        Args:
            goal: Natural language description of the desired chart
            payload: Input data to visualise
            **kwargs: Optional format, chart_type, title, x_label, y_label,
                width, height

        Returns:
            Chart result (format depends on server config)
        """
        self._warn_if_not_dg("chart")
        self._ensure_initialized()
        params: Dict[str, Any] = {"goal": goal, "payload": payload}
        _CHART_OPTS = (
            "format", "chart_type", "title", "x_label", "y_label", "width", "height",
        )
        for key in _CHART_OPTS:
            if key in kwargs:
                params[key] = kwargs.pop(key)

        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/prism.chart", params)
        )

    async def render(
        self,
        goal: str,
        payload: Any = None,
        format: str = "markdown",
        sections: Optional[List[Dict[str, Any]]] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Generate a document toward a natural-language goal (DataGrout-native).

        The server chooses the best rendering strategy for the target format.
        Supported formats include markdown, html, pdf, json.

        Args:
            goal: Natural language description of the content to generate
            payload: Input data to base the content on
            format: Output format (markdown, html, pdf, json)
            sections: Optional list of section specs (id, goal, data, type)
            **kwargs: Additional options passed to the tool

        Returns:
            Generated content (structure depends on format and server)
        """
        self._warn_if_not_dg("render")
        self._ensure_initialized()
        params: Dict[str, Any] = {"goal": goal, "format": format, **kwargs}
        if payload is not None:
            params["payload"] = payload
        if sections is not None:
            params["sections"] = sections
        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/prism.render", params)
        )

    async def export(
        self,
        content: Any,
        format: str,
        style: Optional[Dict[str, Any]] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Convert content to another format (DataGrout-native).

        Fast format conversion without LLM. Supports pdf, json, csv, xlsx,
        html, markdown, xml, latex, ndjson, yaml, txt.

        Args:
            content: Data or string to export
            format: Target format (e.g. "csv", "xlsx", "pdf")
            style: Optional styling (theme, page_size, font_size, etc.)
            metadata: Optional document metadata (title, author, etc.)
            **kwargs: Format-specific options (e.g. csv_delimiter)

        Returns:
            Dict with output, format, size_bytes, and metadata
        """
        self._warn_if_not_dg("export")
        self._ensure_initialized()
        params: Dict[str, Any] = {"content": content, "format": format, **kwargs}
        if style is not None:
            params["style"] = style
        if metadata is not None:
            params["metadata"] = metadata
        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/prism.export", params)
        )

    async def request_approval(
        self,
        action: str,
        details: Optional[Dict[str, Any]] = None,
        reason: Optional[str] = None,
        context: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Pause workflow for human approval (DataGrout-native).

        Use when an operation is destructive or policy requires confirmation.
        Execution blocks until the user approves, rejects, or modifies.

        Args:
            action: Name of the action (e.g. "create_invoice", "delete_record")
            details: Action-specific payload (amount, customer, etc.)
            reason: Why approval is being requested
            context: Workflow context (workflow_id, step, etc.)
            **kwargs: Additional params for the tool

        Returns:
            Approval result (status, decision, etc.)
        """
        self._warn_if_not_dg("request_approval")
        self._ensure_initialized()
        params: Dict[str, Any] = {"action": action, **kwargs}
        if details is not None:
            params["details"] = details
        if reason is not None:
            params["reason"] = reason
        if context is not None:
            params["context"] = context
        return await self._send_with_retry(
            lambda: self._transport.call_tool(
                "data-grout/flow.request-approval", params
            )
        )

    async def request_feedback(
        self,
        missing_fields: List[str],
        reason: str,
        current_data: Optional[Dict[str, Any]] = None,
        suggestions: Optional[Dict[str, Any]] = None,
        context: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> Any:
        """
        Request user clarification for missing fields (DataGrout-native).

        Pauses workflow until the user provides values for the required fields.

        Args:
            missing_fields: List of field names that need values
            reason: Why this information is needed
            current_data: Data already collected (for context)
            suggestions: Optional suggested options per field
            context: Workflow context
            **kwargs: Additional params for the tool

        Returns:
            Feedback result (status, provided_data, feedback_id)
        """
        self._warn_if_not_dg("request_feedback")
        self._ensure_initialized()
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
        return await self._send_with_retry(
            lambda: self._transport.call_tool(
                "data-grout/flow.request-feedback", params
            )
        )

    async def execution_history(
        self,
        limit: int = 50,
        offset: int = 0,
        status: Optional[str] = None,
        refractions_only: bool = False,
        **kwargs: Any,
    ) -> Any:
        """
        List recent tool executions for the current server (DataGrout-native).

        Args:
            limit: Max results (default 50, max 500)
            offset: Pagination offset
            status: Filter by success, error, or timeout
            refractions_only: Only show refraction executions
            **kwargs: Additional params for the tool

        Returns:
            Dict with executions list, count, limit, offset
        """
        self._warn_if_not_dg("execution_history")
        self._ensure_initialized()
        params: Dict[str, Any] = {
            "limit": limit,
            "offset": offset,
            "refractions_only": refractions_only,
            **kwargs,
        }
        if status is not None:
            params["status"] = status
        return await self._send_with_retry(
            lambda: self._transport.call_tool(
                "data-grout/inspect.execution-history", params
            )
        )

    async def execution_details(self, execution_id: str, **kwargs: Any) -> Any:
        """
        Get details and transcript for a specific execution (DataGrout-native).

        Args:
            execution_id: Unique execution ID (from execution_history or MCP)
            **kwargs: Additional params for the tool

        Returns:
            Dict with execution object and found flag
        """
        self._warn_if_not_dg("execution_details")
        self._ensure_initialized()
        params: Dict[str, Any] = {"execution_id": execution_id, **kwargs}
        return await self._send_with_retry(
            lambda: self._transport.call_tool(
                "data-grout/inspect.execution-details", params
            )
        )

    async def dg(
        self,
        tool_short_name: str,
        params: Optional[Dict[str, Any]] = None,
    ) -> Any:
        """
        Call any DataGrout first-party tool by its short name.

        Equivalent to ``call_tool("data-grout/<tool_short_name>", params)``.

        Args:
            tool_short_name: Tool short name without the ``data-grout/`` prefix
                (e.g., ``"prism.render"``, ``"discovery.plan"``).
            params: Optional parameters dict to pass to the tool.

        Returns:
            Tool result

        Example::

            result = await client.dg("prism.render", {"payload": data, "goal": "summary"})
        """
        self._ensure_initialized()
        method = f"data-grout/{tool_short_name}"
        _params = params or {}
        return await self._send_with_retry(
            lambda: self._transport.call_tool(method, _params)
        )

    async def estimate_cost(self, tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Get cost estimate before execution.

        Args:
            tool: Tool name
            args: Tool arguments

        Returns:
            Cost estimate with breakdown
        """
        self._ensure_initialized()
        estimate_args = {**args, "estimate_only": True}
        return await self._send_with_retry(
            lambda: self._transport.call_tool(tool, estimate_args)
        )

    # ===== Internal Helpers =====

    async def _perform_with_tracking(
        self, tool: str, args: Dict[str, Any], **kwargs: Any
    ) -> Any:
        """Execute tool via discovery.perform and track receipt."""
        params = {"tool": tool, "args": args, **kwargs}
        return await self._send_with_retry(
            lambda: self._transport.call_tool("data-grout/discovery.perform", params)
        )

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
                "description": "Guided workflow navigation",
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
                        "data": {},
                        "lens": {"type": "string"},
                    },
                    "required": ["data"],
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
