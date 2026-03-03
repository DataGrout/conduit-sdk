# Changelog

All notable changes to the DataGrout Conduit SDK will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

---

## [0.1.0] - 2026-03-02

Initial public release of the DataGrout Conduit SDK across five languages: Rust, TypeScript, Python, Elixir, and Ruby.

### Core

- **JSON-RPC 2.0 transport** — lightweight HTTP POST-based transport with full request/response handling, retry logic, and error mapping.
- **MCP transport** — Streamable HTTP / SSE transport for full MCP protocol compliance; supports `initialize`, `tools/list`, `tools/call`, session management, `Mcp-Session-Id` tracking, SSE response parsing, and `202 Accepted` handling.
- **Default transport: MCP** — all SDKs default to MCP transport. JSONRPC available as an explicit option.
- **Intelligent Interface** — auto-enabled for DataGrout endpoints; filters tool list to only non-integration tools (hides `@`-prefixed tools like `salesforce@1/get_lead@1`), exposing just `data-grout@1/discovery.discover@1` and `data-grout@1/discovery.perform@1`.
- **Bearer, Basic, API key, and OAuth authentication** — all auth types supported across both transports.
- **Rate limit handling** — typed `RateLimitError` with parsed `X-RateLimit-*` headers and `retry_after` for automatic backoff.
- **OAuth 401 retry** — automatic token refresh and request retry on 401 when OAuth is configured.
- **`list_tools` pagination** — loops with `cursor`/`nextCursor` to aggregate all pages from paginated servers.

### Semantic Discovery & Workflows

- **`discover()`** — semantic search over tool catalogs by intent, with score-based ranking, integration filtering, and configurable limits. Calls `data-grout/discovery.discover`.
- **`plan()`** — Prolog-backed workflow planner; returns ranked plans with required inputs and virtual skill handles. Calls `data-grout/discovery.plan`. Params: `goal` or `query` (required), plus `server`, `k`, `policy`, `have`, `return_call_handles`, `expose_virtual_skills`, `model_overrides`.
- **`perform()`** — tracked tool execution with optional demultiplexing. Calls `data-grout/discovery.perform`. Wire params: `tool`, `args`, `demux_mode`.
- **`guide()`** — interactive multi-step guided workflow sessions with branching choices. Calls `data-grout/discovery.guide`.
- **`flow_into()`** — validates and executes a workflow plan; can save result as a reusable skill with a CTC. Calls `data-grout/flow.into`.
- **`estimate_cost()`** — pre-execution credit estimate; injects `estimate_only: true` into the tool's own args and calls the target tool method directly.
- **`callTool()`** — standard MCP `tools/call` path, works with any MCP server.

### Prism: Data Transformation & Visualisation

- **`refract()`** — transform any data structure toward a natural-language goal; the plan is compiled and verified on first use and subsequent equivalent calls are served from cache. Calls `data-grout/prism.refract`. Required: `goal`, `payload`. Optional: `verbose`, `chart`.
- **`chart()`** — visualise any tool output as a chart (SVG, sparkline, Unicode, statistics). Calls `data-grout/prism.chart`. Required: `goal`, `payload`. Optional: `format`, `chart_type`, `title`, `x_label`, `y_label`, `width`, `height`.
- **`prism_focus()`** — semantic type bridge converting data between semio types. Calls `data-grout/prism.focus`. Params: `data`, `source_type`, `target_type`, plus optional `source_annotations`, `target_annotations`, `context`.
- `dg("prism.render", params)` — generate content (articles, reports, HTML, PDF, XLSX) from structured data.
- `dg("prism.export", params)` — format conversion without LLM (JSON → CSV → XLSX → LaTeX etc.).
- `dg("prism.paginate", params)` — page through large result sets by `cache_ref` or payload.
- `dg("prism.code_lens", params)` — transform source code into queryable semantic facts.
- `dg("prism.diff_analyzer", params)` — analyse code changes for alignment with a stated goal.
- `dg("prism.code_query", params)` — execute Prolog queries over lensed code facts.

