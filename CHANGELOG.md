# Changelog

All notable changes to the DataGrout Conduit SDK will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

---

## [0.8.0] - 2026-09-08

### TL;DR

Four themes:

1. **The SDKs can authenticate a person, not just a machine.** OAuth 2.1
   authorization code + PKCE lands in all five languages. Until now every
   conduit SDK could authenticate a *machine* — `client_credentials`, or the
   onramp handshake that ends in one — which left
   `https://gateway.datagrout.ai/connect` unreachable, because the server
   binding there is chosen at consent time and lives in the token rather than
   the URL. Desktop and CLI applications can now sign a user in.
2. **The WebSocket handshake actually authenticates.** Four of the five sent no
   usable credential on the upgrade, for three different underlying reasons,
   and two of them dropped an mTLS identity they had been handed. Elixir also
   performed no server verification at all without an identity.
3. **An agent can act for a user without becoming the user.** RFC 8693 token
   exchange produces a token naming the person as `sub` and the agent in `act`,
   so a resource server can tell the two apart and audit, rate-limit or revoke
   them separately. An actor is required unless impersonation is asked for by
   name, so the accountable mode is the one you get by default.
4. **The cross-language contract is enforced rather than described.**
   `testdata/contract.json` pins the grant shapes, the persisted client, the
   default scope and the error taxonomies, and every language's suite loads it.

**Behaviour changes for existing users**, none of them tied to the new grant:
WebSocket upgrades now carry an `Authorization` header for `client_credentials`
in Rust, TypeScript, Python and Elixir; Elixir `wss://` now refuses a server
certificate it cannot verify, where it previously accepted anything; and an
Elixir HTTP 401 now refreshes and retries once instead of surfacing
immediately. Details in the sections below.

Everything above is in all five languages. Rust is the reference implementation
and the other four are written from it, so a behaviour described here is a
behaviour you can rely on whichever SDK you use.

The WebSocket fix was not one bug in five places. Rust, TypeScript and Python
built the upgrade headers synchronously and so could never attach an
asynchronously-fetched token; Elixir interpolated the `{:ok, token}` tuple and
sent a malformed bearer; Ruby resolves synchronously and was always correct.
Same symptom in four of them, three different causes. Each language section
below says which applied.

### Fixed — OAuth tokens now authenticate the WebSocket handshake

`WsTransport::connect` resolves an asynchronously-fetched bearer **before**
building the handshake request. `build_handshake_request` is synchronous, so
previously a provider-backed token could never reach the upgrade — an OAuth
client authenticated over WS only if it also happened to present an mTLS
identity. This affected `client_credentials` from the start; it is fixed for
both grants.

Behaviour change for existing `client_credentials` users: WS upgrades now carry
an `Authorization: Bearer` header. Servers that were relying on the absence of
that header will see it.

### Fixed — mTLS identities now present a client certificate on the WebSocket handshake

Two WebSocket transports accepted a `ConduitIdentity` and silently dropped it,
so a `wss://` connection presented no client certificate even though the HTTP
transports in the same language did. Rust (`build_connector`), Python
(`_build_ssl_context`) and Ruby (`build_ssl_context`) already presented the
cert and were not changed.

- **TypeScript** — `WsTransport` now passes the identity's PEMs to the `ws`
  client as `cert`, `key` and (when set) `ca`, which flow to `tls.connect` —
  the same options `fetchWithIdentity` hands to `https.request`. Outside Node
  it warns and connects without the cert, as `fetchWithIdentity` does. Applied
  to `wss://` only; a plain `ws://` connection never carries one.
- **Elixir** — `Transport.Ws.Conn` now builds `:ssl_options` for WebSockex from
  the identity: `cert`/`key` from PEM or `certfile`/`keyfile` from paths,
  `verify: :verify_peer`, SNI, and a trust store that is the identity's CA
  (`cacerts` from PEM, `cacertfile` from a path) or the CAStore bundle the
  Finch-backed transports already verify against. Applied to `wss://` only.

### Fixed — Elixir `wss://` connections verify the server without an identity

