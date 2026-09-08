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

## Coverage is not uniform, deliberately

`error_kinds` is checked in four of the five. Python enumerates a real `Enum`
and TypeScript uses an exhaustive `Record<AuthCodeErrorKind, true>`, so both
fail if a kind is added to the SDK and not to this file. Ruby and Elixir express
the taxonomy as classes and atoms with no runtime registry, so their tests
compare a hand-written list against this file — that catches a *renamed* kind but
not an *added* one. Rust models it as a `thiserror` enum with no string form at
all, so it does not participate; adding one would mean new public API.

The grant and client shapes are checked in all five.

## Adding a sixth language

Load this file, assert the same five rows, and add it to the table above. If a
new field ever joins the grant, it changes here first and every suite fails
until it is ported — which is the whole idea.
