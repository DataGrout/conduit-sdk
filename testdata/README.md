# testdata

`contract.json` is the cross-language contract, as bytes rather than prose.

Every language SDK's test suite loads this one file and asserts its own types
agree with it. That is the point: before this existed, each suite round-tripped
a grant through *its own* serializer, which passes even when a language has a
field name wrong — as long as it is consistently wrong. Nothing checked that
Python and Ruby would actually read each other's saved grant, which is the whole
promise of having one persisted shape.

## What it pins

| key | what a failure means |
|---|---|
| `grant` | a field was renamed, added, or dropped from the persisted shape |
| `grant_minimal` | absent optionals are being written as nulls instead of omitted |
| `registered_client` | the id/redirect-URI pair no longer persists as one unit |
| `default_scope` | someone "improved" the scope string |
| `error_kinds` | the error taxonomy drifted in one language |
| `delegation.grant_type`, `delegation.token_types` | a URN was mistyped in one language |
| `delegation.request` → `delegation.request_form` | the fixture request no longer posts exactly this body, in this order |
| `delegation.token`, `delegation.token_minimal`, `delegation.wire_response` | the issued-token shape drifted, or `expires_in` is not becoming absolute `expires_at` |
| `delegation.error_kinds` | the delegation error taxonomy drifted |
| `delegation.server_error_codes` | the RFC 6749 code list a `server` error can carry drifted |

## Where the tests live

- Rust — `rust/src/authcode.rs` and `rust/src/delegation.rs`, `contract_fixture` tests
- TypeScript — `typescript/tests/contract.test.ts`
- Python — `python/tests/test_contract.py`
- Ruby — `ruby/test/contract_test.rb`
- Elixir — `elixir/test/contract_test.exs`

## How strictly each language is held

All five check every row. They differ in whether an *added* kind is caught as
well as a *renamed* one:

| language | renamed kind | added kind |
|---|---|---|
| Rust | test | compiler — `AuthCodeError::kind()` and `DelegationError::kind()` match exhaustively |
| TypeScript | test | compiler — exhaustive `Record<AuthCodeErrorKind, true>` |
| Python | test | test — enumerates a real `Enum` |
| Ruby | test | not caught — no runtime registry, list is hand-written |
| Elixir | test | not caught — same |

Ruby and Elixir express the taxonomy as classes and atoms with nothing to
enumerate at runtime, so a kind added to the SDK and not to this file slips past
them. The other three would fail, which is enough to stop the drift.

## Adding a sixth language

Load this file, assert every row above, and add the language to the table. If a
new field ever joins the grant, it changes here first and every suite fails
until it is ported — which is the whole idea.