WebSockex defaults to `insecure: true`, so an Elixir WebSocket connection that
carried no mTLS identity performed no peer verification at all — unlike the
Finch-backed HTTP transports and the Rust reference, which always verify
against a real trust store. `Transport.Ws.Conn` now sets `verify: :verify_peer`,
SNI, the `:https` hostname check and the CAStore bundle on every `wss://`
connection, identity or not. Behaviour change: a `wss://` endpoint with a
self-signed or otherwise untrusted server certificate that used to connect will
now be refused, as it already was over HTTP.

### Added — RFC 8693 token exchange (delegation)

An agent can now hold a token that names the **user** as `sub` and **itself**
in `act`, behind the new `delegation` feature. The two existing grants each
answer one question — `client_credentials` says which machine, authorization
code says which person — and neither says both. An agent working on a user's
behalf needs both: the resource server has to know whose data it is and who is
actually holding the connection, so it can audit, rate-limit and revoke the two
separately. RFC 8693 produces exactly that token from two the caller already
has. The module speaks the RFC, so it works against any compliant token
endpoint.

**Wire contract.** `POST {token_endpoint}`, form-encoded:
`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token` +
`subject_token_type`, `actor_token` + `actor_token_type`, `client_id` +
`client_secret?` (in the body by default; HTTP Basic on request), and the
optional `audience`, `resource`, `scope`, `requested_token_type`. `resource` is
RFC 8707 and is always sent when set, the same invariant the authorization-code
module keeps. The success body is `{access_token, issued_token_type,
token_type, expires_in?, scope?}`; failures are RFC 6749
`{error, error_description?}` with `invalid_request | invalid_client |
invalid_grant | unauthorized_client | invalid_target | invalid_scope |
unsupported_grant_type`.

**Why an actor is required by default.** RFC 8693 distinguishes *delegation*
(the issued token carries `act`, and the resource server can tell agent from
user) from *impersonation* (the agent simply becomes the user, and nobody can).
DataGrout issues delegation tokens only and requires `actor_token`. The SDK
therefore refuses to build a request with no actor — `missing_actor`, before
any HTTP — unless the caller says `impersonation()` explicitly. Forgetting to
set an actor is an error, not a silent downgrade to the less accountable mode.

**The client must be the actor.** The `client_id` authenticating the request
and the principal behind `actor_token` are expected to be the same agent. The
SDK does not verify this (it cannot without decoding the actor token); the
server does, and answers `unauthorized_client` when they differ.

- `delegation::DelegationRequest` — builder: `new(token_endpoint, client_id)`,
  `.client_secret()`, `.client_auth(ClientAuth::Body | Basic)`,
  `.subject_token(token, TokenType)`, `.actor_token(token, TokenType)`,
  `.audience()`, `.resource()`, `.scope()`, `.requested_token_type()`,
  `.impersonation()`; `form_params()` exposes the exact body for tests;
  `exchange(&http)` performs it.
- `delegation::TokenType` — `AccessToken`, `Jwt`, `IdToken`, `RefreshToken`,
  `Saml2`, `Other(String)`; serializes as its URN.
- `delegation::DelegatedToken` — `{access_token, issued_token_type,
  token_type, expires_at?, scope?}`. `expires_at` is **Unix seconds**, computed
  from `expires_in` at receipt, so the shape means the same thing in every
  language and once written down.
- `delegation::DelegationError` with `kind()` ∈ `missing_subject`,
  `missing_actor`, `http`, `server` (carrying `status`, `error`,
  `error_description`), `invalid_response`. A non-2xx whose body is not an
  RFC 6749 error — a proxy's HTML — is `invalid_response`, not `server`.
- `delegation::TokenSource` — where the provider gets each token:
  `static_token`, `client_credentials(OAuthTokenProvider)`,
  `authorization_code(AuthCodeProvider)` (with `authcode`), or `dynamic(async
  fn)`. Consulted on every exchange, so an upstream provider's own refresh is
  what keeps the subject and actor live.
