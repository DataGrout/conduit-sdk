# Changelog

All notable changes to the DataGrout Conduit SDK will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

---

## [0.1.0] - 2026-03-01

Initial public release of the DataGrout Conduit SDK across all three languages.

### Core

- **JSON-RPC 2.0 transport** — lightweight HTTP POST-based transport with full request/response handling, retry logic, and error mapping.
- **MCP transport** — Streamable HTTP / SSE transport for full MCP protocol compliance; supports `initialize`, `tools/list`, `tools/call`, and session management.
- **Transport auto-detection** — DataGrout gateway URLs automatically select the correct transport based on the endpoint path.
- **Bearer token authentication** — simple API key or access token auth via `Authorization: Bearer` header.
- **Rate limit handling** — typed `RateLimitError` / `RateLimit` with parsed `X-RateLimit-*` headers and `retry_after` for automatic backoff.

### Semantic Discovery & Workflows

- **`discover()`** — semantic search over tool catalogs by intent, with score-based ranking, integration filtering, and configurable limits.
- **`guide()`** — interactive multi-step guided workflow sessions with branching choices.
- **`perform()`** — direct tool execution with optional demultiplexing.

### Cost Tracking

- **`extract_meta()`** — extract the `_datagrout` metadata block from tool-call results, including receipts, credit estimates, and BYOK discount details.
- **Receipt type** — structured receipt with `estimated_credits`, `actual_credits`, `net_credits`, `savings`, per-component `breakdown`, and optional balance tracking.

### mTLS Identity Plane

- **`ConduitIdentity`** — load client certificates from PEM files, PEM byte strings, or PKCS#12 bundles.
- **Auto-discovery** — searches `CONDUIT_MTLS_CERT`/`CONDUIT_MTLS_KEY` env vars, `CONDUIT_IDENTITY_DIR`, `~/.conduit/`, and `.conduit/` relative to cwd.
- **Custom identity directories** — `identity_dir` option for running multiple agents on the same machine with separate certificates.
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

### Language-Specific Notes

**Rust** (`datagrout-conduit` crate)
- Builder pattern via `ClientBuilder` with `url()`, `auth_bearer()`, `transport()`, `with_identity()`, `with_identity_auto()`, `identity_dir()`, `bootstrap_identity()`.
- `registration` feature flag to opt-in to `rcgen`-based keypair generation.
- Seven runnable examples: `basic`, `discovery`, `guided_workflow`, `flow_orchestration`, `type_transformation`, `cost_tracking`, `batch_operations`.

**TypeScript** (`@datagrout/conduit` npm package)
- ESM and CJS dual-publish via `tsup`.
- `Client` class with `connect()` / `disconnect()` lifecycle.
- Full vitest test suite with mocks and live integration tests (gated on env vars).

**Python** (`datagrout-conduit` PyPI package)
- Async context manager: `async with Client(url) as client`.
- `httpx`-based HTTP client with `pydantic` models.
- pytest + pytest-asyncio test suite.
