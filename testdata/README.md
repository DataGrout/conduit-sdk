# testdata

`contract.json` is the cross-language contract, as bytes rather than prose.

Every language SDK's test suite loads this one file and asserts its own types
agree with it. That is the point: before this existed, each suite round-tripped
a grant through *its own* serializer, which passes even when a language has a
field name wrong — as long as it is consistently wrong. Nothing checked that
Python and Ruby would actually read each other's saved grant, which is the
property invariant #1 in `CHANGELOG.md` promises.

## What it pins

| key | invariant | what a failure means |
|---|---|---|
| `grant` | #1 | a field was renamed, added, or dropped from the persisted shape |
| `grant_minimal` | #1 | absent optionals are being written as nulls instead of omitted |
| `registered_client` | #9 | the id/redirect-URI pair no longer persists as one unit |
| `default_scope` | #10 | someone "improved" the scope string |
| `error_kinds` | #2 | the error taxonomy drifted in one language |

## Where the tests live

- Rust — `rust/src/authcode.rs`, `contract_fixture` tests
- TypeScript — `typescript/tests/contract.test.ts`
- Python — `python/tests/test_contract.py`
- Ruby — `ruby/test/contract_test.rb`
- Elixir — `elixir/test/contract_test.exs`

## How strictly each language is held

All five check every row. They differ in whether an *added* kind is caught as
well as a *renamed* one:

| language | renamed kind | added kind |
|---|---|---|
| Rust | test | compiler — `AuthCodeError::kind()` matches exhaustively |
| TypeScript | test | compiler — exhaustive `Record<AuthCodeErrorKind, true>` |
| Python | test | test — enumerates a real `Enum` |
| Ruby | test | not caught — no runtime registry, list is hand-written |
| Elixir | test | not caught — same |

Ruby and Elixir express the taxonomy as classes and atoms with nothing to
enumerate at runtime, so a kind added to the SDK and not to this file slips past
them. The other three would fail, which is enough to stop the drift.

## Adding a sixth language

Load this file, assert the same five rows, and add it to the table above. If a
new field ever joins the grant, it changes here first and every suite fails
until it is ported — which is the whole idea.