- `delegation::DelegatedProvider::new(request, subject, Option<actor>)` — the
  third token provider, shaped like the other two: `get_token` re-exchanges
  inside the same 60-second buffer, `invalidate` drops the cached token for the
  401 retry, exchanges are single-flighted. `AuthConfig::Delegation` resolves
  through the same `inject_oauth_token` and `resolve_async_token` choke points,
  so every HTTP transport, the 401-retry path and the **WebSocket upgrade**
  (invariant 11) carry the delegated bearer unchanged.
- `ClientBuilder::auth_delegation(provider)`.
- `delegation::codes` — the seven RFC 6749 error codes as named constants.
- `testdata/contract.json` gains a `delegation` object: grant type, token-type
  URNs, a request fixture with the exact form body it must produce, the issued
  token and its minimal form, the wire response, the error kinds and the
  server error codes. `testdata/README.md` has the rows.
- Example: `cargo run --example delegated_agent --features delegation`.

**Additive:** with the feature off, nothing changes. Naming is deliberate:
"token exchange" elsewhere in this crate (`Error::Onramp { stage:
"token_exchange" }`, `AuthCodeError::TokenExchange`) means redeeming a
`client_credentials` or authorization-code grant. This module says
*delegation* and *exchange* and never reuses that label.


### Added — OAuth 2.1 authorization code + PKCE

Browser-consent sign-in, behind the new `authcode` feature. Until now every
conduit SDK could authenticate a *machine* (`client_credentials`, or the onramp
handshake that ends in one) but none could authenticate a *person*. That made
`https://gateway.datagrout.ai/connect` — where the server binding is chosen at
consent time and lives in the token rather than the URL — unreachable from a
desktop or CLI application.

- `authcode::AuthCodeFlow` — RFC 8414/9728 discovery → RFC 7591 dynamic client
  registration (as a **public client**, `token_endpoint_auth_method: "none"`) →
  PKCE authorize URL → code exchange.
- `authcode::Grant` — the persistable authorization, with `refresh()`.
- `authcode::RegisteredClient` — a client id **paired with its redirect URI**.
  `register()` returns this rather than a bare id, and
  `AuthCodeFlow::with_registered_client` restores it. The pairing is not
  bookkeeping: the authorization server matches redirect URIs exactly, with no
  loopback-port exemption, so an id saved without its URI cannot be reused.
- `loopback::Listener::bind_for(redirect_uri)` — re-bind the exact port and
  path of a saved registration, failing loudly if that port is taken (recover by
  registering a new client, not by retrying).
- `authcode::AuthCodeProvider` — caches and refreshes, mirroring
  `OAuthTokenProvider`; `take_if_dirty()` surfaces a rotated grant for
  re-persisting.
- `authcode::loopback::Listener` (feature `authcode-loopback`) — one-shot
  `127.0.0.1` redirect capture.
- `ClientBuilder::auth_authorization_code(grant)` and
  `auth_authorization_code_provider(provider)`.
- `AuthCodeError::kind()` — the cross-language name for a failure, for logging
  and for comparing against another SDK's error. Rust callers branching on a
  failure should match the variant; this exists for the contract. The `match`
  behind it is exhaustive, so a variant added without naming its kind does not
  compile.
- Example: `cargo run --example browser_signin --features authcode-loopback`.

**Additive:** with the feature off, nothing changes. The new
`AuthConfig::AuthorizationCode` variant resolves through the same
`inject_oauth_token` choke point as `ClientCredentials`, so every transport and
the 401-retry path pick it up unchanged.

**WebSocket:** `connect()` now resolves an async bearer before building the
handshake, so authorization-code grants authenticate over WS.
`ClientCredentials` keeps its existing WS behaviour (mTLS, or a token in the
first subscribe frame) — the same treatment would likely suit it, but that
would change existing behaviour and is left for a separate change.

#### TypeScript

