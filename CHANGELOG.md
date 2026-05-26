# Changelog

All notable changes to the DataGrout Conduit SDK will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

---

## [0.7.0] - 2026-05-25

### TL;DR

Two themes:

1. **Client-initiated WebSocket ping keepalive** — new in all five languages.
   The WS transport now sends a ping every 25 seconds to defeat idle-timeout
   disconnects from load balancers and reverse proxies (nginx, AWS ALB,
   Cloudflare).
2. **Rust subscribe/unsubscribe API surface closes a long-standing parity
   gap** — TS, Python, Ruby, and Elixir have exposed `Client.subscribe(topic)`
   / `Client.unsubscribe(id)` since 0.4.0; Rust callers had to reach for
   `WsTransport.subscribe` directly. The Rust client now has the same surface.

After this release the five SDKs are at **full functional parity** for push
subscriptions and connection keepalive.

### Added (all five languages — new behaviour)

**Client-initiated WebSocket ping keepalive (25 s).**  The WS transport
sends a ping frame every `PING_INTERVAL` seconds.  Many load balancers and
reverse proxies close idle WS connections after 60–120 seconds; pinging
every 25 seconds keeps the connection alive well within the tightest common
timeout window.  Long-running push subscriptions that previously died after
two minutes of quiet traffic now stay open indefinitely.

Each language exposes the interval as a public constant, mirrored across
the five SDKs:

| Lang       | Constant / accessor                                                  | Override mechanism                                  |
| ---------- | -------------------------------------------------------------------- | --------------------------------------------------- |
| Rust       | `ws_transport::PING_INTERVAL` (`Duration::from_secs(25)`)            | private const — recompile or fork                    |
| TypeScript | `PING_INTERVAL_MS = 25_000` (exported)                               | `WsTransport.setPingInterval(ms)` before `connect()` |
| Python     | `PING_INTERVAL_SECONDS = 25` (exported)                              | `WsTransport(url, ping_interval=...)` kw            |
| Ruby       | `Transport::Ws::PING_INTERVAL_SECONDS = 25`                          | `Ws.new(url, ping_interval: ...)` kw                |
| Elixir     | `DatagroutConduit.Transport.Ws.ping_interval_ms/0` → `25_000`        | `start_link(..., ping_interval_ms: ...)` init opt   |

Per-language wire-up:

- **Rust** — `run_connection` in `ws_transport.rs` fires
  `Message::Ping(vec![])` on a `tokio::time::interval` tick; if the sink
  send fails the connection task exits cleanly.
