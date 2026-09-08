"""The cross-language contract, checked against the shared fixture.

Every other test in this suite round-trips a grant through this SDK's own
serializer, which passes even if a field name is wrong — as long as it is
consistently wrong. These load ``testdata/contract.json``, the same bytes every
language checks, so a grant written here is provably readable elsewhere.

See ``testdata/README.md``.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict

from datagrout.conduit.authcode import (
    DEFAULT_SCOPE,
    AuthCodeErrorKind,
    Grant,
    RegisteredClient,
)

CONTRACT: Dict[str, Any] = json.loads(
    (Path(__file__).resolve().parents[2] / "testdata" / "contract.json").read_text()
)


def test_a_grant_written_elsewhere_loads_field_for_field():
    # Read explicitly rather than by round-trip: a misnamed field would leave
    # the attribute None, and a round-trip alone would not notice.
    grant = Grant.from_dict(CONTRACT["grant"])

    assert grant.access_token == "at_contract_fixture"
    assert grant.refresh_token == "rt_contract_fixture"
    assert grant.expires_at == 1700000000
    assert grant.client_id == "client_contract_fixture"
    assert grant.token_endpoint == "https://gateway.example.com/oauth/token"
    assert grant.scope == "mcp tools"
    assert grant.resource == "https://gateway.example.com/connect"


def test_a_grant_written_here_is_byte_identical_to_the_contract():
    assert Grant.from_dict(CONTRACT["grant"]).to_dict() == CONTRACT["grant"]


def test_a_minimal_grant_omits_absent_optionals_rather_than_nulling_them():
    minimal = CONTRACT["grant_minimal"]
    assert Grant.from_dict(minimal).to_dict() == minimal


def test_a_registered_client_round_trips_as_one_unit():
    client = CONTRACT["registered_client"]
    assert RegisteredClient.from_dict(client).to_dict() == client


def test_the_default_scope_matches_the_contract():
    assert DEFAULT_SCOPE == CONTRACT["default_scope"]


def test_the_error_taxonomy_matches_the_contract():
    # A real Enum, so this fails both ways: a kind added to the SDK and not to
    # the fixture, and a kind in the fixture this SDK does not define.
    assert sorted(kind.value for kind in AuthCodeErrorKind) == sorted(CONTRACT["error_kinds"])