The same surface, idiomatically. `Grant` is a plain interface, so
`JSON.stringify` produces the cross-language shape with no `toJSON` to forget,
and the helpers are free functions (`isGrantExpired`, `isGrantRefreshable`,
`refreshGrant`). The error taxonomy is one `AuthCodeError` carrying a `kind`
from a string-literal union, which is how a TypeScript caller branches.
`auth.authorizationCode` accepts either a bare `Grant` or an
`AuthCodeProvider` you keep — the second being what you want when a rotated
refresh token has to be written back.

`LoopbackListener` lives in its own module (`src/loopback.ts`) rather than
inside `authcode`, mirroring the Rust feature split so a headless caller can
take the flow without an HTTP server.

Unlike Rust, the WS fix here also covers `client_credentials`: that transport
built its upgrade headers synchronously and never constructed a provider at
all, so *neither* grant authenticated over WS. Both do now, and the token
endpoint is derived from the `ws://` URL with the scheme mapped across to
`http://`, since a `ws://` token endpoint is nonsense.

Example: `npx tsx examples/browserSignin.ts`. 65 new tests, including a
capturing WebSocket stub that drives the real `connect()` — the bug lived in
exactly the wiring that the existing mocked-transport tests skip.

#### Python

The same surface, async throughout. `Grant`, `RegisteredClient` and
`AuthServerMetadata` are dataclasses with `to_dict`/`from_dict` producing the
cross-language shape; `to_dict` omits absent optionals rather than writing
nulls. `AuthCodeError` subclasses `ConduitError` and carries an
`AuthCodeErrorKind` — a `str`-valued enum, so the wire names compare equal to
plain strings. `AuthCodeFlow` is an async context manager and closes only an
`httpx` client it created itself, so a caller-supplied client survives the
flow.

`auth={"authorization_code": ...}` accepts a `Grant`, a grant dict straight
from JSON, or an `AuthCodeProvider` you keep — the third being what you want
when a rotated refresh token has to be written back.
`LoopbackListener` lives in `datagrout.conduit.loopback`, mirroring the Rust
feature split, and is re-exported from the package root. It runs on
`asyncio.start_server` and needs no dependency beyond the standard library.

As in TypeScript, the WS fix here also covers `client_credentials`: that
transport built its upgrade headers synchronously and never constructed a
provider at all, so *neither* grant authenticated over WS. Both do now, and the
token endpoint is derived from the `ws://` URL with the scheme mapped across to
`http://`. The transport closes the `httpx` client it creates for token fetches
on disconnect.

Example: `python examples/browser_signin.py`. 102 new tests: the loopback suite
binds real sockets and drives them with real requests, and the WS suite drives
the real `connect()` and reads the headers handed to `websockets`. The transport
suite runs every case against both HTTP transports, which carry independent
copies of the header-building and 401-retry paths.

#### Ruby

The same surface, synchronous. `AuthCode::Grant`, `AuthCode::RegisteredClient`
and `AuthCode::ServerMetadata` carry `to_h`/`from_h` producing the
cross-language shape, with absent optionals omitted rather than written as
nulls. The error taxonomy is a class per kind under `AuthCode::Error`, so a
caller branches by rescuing the one it cares about; every one of them also
answers `#kind` with the shared wire name, and all descend from
`DatagroutConduit::AuthError`, so code that only cares that authentication
failed keeps working.

`auth: { authorization_code: ... }` accepts a `Grant`, a grant `Hash` straight
from JSON (either key style), or an `AuthCode::Provider` you keep — the third
being what you want when a rotated refresh token has to be written back.
`AuthCode::Provider` mirrors `OAuth::TokenProvider`, `Mutex` and all, down to
`get_token` and `invalidate!`, so both grants reach the transports through one
branch. `AuthCode::LoopbackListener` lives in its own file, mirroring the Rust
feature split, and runs on `TCPServer` — no new dependency.

**The WebSocket handshake was never broken here.** Resolving a token is
synchronous in Ruby, so `build_upgrade_headers` could always call `get_token`
directly; the async SDKs had to hoist that out of header construction to reach
the same place. The authorization-code grant joins `client_credentials` on that
path, and the tests now pin both down.