### Logic Cell (Agent Memory)

- **`remember()`** — store natural-language facts in the persistent Logic Cell. Calls `data-grout/logic.remember`. Params: `statement` or `facts`, optional `tag`.
- **`query_cell()`** — query stored facts by natural language or pattern. Calls `data-grout/logic.query`. Params: `question` or `patterns`, optional `limit`.
- **`forget()`** — retract facts by handle list or pattern. Calls `data-grout/logic.forget`. Params: `handles` or `pattern`.
- **`constrain()`** — store logical rules/policies governing agent behaviour. Calls `data-grout/logic.constrain`. Params: `rule`, optional `tag`.
- **`reflect()`** — introspect all facts in the Logic Cell. Calls `data-grout/logic.reflect`. Optional: `entity`, `summary_only`.

### Flow & Inspect (via generic hook)

- `dg("flow.request-approval", params)` — pause for human approval before destructive operations.
- `dg("flow.request-feedback", params)` — request missing or clarifying information from the user.
- `dg("inspect.execution-history", params)` — list recent tool executions.
- `dg("inspect.execution-details", params)` — detailed info on a specific execution.
- `dg("inspect.ctc-executions", params)` — list executions tied to a specific CTC or skill.

### Generic Escape Hatch

- **`dg(shortName, params)`** — call any DataGrout first-party tool by its short name (e.g. `"prism.render"`). Automatically prefixes `data-grout/`. Future tools are accessible without SDK updates.

### Cost Tracking

- **`extract_meta()`** — extract the `_datagrout` metadata block from tool-call results (checks `_datagrout`, `_meta.datagrout`, and `_meta` keys), including receipts, credit estimates, and BYOK discount details.
- **Receipt type** — `receipt_id`, `transaction_id`, `estimated_credits`, `actual_credits`, `net_credits`, `savings`, `savings_bonus`, `balance_before`, `balance_after`, `breakdown`, `byok`.
- **CreditEstimate type** — `estimated_total`, `actual_total`, `net_total`, `breakdown`.
- **Byok type** — `enabled`, `discount_applied`, `discount_rate`.

### mTLS Identity Plane

- **`ConduitIdentity`** — load client certificates from PEM files, PEM byte strings, or PKCS#12 bundles. mTLS works across both MCP and JSONRPC transports.
- **Auto-discovery** — 5-step cascade: `override_dir` → `CONDUIT_MTLS_CERT`/`CONDUIT_MTLS_KEY` env vars → `CONDUIT_IDENTITY_DIR` → `~/.conduit/` → `.conduit/` relative to cwd.
- **Custom identity directories** — `identity_dir` option for running multiple agents on the same machine with separate certificates.
- **`needs_rotation?`** — check if identity certificate is approaching expiry.
- **`fetchWithIdentity()`** (TypeScript) / `fetch_with_identity()` (Python) — HTTP fetch helpers that attach the mTLS identity to any outgoing request.

### Identity Registration & Bootstrap

- **`generate_keypair()`** — ECDSA P-256 keypair generation (Rust: gated behind `registration` feature).
- **`register_identity()`** — send public key to the DataGrout CA, receive a DG-CA-signed X.509 certificate. Private key never leaves the client.
- **`rotate_identity()`** — mTLS-authenticated certificate renewal without needing an API key.
- **`bootstrap_identity()`** — one-call flow: generate keys, register with DG CA, save to disk, return a connected client.
- **`bootstrap_identity_oauth()`** — same flow using OAuth 2.1 `client_credentials` instead of a bearer token.
- **`save_identity_to_dir()`** — persist identity files with proper permissions (chmod 600 on Unix).
- **`refresh_ca_cert()`** — fetch the latest DG CA certificate for local pinning.

### OAuth 2.1