- **TypeScript** — `setInterval(_, PING_INTERVAL_MS)` set in `connect()`,
  cleared in `disconnect()` and `onclose`.  Calls the Node `ws.ping()`
  method when available; silently no-ops in browsers (the spec
  `WebSocket` API doesn't expose ping).  `Timer.unref()` is invoked when
  available so the timer does not pin the Node event loop open.
- **Python** — `ping_interval` and `ping_timeout` are forwarded to
  `websockets.connect()`, using the library's built-in ping mechanism.
- **Ruby** — a `conduit-ws-ping` background thread sleeps
  `@ping_interval` seconds then calls `WebSocket::Driver#ping`; exits
  cleanly when the driver returns `false` (closing) or `@connected` flips
  to `false`.  `cleanup_socket` kills the ping thread before tearing down
  the reader.
- **Elixir** — `:ping_tick` `handle_info/2` clause sends `{:ping, ""}`
  through the `Conn` WebSockex process and reschedules itself via
  `Process.send_after/3`.  A new `safe_send_ping/1` helper catches `:exit`
  from `WebSockex.send_frame/2` so a vanished Conn does not crash the `Ws`
  GenServer alongside it.

### Added (Rust — closing the parity gap with the other four SDKs)

These items bring Rust to the same surface the other four languages have
shipped since 0.4.0; no functional change for TS/Python/Ruby/Elixir.

- **`TransportTrait::subscribe(topic)` / `TransportTrait::unsubscribe(id)`** —
  promoted from the `WsTransport` inherent impl onto the public transport
  trait, with default impls that return
  `Error::Network("subscribe is only supported on the WS transport")` for
  non-WS transports.  Callers no longer need to downcast.  Mirrors TS's
  `Client.subscribe` runtime check, Python's analogous guard, Ruby's
  `Subscription.unsubscribe`, and Elixir's `{:error, :not_ws_transport}`
  return on non-WS clients.
- **`Client::subscribe(topic)` / `Client::unsubscribe(id)`** — client-level
  methods that delegate to the active transport.  Same naming as the
  corresponding methods on TypeScript, Python, Ruby, and Elixir clients.
  (No collision with namespace accessors — those are sync methods returning
  `Logic<'_>` / `Prism<'_>` / `Flow<'_>` namespaced handles.)

### Tests

| Lang       | New tests | Total WS tests | Total package tests |
| ---------- | --------: | -------------: | ------------------: |
| Rust       |         0 |              8 |                 105 |
| TypeScript |        +4 |             30 |                 157 |
| Python     |        +4 |             32 |                 196 |
| Ruby       |        +6 |             41 |                 151 |
| Elixir     |        +5 |             18 |                 125 |

The new tests verify, per language: the public `PING_INTERVAL` constant
value, the default state, the override mechanism, the timer/thread/tick
lifecycle, and graceful degradation when the underlying connection has
gone away.  Rust's existing `ws_transport_tests.rs` suite continues to
pass; the ping cadence is exercised indirectly by the long-lived
subscribe→push→unsubscribe lifecycle test.

---

## [0.6.0] - 2026-05-19

### Added (all languages)

**MCP 2025 `structuredContent` support** — `call_tool` now prefers the
`structuredContent` field on tool call results when it is present. This field
carries the actual JSON payload directly (no string-encoding), superseding the
legacy `content[0].text` path which remains as a fallback for servers that
predate the MCP 2025 revision.

The unwrap priority is:
1. `structuredContent` — returned as-is (pure JSON object).
2. `content[0].text` — parsed as JSON; falls back to `{"text": <value>}` if
   the text is not valid JSON.
3. `content[0]` — returned as-is when the first content item has no `text`
   field (e.g. image content items).
4. Raw result — returned unchanged when neither envelope is present.

### Changed (Rust)

- **`protocol.rs` — `CallToolResult`**: added `structured_content: Option<Value>`
  (`#[serde(rename_all = "camelCase")]` so it deserialises from `structuredContent`);
  `content` now carries `#[serde(default)]` so it is optional on the wire.
- **`client.rs` — `call_tool`**: prefers `structured_content` → parses
  `content[0].text` as JSON → returns `content[0]` as-is → returns raw. Removes
  the previous behaviour of returning the raw content item unchanged.
- **`client.rs` — `call_dg_tool`**: same priority order applied to the internal
  DG tool dispatch path.

### Changed (TypeScript)

- **`transports/jsonrpc.ts` — `unwrapContent`**: checks `result.structuredContent`
  first; falls back to `content[0].text` JSON parse, then `content[0]` as-is.
  Updated JSDoc to document the four-step priority. `unwrapContent` is now
  exported (as a testing seam) alongside the existing `RateLimitError` re-export.
- **`transports/mcp.ts` — `callTool`**: same `structuredContent`-first check
  applied inline before the content-array fallback.

### Changed (Python)

- **`transports/mcp_transport.py` — `call_tool`**: `structuredContent` key
  checked first; falls back to `content[0]["text"]` JSON parse, then `content[0]`
  as-is. Comment updated to document the three-step fallback.
- **`transports/jsonrpc_transport.py` — `call_tool`**: identical change.

### Changed (Elixir)

- **`types.ex` — `Types.ToolResult`**: added `structured_content: nil` field
  and corresponding `@type` spec entry.
- **`client.ex` — `handle_call({:call_tool, …})`**: populates
  `structured_content: result["structuredContent"]` on the returned `ToolResult`.
- **`client.ex` — `unwrap_content/1`**: added a first clause matching
  `%{"structuredContent" => sc}` (non-nil guard) that returns `sc` directly;
  added a third clause returning `content[0]` as-is for non-text content items.

### Changed (Ruby)

- **`client.rb` — `unwrap_content`**: checks `raw.key?("structuredContent")`
  first and returns its value; falls back to `content[0]["text"]` JSON parse,
  then `content[0]` as-is when no `"text"` key is present. Comment updated with
  full four-step priority documentation.

### Tests

- **Rust** (`src/client.rs`): existing `call_tool` tests cover the new unwrap
  behaviour; the `protocol.rs` change is covered by the existing serde tests.
- **TypeScript** (`tests/client.test.ts`): 7 new `describe('unwrapContent')`
  unit tests covering `structuredContent` priority, JSON parse fallback,
  non-JSON text fallback, no-text content item, no-envelope passthrough, and
  null/undefined passthrough.
- **Python** (`tests/test_client.py`): 5 new parametrised `@pytest.mark.asyncio`
  tests run against both `MCPTransport` and `JSONRPCTransport` covering the
  same cases.
- **Elixir** (`test/client_test.exs`): 6 new ExUnit tests across two `describe`
  blocks — `call_tool/3 structured_content field` and
  `dg/3 unwrap_content priority (MCP 2025)`.
- **Ruby** (`test/client_test.rb`): 6 new minitest tests covering all
  `unwrap_content` branches.

### Version

`0.5.0` → `0.6.0`

---

## [0.5.0] - 2026-05-09

### Added (all languages)

**Autonomous agent onramp** — zero-credential self-registration for agents that have never been provisioned. Agents can now call a two-step unauthenticated HTTP handshake to receive provisional OAuth credentials, exchange them for an access token, and bootstrap a full mTLS identity in one pass. No API key or pre-provisioned secret required.

### Added (Rust)

- **`OnrampOptions`** struct — `gateway`, `agent_name`, `agent_type?`, `intended_use?`, `access_code?`.
- **`OnrampCredentials`** struct — `client_id`, `client_secret`, `token_url`, `scopes`, `expires_in`, `mcp_url?`, `rpc_url?`.
- **`onramp::register_only(opts)`** — two-step handshake returning provisional credentials; no token exchange.
- **`onramp::register_and_exchange(opts)`** — credentials + immediate OAuth token exchange in one call.
- **`ClientBuilder::bootstrap_onramp(opts)`** — all-in-one: fast-path check for a saved mTLS identity → onramp → token exchange → `bootstrap_identity`. Subsequent runs auto-discover the saved identity and skip registration entirely.
- **`rust/examples/bootstrap.rs`** — runnable example showing both Path A (one-liner `bootstrap_onramp`) and Path B (manual `register_and_exchange` + `bootstrap_identity`). Run with `cargo run --example bootstrap --features bootstrap`.

### Added (Python)

- **`OnrampOptions`** dataclass — snake_case fields: `gateway`, `agent_name`, `agent_type`, `intended_use`, `access_code`.
- **`OnrampCredentials`** dataclass — `client_id`, `client_secret`, `token_url`, `scopes`, `expires_in`, `mcp_url`, `rpc_url`.
- **`OnrampError`** — raised on non-2xx onramp or token exchange responses.
- **`register_only(opts)`** / **`register_and_exchange(opts)`** — public async API matching the Rust surface.
- **`Client.bootstrap_onramp(opts, ...)`** — async classmethod; fast-paths on existing valid identity, otherwise onramp → token → `bootstrap_identity`.
- All onramp types exported from `datagrout.conduit` top-level package.
- 11 new pytest tests in `tests/test_onramp.py`.

### Added (TypeScript)

- **`OnrampOptions`** interface — camelCase fields: `gateway`, `agentName`, `agentType?`, `intendedUse?`, `accessCode?`.
- **`OnrampCredentials`** interface — `clientId`, `clientSecret`, `tokenUrl`, `scopes`, `expiresIn`, `mcpUrl?`, `rpcUrl?`.
- **`registerOnly(opts)`** / **`registerAndExchange(opts)`** — public async API; `registerAndExchange` returns `[OnrampCredentials, string]`.
- **`Client.bootstrapOnramp({ opts, url?, identityDir? })`** — static async method; fast-paths on existing valid identity.
- Internal `_doRegister` / `_exchangeToken` exported for test access.
- All types and functions exported from `@datagrout/conduit`.
- 18 new vitest tests in `tests/onramp.test.ts`.

### Added (Ruby)

- **`DatagroutConduit::Onramp::OnrampOptions`** Struct — snake_case: `gateway`, `agent_name`, `agent_type`, `intended_use`, `access_code`.
- **`DatagroutConduit::Onramp::OnrampCredentials`** Struct — `client_id`, `client_secret`, `token_url`, `scopes`, `expires_in`, `mcp_url`, `rpc_url`.
- **`DatagroutConduit::Onramp::OnrampError`** — raised on non-2xx responses.
- **`Onramp.register_only(opts)`** / **`Onramp.register_and_exchange(opts)`** — synchronous class methods; `register_and_exchange` returns `[creds, token]`.
- **`Client.bootstrap_onramp(opts:, url: nil, name:, identity_dir: nil)`** — fast-paths on existing valid identity; falls back to onramp → token → `bootstrap_identity`.
- 9 new minitest tests in `test/onramp_test.rb`.

### Added (Elixir)

- **`DatagroutConduit.Onramp.OnrampOptions`** struct — `gateway`, `agent_name`, `agent_type`, `intended_use`, `access_code`.
- **`DatagroutConduit.Onramp.OnrampCredentials`** struct — `client_id`, `client_secret`, `token_url`, `scopes`, `expires_in`, `mcp_url`, `rpc_url`.
- **`Onramp.register_only/1`** — `{:ok, %OnrampCredentials{}}` or `{:error, reason}`.
- **`Onramp.register_and_exchange/1`** — `{:ok, {%OnrampCredentials{}, token}}` or `{:error, reason}`.
- **`Onramp.exchange_token/1`** — public for composing custom flows.
- **`DatagroutConduit.Client.bootstrap_onramp/1`** — keyword-list API (`opts:`, `url:`, `name:`, `identity_dir:`); returns `{:ok, pid}` or `{:error, reason}`.
- 15 new ExUnit tests in `test/onramp_test.exs`.

### Changed

- **Version**: `0.4.0` → `0.5.0`

---

## [0.4.0] - 2026-04-30

### Added (all languages)

WebSocket transport (`datagrout-jsonrpc.v1`) is now available in all five SDK languages, completing feature parity across the SDK matrix.

### Added (Rust)

- **WebSocket transport** — `Transport::WebSocket` over `wss://`, implementing the `datagrout-jsonrpc.v1` subprotocol. Single mTLS connection multiplexed for all requests; concurrent requests correlated by JSON-RPC `id` with no head-of-line blocking.
- **Push subscriptions** — `client.subscribe(topic)` / `client.unsubscribe(topic)` for server-initiated notification delivery via Tokio `broadcast` channel. Supported topics: `agents.<id>.events`, `tools.<tool>.results`, `tasks.<task_id>.*`, `flows.<flow_id>.*`, `governor.<server_uuid>`.
- **`WsTransport`** struct (`ws_transport.rs`) — full send/receive loop, outbound frame queue, per-subscription broadcast channel registry, connect/disconnect lifecycle with no orphan tasks.
- **8 integration tests** for the WS transport — subprotocol negotiation, bearer token forwarding in upgrade headers, concurrent request multiplexing, subscribe + server-pushed notification + unsubscribe round-trip, server error propagation, connect/disconnect hygiene. All run against a local mock `datagrout-jsonrpc.v1` server using `tokio-tungstenite`.

### Added (Python)

- **WebSocket transport** — `WsTransport` class using `websockets` (asyncio-native). Single `wss://` connection multiplexed across all concurrent requests; correlated by JSON-RPC `id` via `asyncio.Future`. Install extra: `pip install 'datagrout-conduit[ws]'`.
- **Push subscriptions** — `client.subscribe(topic)` returns an async-iterable `Subscription`. Iterate with `async for event in sub` or call `await sub.recv()`. Unsubscribe with `client.unsubscribe(sub.id)`.
- **Async read loop** — background `asyncio.Task` drains the WebSocket; all response routing and subscription delivery happen without blocking the caller.
- **34 unit tests** for `WsTransport` — frame injection via mock protocol, pending-future routing, subscription delivery, malformed JSON handling, disconnect cleanup, and auth header generation.

### Added (TypeScript)

- **WebSocket transport** — `WsTransport` class using the `ws` package (`ws` npm). Single `wss://` connection multiplexed via a `Map<string, { resolve, reject }>` pending table. Specify `transport: 'websocket'` when constructing the client.
- **Push subscriptions** — `client.subscribe(topic)` returns a `Subscription` with an `AsyncIterator` interface. Iterate with `for await (const event of sub)` or call `await sub.recv()`. Close with `client.unsubscribe(sub.id)`.
- **Background reader** — WebSocket `'message'` handler routes frames; subscription events are pushed to per-subscription `AsyncQueue` with backpressure via configurable buffer (default 256).
- **28 unit tests** for `WsTransport` — message injection, pending resolution, subscription routing, error propagation, URL rewriting, and disconnect cleanup.

### Added (Elixir)

- **WebSocket transport** — `DatagroutConduit.Transport.Ws` GenServer over `:gun` (OTP-native HTTP/2 + WS client). Single connection with per-request reply tracking via `GenServer.call`. Start with `transport: :websocket` option.
- **Push subscriptions** — `DatagroutConduit.Client.subscribe/2` returns `{:ok, sub_id}`. Server-pushed events arrive as `{:subscription_event, sub_id, event}` messages in the subscribing process's mailbox. Unsubscribe with `DatagroutConduit.Client.unsubscribe/2`.
- **`Ws.Conn`** — thin `websocket_client` wrapper that handles the WS frame loop, routes notifications by subscription ID, and forwards events to registered subscriber PIDs.
- **32 unit tests** for `Transport.Ws` — message injection, subscription delivery, error propagation, reconnect semantics, and client delegate methods.

### Added (Ruby)

- **WebSocket transport** — `DatagroutConduit::Transport::Ws` class using `websocket-driver ~> 0.7` (the library underlying Rails ActionCable). Single `wss://` connection with `Thread::Queue`-based blocking semantics; no EventMachine dependency. Specify `transport: :websocket` when constructing the client.
- **Push subscriptions** — `client.subscribe(topic)` returns a `Subscription` with `recv(timeout:)` and `each` (Enumerable). Block on `sub.recv` or iterate with `sub.each { |event| ... }`. Unsubscribe with `client.unsubscribe(sub)`.
- **Background read thread** — dedicated `Thread` runs the `read_loop` and calls `@driver.parse`; all response routing happens in the reader thread with `Mutex`-protected shared state.
- **34 unit tests** for `Transport::Ws` — frame injection, pending routing, subscription delivery, integer id coercion, disconnect cleanup, auth header generation, and Subscription lifecycle.

### Changed

- **READMEs** — WebSocket transport section added to all five language READMEs; top-level README transport table updated to reflect full WS parity.
- **Rust README comparison table** — WebSocket push row updated from `🔜 Planned` to `✅ v0.4+` for Python, TypeScript, Elixir, and Ruby.
- **Version**: `0.3.0` → `0.4.0`

---

## [0.3.0] - 2026-03-23

### Added

- **Server-scoped DG identity bootstrap** — DG MCP URLs now derive a per-server identity endpoint (`/servers/:server_id/identity`) for certificate registration instead of relying on the legacy global substrate bootstrap route.

### Changed

- **Bootstrap flow for DG URLs** — `bootstrap_identity()` now targets the MCP server's own DG identity registration path, matching the server-side DG CA bootstrap and mTLS acceptance flow.
- **Identity renewal behavior** — DG-issued identities now attempt mTLS rotation first when a stored certificate is nearing expiry, falling back to token-authenticated re-registration only if rotation fails.
- **Documentation** — README and Rust README now describe the server-scoped DG bootstrap and rotation behavior more explicitly.

---

## [0.2.0] - 2026-03-19

### Breaking Changes

- **Namespaced API** — domain-specific methods have moved from flat `client.method()` calls to namespaced accessors. This affects all five languages:
  - `client.refract()` → `client.prism.refract()`
  - `client.chart()` → `client.prism.chart()`
  - `client.prism_focus()` → `client.prism.focus()`
  - `client.remember()` → `client.logic.remember()`
  - `client.query_cell()` → `client.logic.query()`
  - `client.forget()` → `client.logic.forget()`
  - `client.constrain()` → `client.logic.constrain()`
  - `client.reflect()` → `client.logic.reflect()`
  - `client.flow_into()` → `client.flow.run()`

  The `dg(short_name, params)` escape hatch and core methods (`discover`, `plan`, `perform`, `guide`, `estimate_cost`, `call_tool`) remain on the client root.

### Added

- **Namespace modules** — six new sub-namespaces organize domain-specific tools:
  - **`client.prism`** — `refract()`, `chart()`, `focus()`
  - **`client.logic`** — `remember()`, `query()`, `forget()`, `constrain()`, `reflect()`, `hydrate()`, `worlds()`, `tabulate()`, `export()`, `import_facts()`
  - **`client.warden`** — `adjudicate()`, `intent()`, `ensemble()`, `canary()`
  - **`client.deliverables`** — `register()`, `list()`, `get()`
  - **`client.ephemerals`** — `list()`, `inspect()`
  - **`client.flow`** — `run()`, `route()`, `request_approval()`, `request_feedback()`
- **First-class Warden wrappers** — `adjudicate`, `intent`, `ensemble`, `canary` for policy enforcement and security analysis.
- **First-class Deliverables wrappers** — `register`, `list`, `get` for managing persistent output artifacts.
- **First-class Ephemerals wrappers** — `list`, `inspect` for examining transient execution state.
- **Expanded Logic Cell wrappers** — `hydrate`, `worlds`, `tabulate`, `export`, `import_facts` join the existing `remember`, `query`, `forget`, `constrain`, `reflect`.
- **Flow orchestration wrappers** — `run` (née `flow_into`), `route`, `request_approval`, `request_feedback` for higher-order workflow composition.
- **`perform_batch()`** — execute multiple tool calls in a single gateway request. Now available in all five languages (previously only Python and TypeScript).
- **3-tier metadata fallback** — `extract_meta()` now checks `_meta.datagrout` (rich), `structuredContent._dg` / `_dg` (compact), and `_datagrout` / `_meta` (legacy) in order. Logs a warning when no cost tracking metadata is found.
- **Higher-order workflow documentation** — README now documents named flows, unnamed flows (`$compute`), conditional routing, and human-in-the-loop patterns.

### Changed

- **README** updated with namespaced API examples across all languages, plus a comprehensive "Higher-Order Workflows" section.
- **Elixir client** — removed dead `handle_call` clauses that became unreachable after namespace migration.

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
### Invariant: Semantic Code Analysis

- `dg("invariant.code_lens", params)` — transform source code into queryable semantic facts.
- `dg("invariant.diff_analyzer", params)` — analyse code changes for alignment with a stated goal.
- `dg("invariant.code_query", params)` — execute Prolog queries over lensed code facts.

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