Example: `ruby -Ilib examples/browser_signin.rb`. 94 new tests: the loopback
suite binds real sockets and drives them with raw HTTP requests, and the
transport suite runs each case against MCP, JSONRPC and WebSocket, since the
three build their headers independently.

#### Elixir

The same surface, as plain functions over a struct rather than a process: the
flow is short-lived and sequential, so `DatagroutConduit.AuthCode.discover/1`,
`register/3`, `authorize_url/1` and `exchange/4` thread a `%AuthCode{}` and
return `{:ok, ...} | {:error, %AuthCode.Error{}}`. `register/3` returns
`{:ok, registered, flow}` because there is nothing to mutate. The error taxonomy
is one exception struct carrying a `:kind` atom, which is what an Elixir caller
pattern-matches on. `AuthCode.Grant`, `RegisteredClient` and `ServerMetadata`
carry `to_map/1` and `from_map/1` producing the cross-language shape, with
absent optionals omitted rather than written as nulls.

`AuthCode.Provider` is a GenServer mirroring `DatagroutConduit.OAuth` — same
`get_token/1` and `invalidate/1` — and `take_if_dirty/1` returns `{:ok, grant}`
or `:clean`. `auth: {:authorization_code, ...}` accepts a `Grant`, a grant map
straight from JSON, or a running provider. `AuthCode.Loopback` lives in its own
module, mirroring the Rust feature split, and runs on `:gen_tcp` — no new
dependency.

**New: `DatagroutConduit.Auth`.** Resolving auth, invalidating it, and turning
it into headers now live in one module that every transport calls, which is what
lets the two grants share a single path. Three things were wrong before, and all
three are fixed by routing through it:

- The WS upgrade interpolated the `{:ok, token}` tuple that `get_token` returns,
  so it sent `Authorization: Bearer {:ok, "…"}`. An OAuth client authenticated
  over WS only if it also happened to present an mTLS identity — the same
  outcome as the other SDKs, by a different route.
- The client never passed a provider into the transports' request options, so
  the 401-refresh path in both HTTP transports was unreachable.
- Even when reached, the retry reused the `Req` struct built with the stale
  header, so it would have re-sent the token that had just been rejected. The
  transports now invalidate, rebuild the header, and retry once.
- A token fetch that *failed* was logged and dropped, and the request went out
  with no `Authorization` header at all. The caller then saw a bare 401 — a
  round trip later, and saying nothing about why the token could not be had.
  Elixir was the only SDK that did this; the other four propagate. `resolve/1`
  now returns `{:ok, resolved} | {:error, reason}` and callers surface
  `{:auth_error, reason}` rather than sending the request unauthenticated.
  The WebSocket transport refuses to start, since the token rides the upgrade
  and there is no second chance. The one exception is client start-up, where a
  failure stays advisory: every request re-resolves, so a briefly-unreachable
  token endpoint must not stop a supervised client from booting.

`Auth.normalize/1` now raises `ArgumentError` on an `:authorization_code` value
it cannot turn into a provider, matching what the Ruby SDK already did. That is
a configuration mistake rather than a transient failure, and silently
continuing unauthenticated turned a typo into a puzzling 401 much later.

Behaviour change for existing `client_credentials` users: WS upgrades now carry
a well-formed `Authorization: Bearer` header; a 401 on an HTTP transport
refreshes and retries once instead of surfacing immediately; and a failed token
fetch now returns `{:error, {:auth_error, reason}}` where it previously sent an
unauthenticated request.

Example: `mix run examples/browser_signin.exs`. 100 new tests: the loopback suite
binds real sockets and drives them with raw HTTP requests, the flow suite runs
against `Req.Test` so the real request building is exercised, and the transport
suite drives both HTTP transports plus the WS upgrade headers.

### The cross-language contract

Rust is the reference implementation and the other four SDKs are written from
it. Signatures follow each language's own idiom, but the semantics below hold
everywhere, so anything relying on them behaves the same whichever SDK you
reach for. `testdata/contract.json` pins the parts a test can check, and every
language's suite loads it.