- **`OAuthTokenProvider`** — automatic token acquisition, caching, and refresh via the `client_credentials` grant.
- **`deriveTokenEndpoint()`** — resolves the OAuth token endpoint from `/.well-known/oauth-authorization-server` or falls back to a conventional path.
- **`invalidate()`** — clear cached token to force re-acquisition (used by 401 retry logic).

### Language-Specific Notes

**Rust** (`datagrout-conduit` crate)
- Builder pattern via `ClientBuilder` with `url()`, `auth_bearer()`, `transport()`, `with_identity()`, `with_identity_auto()`, `identity_dir()`, `bootstrap_identity()`.
- `registration` feature flag to opt-in to `rcgen`-based keypair generation.
- `PlanBuilder`, `RefractBuilder`, `ChartBuilder` follow the same `.execute().await` builder pattern as `DiscoverBuilder`.
- Logic cell methods (`remember`, `remember_facts`, `query_cell`, `query_cell_patterns`, `forget`, `forget_pattern`, `constrain`, `constrain_tagged`, `reflect`, `reflect_entity`) as direct async methods.
- `dg(short_name, params)` generic hook.
- 75 Rust tests across unit, integration, and transport suites. Seven runnable examples: `basic`, `discovery`, `guided_workflow`, `flow_orchestration`, `type_transformation`, `cost_tracking`, `batch_operations`.

**TypeScript** (`@datagrout/conduit` npm package)
- ESM and CJS dual-publish via `tsup`.
- `Client` class with `connect()` / `disconnect()` lifecycle and `ensureInitialized()` guard.
- `Client.bootstrapIdentity()` static method for one-call identity provisioning.
- `sendWithRetry()` — auto-reconnects on `NotInitialized` errors.
- `annotations` field on `MCPTool` type.
- `DG_SUBSTRATE_ENDPOINT` and `DG_CA_URL` constants exported.
- 89 vitest tests (plus 12 skipped integration tests gated on env vars).

**Python** (`datagrout-conduit` PyPI package)
- Async context manager (`async with Client(url) as client`) and explicit `connect()`/`disconnect()` methods.
- `_ensure_initialized()` guard on all public methods.
- `_send_with_retry()` — auto-reconnects on `NotInitialized` errors.
- `httpx`-based HTTP client with `pydantic` models.
- 117 pytest tests.

**Elixir** (`datagrout_conduit` hex package)
- GenServer-based `Client` for connection state management with `bootstrap_identity/1` and `bootstrap_identity_oauth/1`.
- `Registration` module: `generate_keypair`, `register_identity`, `rotate_identity`, `save_identity`, `fetch_ca_cert`, `refresh_ca_cert`.
- `GuidedSession` module with `start`, `choose`, `complete` for interactive multi-step workflows.
- `Identity` module with full 5-step mTLS discovery cascade and X.509 expiry parsing.
- `OAuth` GenServer with token caching, auto-refresh, and `invalidate/1`.
- `Req`-based HTTP transports with SSE parsing, `Mcp-Session-Id` tracking, 202 Accepted handling, 429 rate-limit handling, and 401 OAuth retry.
- `annotations` field on `Tool` type.
- 87 ExUnit tests.

**Ruby** (`datagrout-conduit` gem)
- Thread-safe `Client` with `connect`/`disconnect` lifecycle, `bootstrap_identity`, and `bootstrap_identity_oauth`.
- `Registration` class: `generate_keypair`, `register_identity`, `rotate_identity`, `save_identity`, `fetch_ca_cert`, `refresh_ca_cert`.
- `Identity` class with OpenSSL integration, `with_expiry`, `needs_rotation?`, and `try_discover`.
- `OAuth::TokenProvider` with `Mutex`-protected token caching and `invalidate!`.
- Faraday-based transports with mTLS SSL configuration, SSE parsing, `Mcp-Session-Id` tracking, and `Accept: application/json, text/event-stream` header.
- `identity_dir` and `disable_mtls` options on `Client`.
- 98 minitest tests, 218 assertions.