1. **The `Grant` JSON shape is identical**, so a grant written by one SDK is
   readable by another: `access_token`, `refresh_token?`, `expires_at?`,
   `client_id`, `token_endpoint`, `scope?`, `resource?`. `expires_at` is
   **Unix seconds** — never a monotonic clock value, which is meaningless once
   serialized.
2. **Sequence and error taxonomy match:** discovery → registration → authorize
   → exchange → refresh, with distinct errors for `Discovery`,
   `NoRegistrationEndpoint`, `RegistrationRejected`, `NoClientId`,
   `PkceUnsupported`, `StateMismatch`, `TokenExchange`, `NotRefreshable`,
   `Denied`, `Http`.
3. **`state` is verified inside `exchange`**, before any request is sent, using
   a length-independent comparison. A mismatch is refused, never attempted.
4. **PKCE is S256 only.** A server advertising only `plain` is refused rather
   than downgraded; an empty `code_challenge_methods_supported` is treated as
   "assume S256".
5. **`resource` (RFC 8707) is sent** on both authorize and token requests, so a
   token cannot be replayed against a different resource.
6. **The loopback listener is a separate opt-in** from the flow itself, so
   headless callers never pull in an HTTP server.
7. **Storage is the application's job.** The SDK owns the grant's shape and its
   refresh; it must not choose a file location or a keychain.
8. **A refresh that returns no new refresh token keeps the old one**, rather
   than silently making the grant unrefreshable.
9. **The registered client id and its redirect URI are one persisted unit**, and
   a saved registration re-binds the same loopback port. Redirect matching is
   exact; a new random port with an old client id is rejected, and the failure
   only surfaces once the first grant can no longer be refreshed.
10. **`DEFAULT_SCOPE` is `"mcp tools"`** — the authorization server's own
    registration default. It splits the scope string on whitespace and stores
    what it is given, so an invented scope is accepted silently and then means
    nothing. Do not "improve" this per language.
11. **The WS handshake carries the resolved OAuth bearer**, for both grants.
12. **A refresh never holds the state lock.** `grant`, `is_dirty` and
    `take_if_dirty` must keep answering while one is in flight — a persistence
    loop is the documented use, and a hung token endpoint must not wedge the
    provider. Refreshes are single-flighted: concurrent callers make one
    request and share its outcome, failure included, so a dead endpoint costs
    one round trip rather than one per waiter.
13. **The form body is exactly `contract.json` → `delegation.request_form`**,
    field for field, for the fixture request — including order. `resource`
    is sent whenever set. `client_secret` is in the body under the default
    client auth and absent from it under Basic.
14. **An actor is required unless impersonation is explicit.** A request with
    no actor fails `missing_actor` *before any HTTP*; a request with no subject
    fails `missing_subject` likewise. The opt-out is a named call on the
    builder, never a default or an `Option` that quietly reads as "none".
15. **`DelegatedToken` is `{access_token, issued_token_type, token_type,
    expires_at?, scope?}`**, `issued_token_type` a URN string, `expires_at`
    Unix seconds computed at receipt, absent optionals omitted rather than
    null. `contract.json` → `delegation.token`, `token_minimal` and
    `wire_response` pin all three halves.
16. **Error taxonomy:** `missing_subject`, `missing_actor`, `http`, `server`
    (status + RFC 6749 `error` + `error_description?`), `invalid_response`. A
    non-2xx without an RFC 6749 body is `invalid_response`. A 2xx missing
    `issued_token_type` or `token_type` is `invalid_response`.
17. **The delegated provider behaves like the other two.** `get_token` and
    `invalidate`, the same 60-second refresh buffer, single-flighted exchange,
    and a cached token dropped on a 401 then re-exchanged once. It resolves
    through the same path the other grants use, so every HTTP transport, the
    401 retry and the WebSocket upgrade (invariant 11) all carry the delegated
    bearer.
18. **Token sources are consulted on every exchange**, so a provider-backed
    subject or actor is refreshed by the provider that owns it, and a 401 on
    the resource server drops only the delegated token, never the sources.
19. **The client must be the actor, and the server is what enforces it.** The
    SDK cannot verify the pairing without decoding the actor token, so it does
    not try.


#### Fixed — a refresh no longer freezes the provider

Every provider except TypeScript's held its state lock across the refresh
request. That blocked `grant`, `is_dirty` and `take_if_dirty` for the whole
round trip — and a persistence loop calling `take_if_dirty` on a timer is the
use the docs recommend — while a hung token endpoint wedged the provider
outright. Elixir was worst: the refresh ran inside `handle_call`, so every
caller hit its 30-second timeout while the GenServer stayed stuck.

TypeScript already had the right model, a shared promise cleared in `finally`.
The other four now match it:

- **Rust** — a dedicated `tokio::sync::Mutex` serializes refreshes; the `RwLock`
  over the grant is taken only to read the stale value and to write the fresh
  one, never across `.await`.
- **Python** — the in-flight refresh is a shared `asyncio.Task`, shielded so a
  caller that gives up cannot cancel it for everyone else. The lock is held only
  to hand off leadership.
- **Ruby** — two mutexes with distinct jobs: one guards state and is never held
  across the network, one serializes the refresh itself.
- **Elixir** — the refresh runs in a monitored process and callers are parked
  with `{:noreply, …}` until it lands, so the GenServer keeps serving. Monitored
  rather than linked, so a crash in the refresh answers the waiters instead of
  taking the provider down. `$callers` is propagated by hand, since that is what
  carries process ownership to a test HTTP stub.

All five also share failures, not just successes: a caller that queued behind a
refresh takes its outcome either way, so a dead token endpoint costs one request
rather than one per waiter. TypeScript, Python and Elixir get that from the
shared promise, task and waiter list respectively. Rust and Ruby have no shared
handle to hold, so they record the settled attempt — a counter plus the failure
message — and a waiter that finds the counter moved on takes that result instead
of launching its own.

The memoized failure belongs to the callers that queued behind it, not to the
future: once an attempt has settled, the next call refreshes again rather than
replaying the error. Each language has a test for both halves.

#### Tests — the Rust WebSocket and HTTP auth paths were the least covered

Rust originated both WS fixes and had the thinnest tests for them, which only
became obvious once TypeScript and Elixir grew real suites for the same code.
No behaviour changed here; these cover what was already there.

- `resolve_async_token` — the whole of the WS OAuth fix, since the handshake
  builder is synchronous and this is the only point a provider-backed
  credential can reach the upgrade — had no test, for either grant.
- `build_handshake_request` was only ever called with `None`, so the branch that
  consumes a resolved token was untested, as was the deliberate decision to send
  *no* credential when a provider grant arrives unresolved.
- `build_connector` was only tested with `None`. It now has an identity that
  really is presented, a CA that is really trusted, and an unparseable identity
  that must fail loudly rather than be silently dropped.
- `src/transport.rs` had no test module at all, so `inject_oauth_token`,
  `invalidate_oauth` and the 401-retry-once path were unexercised in Rust for
  both grants — the one part of the authorization-code work the other four SDKs
  covered and the reference did not.

The 401 tests use a grant that is live by the clock but rejected by the server,
which is the case the retry path exists for: an already-expired grant is
refreshed before the first request and never earns a 401.

#### Invariants 1, 2, 9 and 10 are now enforced, not just written down

`testdata/contract.json` holds the canonical grant, minimal grant, registered
client, default scope and error taxonomy as bytes, and every language's suite
loads that one file. Before it, each suite round-tripped a grant through its
*own* serializer — which passes even when a language has a field name wrong, so
long as it is wrong consistently. Nothing actually checked that a grant written
by Python could be read by Ruby, which is the property invariant 1 promises.

Every row is checked in all five. They differ only in whether an *added* kind is
caught as well as a renamed one: Rust and TypeScript catch it at compile time
(an exhaustive `match` and an exhaustive `Record`), Python enumerates a real
`Enum`, and Ruby and Elixir have no runtime registry so their hand-written lists
catch a rename only. `testdata/README.md` has the table.

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
