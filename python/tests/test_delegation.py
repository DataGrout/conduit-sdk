"""RFC 8693 delegation — an agent acting for a user.

The wire body, the refusals that happen before any request, the error
taxonomy, and the provider's caching and single-flighting. The form order and
the token shape are pinned against ``testdata/contract.json`` at the bottom, so
what this SDK posts is provably what the other ports post.
"""

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple
from urllib.parse import parse_qsl

import httpx
import pytest

from datagrout.conduit.authcode import AuthCodeProvider, Grant
from datagrout.conduit.delegation import (
    GRANT_TYPE,
    SERVER_ERROR_CODES,
    ClientAuth,
    DelegatedProvider,
    DelegatedToken,
    DelegationError,
    DelegationErrorKind,
    DelegationRequest,
    ServerErrorCode,
    TokenSource,
    TokenSourceKind,
    TokenType,
)
from datagrout.conduit.oauth import OAuthTokenProvider

TOKEN_ENDPOINT = "https://as.example.com/oauth/token"
AGENT_ENDPOINT = "https://as.example.com/agent/token"

SUCCESS_BODY: Dict[str, Any] = {
    "access_token": "delegated_at",
    "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
    "token_type": "Bearer",
    "expires_in": 900,
    "scope": "mcp tools",
}


def _request(**overrides: Any) -> DelegationRequest:
    fields: Dict[str, Any] = {
        "token_endpoint": TOKEN_ENDPOINT,
        "client_id": "agent_client",
        "client_secret": "agent_secret",
        "subject_token": "user_at",
        "actor_token": "agent_at",
    }
    fields.update(overrides)
    return DelegationRequest(**fields)


def _client(handler: Any) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _form_of(request: httpx.Request) -> List[Tuple[str, str]]:
    """The posted form, in the order it was encoded."""
    return parse_qsl(request.content.decode(), keep_blank_values=True)


# ─── token types ─────────────────────────────────────────────────────────────


def test_token_types_round_trip_through_their_urns():
    for token_type in (
        TokenType.ACCESS_TOKEN,
        TokenType.JWT,
        TokenType.ID_TOKEN,
        TokenType.REFRESH_TOKEN,
        TokenType.SAML2,
    ):
        assert token_type.as_urn().startswith("urn:ietf:params:oauth:token-type:")
        assert TokenType.from_urn(token_type.as_urn()) == token_type


def test_an_unknown_urn_is_kept_verbatim():
    # The vocabulary is open: a URN this SDK does not name must round-trip
    # rather than fail, which is why this is not an Enum.
    other = TokenType.from_urn("urn:example:custom")
    assert other.as_urn() == "urn:example:custom"
    assert str(other) == "urn:example:custom"
    assert other != TokenType.ACCESS_TOKEN


def test_token_types_are_hashable_and_compare_by_urn():
    assert TokenType.from_urn(TokenType.JWT.urn) == TokenType.JWT
    assert len({TokenType.JWT, TokenType.from_urn(TokenType.JWT.urn)}) == 1


# ─── form body ───────────────────────────────────────────────────────────────


def test_form_carries_exactly_the_expected_fields_in_wire_order():
    form = _request(
        audience="https://gateway.example.com",
        resource="https://gateway.example.com/connect",
        scope="mcp tools",
        requested_token_type=TokenType.ACCESS_TOKEN,
    ).form_params()

    assert form == [
        ("grant_type", GRANT_TYPE),
        ("subject_token", "user_at"),
        ("subject_token_type", "urn:ietf:params:oauth:token-type:access_token"),
        ("actor_token", "agent_at"),
        ("actor_token_type", "urn:ietf:params:oauth:token-type:access_token"),
        ("client_id", "agent_client"),
        ("client_secret", "agent_secret"),
        ("audience", "https://gateway.example.com"),
        ("resource", "https://gateway.example.com/connect"),
        ("scope", "mcp tools"),
        ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
    ]


def test_form_omits_optionals_that_were_not_set():
    keys = [key for key, _ in _request().form_params()]
    for absent in ("audience", "resource", "scope", "requested_token_type"):
        assert absent not in keys


def test_form_sends_resource_whenever_it_is_set():
    # RFC 8707 — the same invariant the authorization-code module keeps, so a
    # delegated token cannot be replayed against a different resource.
    form = _request(resource="https://gateway.example.com/connect").form_params()
    assert ("resource", "https://gateway.example.com/connect") in form


def test_form_keeps_the_secret_out_of_the_body_under_basic_auth():
    form = _request(client_auth=ClientAuth.BASIC).form_params()
    assert all(key != "client_secret" for key, _ in form)
    # client_id still travels in the body.
    assert ("client_id", "agent_client") in form


def test_form_accepts_a_jwt_subject():
    form = _request(subject_token="eyJ", subject_token_type=TokenType.JWT).form_params()
    assert ("subject_token_type", "urn:ietf:params:oauth:token-type:jwt") in form


# ─── refusals before any HTTP ────────────────────────────────────────────────


async def test_a_missing_actor_is_refused_before_any_request_is_sent():
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        nonlocal attempts
        attempts += 1
        return httpx.Response(200, json=SUCCESS_BODY)

    request = DelegationRequest(
        token_endpoint=TOKEN_ENDPOINT, client_id="c", subject_token="user_at"
    )
    with pytest.raises(DelegationError) as excinfo:
        await request.exchange(_client(handler))

    assert excinfo.value.kind is DelegationErrorKind.MISSING_ACTOR
    assert excinfo.value.kind == "missing_actor"
    assert attempts == 0


async def test_a_missing_subject_is_refused_before_any_request_is_sent():
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        nonlocal attempts
        attempts += 1
        return httpx.Response(200, json=SUCCESS_BODY)

    request = DelegationRequest(
        token_endpoint=TOKEN_ENDPOINT, client_id="c", actor_token="agent_at"
    )
    with pytest.raises(DelegationError) as excinfo:
        await request.exchange(_client(handler))

    assert excinfo.value.kind is DelegationErrorKind.MISSING_SUBJECT
    assert attempts == 0


def test_impersonation_is_the_only_way_to_omit_the_actor():
    form = DelegationRequest(
        token_endpoint=TOKEN_ENDPOINT,
        client_id="c",
        subject_token="user_at",
        impersonation=True,
    ).form_params()
    assert all(not key.startswith("actor_token") for key, _ in form)


# ─── the wire ────────────────────────────────────────────────────────────────


async def test_exchange_posts_a_form_encoded_body_with_the_actor_fields():
    seen: List[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=SUCCESS_BODY)

    issued = await _request(resource="https://gateway.example.com/connect").exchange(
        _client(handler)
    )

    assert issued.access_token == "delegated_at"
    assert len(seen) == 1
    assert seen[0].headers["content-type"] == "application/x-www-form-urlencoded"
    form = dict(_form_of(seen[0]))
    assert form["grant_type"] == GRANT_TYPE
    assert form["subject_token"] == "user_at"
    assert form["subject_token_type"] == "urn:ietf:params:oauth:token-type:access_token"
    assert form["actor_token"] == "agent_at"
    assert form["actor_token_type"] == "urn:ietf:params:oauth:token-type:access_token"
    assert form["client_id"] == "agent_client"
    assert form["client_secret"] == "agent_secret"
    assert form["resource"] == "https://gateway.example.com/connect"
    # No Basic header when the secret travels in the body.
    assert "authorization" not in seen[0].headers


async def test_exchange_sends_basic_client_auth_when_asked():
    import base64

    seen: List[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=SUCCESS_BODY)

    await _request(client_auth=ClientAuth.BASIC).exchange(_client(handler))

    expected = base64.b64encode(b"agent_client:agent_secret").decode()
    assert seen[0].headers["authorization"] == f"Basic {expected}"
    assert "client_secret" not in dict(_form_of(seen[0]))


async def test_a_success_response_becomes_a_token_with_an_absolute_expiry():
    before = int(time.time())
    issued = await _request().exchange(
        _client(lambda request: httpx.Response(200, json=SUCCESS_BODY))
    )
    after = int(time.time())

    assert issued.access_token == "delegated_at"
    assert issued.issued_token_type == TokenType.ACCESS_TOKEN
    assert issued.token_type == "Bearer"
    assert issued.scope == "mcp tools"
    # expires_at = now + expires_in, in Unix seconds — never monotonic.
    assert issued.expires_at is not None
    assert before + 900 <= issued.expires_at <= after + 900
    assert not issued.is_expired()


async def test_an_rfc6749_error_body_is_a_server_error_with_code_and_status():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            400,
            json={"error": "invalid_target", "error_description": "unknown resource"},
        )

    with pytest.raises(DelegationError) as excinfo:
        await _request().exchange(_client(handler))

    err = excinfo.value
    assert err.kind is DelegationErrorKind.SERVER
    assert err.status == 400
    assert err.error == ServerErrorCode.INVALID_TARGET
    assert err.error_description == "unknown resource"


async def test_a_failure_without_an_oauth_body_is_an_invalid_response():
    # A proxy's HTML did not come from the token endpoint's contract.
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(502, text="<html>bad gateway</html>")

    with pytest.raises(DelegationError) as excinfo:
        await _request().exchange(_client(handler))

    assert excinfo.value.kind is DelegationErrorKind.INVALID_RESPONSE
    assert "502" in str(excinfo.value)


@pytest.mark.parametrize("missing", ["issued_token_type", "token_type"])
async def test_a_success_missing_a_required_field_is_an_invalid_response(missing: str):
    # RFC 8693 §2.2.1 makes both REQUIRED; a server that drops one is out of
    # contract, and guessing would hide that.
    body = {key: value for key, value in SUCCESS_BODY.items() if key != missing}

    with pytest.raises(DelegationError) as excinfo:
        await _request().exchange(_client(lambda request: httpx.Response(200, json=body)))

    assert excinfo.value.kind is DelegationErrorKind.INVALID_RESPONSE
    assert missing in str(excinfo.value)


async def test_a_success_that_is_not_json_is_an_invalid_response():
    with pytest.raises(DelegationError) as excinfo:
        await _request().exchange(
            _client(lambda request: httpx.Response(200, text="not json at all"))
        )
    assert excinfo.value.kind is DelegationErrorKind.INVALID_RESPONSE


async def test_an_unreachable_endpoint_is_an_http_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    with pytest.raises(DelegationError) as excinfo:
        await _request().exchange(_client(handler))

    assert excinfo.value.kind is DelegationErrorKind.HTTP


# ─── token ───────────────────────────────────────────────────────────────────


def _token(expires_at: int | None) -> DelegatedToken:
    return DelegatedToken(
        access_token="delegated_at",
        issued_token_type=TokenType.ACCESS_TOKEN,
        token_type="Bearer",
        expires_at=expires_at,
    )


def test_a_token_with_no_stated_expiry_is_not_expired():
    assert not _token(None).is_expired()


def test_a_token_expires_early_by_the_refresh_skew():
    assert _token(int(time.time()) + 30).is_expired()
    assert not _token(int(time.time()) + 600).is_expired()


def test_token_omits_absent_optionals_when_serialized():
    data = _token(None).to_dict()
    assert "expires_at" not in data
    assert "scope" not in data
    assert data["issued_token_type"] == "urn:ietf:params:oauth:token-type:access_token"


def test_a_token_round_trips_through_its_dict_form():
    token = DelegatedToken(
        access_token="delegated_at",
        issued_token_type=TokenType.JWT,
        token_type="Bearer",
        expires_at=1_700_000_000,
        scope="mcp tools",
    )
    assert DelegatedToken.from_dict(token.to_dict()) == token


# ─── token sources ───────────────────────────────────────────────────────────


async def test_a_static_source_yields_its_token():
    source = TokenSource.static_token("user_at")
    assert source.kind is TokenSourceKind.STATIC
    assert source.token_type == TokenType.ACCESS_TOKEN
    assert await source.resolve(_client(lambda r: httpx.Response(200))) == "user_at"


async def test_a_dynamic_source_is_consulted_on_every_resolve():
    calls = 0

    async def fetch() -> str:
        nonlocal calls
        calls += 1
        return f"user_{calls}"

    source = TokenSource.dynamic(fetch, TokenType.JWT)
    client = _client(lambda r: httpx.Response(200))
    assert await source.resolve(client) == "user_1"
    assert await source.resolve(client) == "user_2"
    assert source.token_type == TokenType.JWT


async def test_an_authorization_code_source_serves_the_signed_in_user():
    grant = Grant(
        access_token="user_access_token",
        client_id="client_abc",
        token_endpoint=TOKEN_ENDPOINT,
        refresh_token="rt",
        expires_at=int(time.time()) + 3600,
    )
    source = TokenSource.authorization_code(AuthCodeProvider(grant))
    assert source.kind is TokenSourceKind.AUTHORIZATION_CODE
    resolved = await source.resolve(_client(lambda r: httpx.Response(200)))
    assert resolved == "user_access_token"


def test_with_token_type_redeclares_a_source():
    source = TokenSource.static_token("user_at").with_token_type(TokenType.JWT)
    assert source.token_type == TokenType.JWT


def test_a_source_repr_never_prints_its_token():
    rendered = repr(TokenSource.static_token("user_at"))
    assert "user_at" not in rendered
    assert "static" in rendered


# ─── provider ────────────────────────────────────────────────────────────────


def _provider(**overrides: Any) -> DelegatedProvider:
    return DelegatedProvider(
        DelegationRequest(
            token_endpoint=TOKEN_ENDPOINT,
            client_id="agent_client",
            client_secret="agent_secret",
            **overrides,
        ),
        subject=TokenSource.static_token("user_at"),
        actor=TokenSource.static_token("agent_at"),
    )


async def test_provider_exchanges_once_and_serves_from_cache_until_expiry():
    exchanges = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal exchanges
        exchanges += 1
        return httpx.Response(200, json=SUCCESS_BODY)

    provider = _provider()
    client = _client(handler)

    for _ in range(3):
        assert await provider.get_token(client) == "delegated_at"

    assert exchanges == 1
    assert provider.token() is not None


async def test_provider_re_exchanges_after_invalidate():
    exchanges = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal exchanges
        exchanges += 1
        return httpx.Response(200, json={**SUCCESS_BODY, "access_token": f"del_{exchanges}"})

    provider = _provider()
    client = _client(handler)

    assert await provider.get_token(client) == "del_1"
    provider.invalidate()
    assert provider.token() is None
    assert await provider.get_token(client) == "del_2"
    assert exchanges == 2


async def test_provider_re_exchanges_a_token_that_is_inside_the_skew():
    # Expires in 30s: already inside the 60s buffer, so the second call must
    # exchange again rather than serve it.
    exchanges = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal exchanges
        exchanges += 1
        return httpx.Response(200, json={**SUCCESS_BODY, "expires_in": 30})

    provider = _provider()
    client = _client(handler)
    await provider.get_token(client)
    await provider.get_token(client)
    assert exchanges == 2


async def test_provider_pulls_fresh_upstream_tokens_on_every_exchange():
    subjects: List[str] = []
    calls = 0

    async def fetch() -> str:
        nonlocal calls
        calls += 1
        return f"user_{calls}"

    def handler(request: httpx.Request) -> httpx.Response:
        subjects.append(dict(_form_of(request))["subject_token"])
        return httpx.Response(200, json=SUCCESS_BODY)

    provider = DelegatedProvider(
        DelegationRequest(token_endpoint=TOKEN_ENDPOINT, client_id="agent_client"),
        subject=TokenSource.dynamic(fetch),
        actor=TokenSource.static_token("agent_at"),
    )
    client = _client(handler)

    await provider.get_token(client)
    provider.invalidate()
    await provider.get_token(client)

    # A source is consulted on every exchange — the whole point of wrapping a
    # provider rather than copying its current token out.
    assert subjects == ["user_1", "user_2"]


async def test_provider_uses_a_client_credentials_actor():
    seen: List[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url == AGENT_ENDPOINT:
            seen.append("agent")
            return httpx.Response(200, json={"access_token": "agent_live", "expires_in": 3600})
        seen.append(dict(_form_of(request))["actor_token"])
        return httpx.Response(200, json=SUCCESS_BODY)

    actor = OAuthTokenProvider(
        client_id="agent_client",
        client_secret="agent_secret",
        token_endpoint=AGENT_ENDPOINT,
    )
    provider = DelegatedProvider(
        DelegationRequest(
            token_endpoint=TOKEN_ENDPOINT,
            client_id="agent_client",
            client_secret="agent_secret",
        ),
        subject=TokenSource.static_token("user_at"),
        actor=TokenSource.client_credentials(actor),
    )

    assert await provider.get_token(_client(handler)) == "delegated_at"
    # The agent's own grant first, then the exchange carrying it.
    assert seen == ["agent", "agent_live"]


async def test_provider_without_an_actor_fails_loudly_unless_impersonating():
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        nonlocal attempts
        attempts += 1
        return httpx.Response(200, json=SUCCESS_BODY)

    provider = DelegatedProvider(
        DelegationRequest(token_endpoint=TOKEN_ENDPOINT, client_id="c"),
        subject=TokenSource.static_token("user_at"),
    )

    with pytest.raises(DelegationError) as excinfo:
        await provider.get_token(_client(handler))

    assert excinfo.value.kind is DelegationErrorKind.MISSING_ACTOR
    assert "actor_token" in str(excinfo.value)
    assert attempts == 0


async def test_provider_exchanges_without_an_actor_when_impersonating():
    forms: List[List[Tuple[str, str]]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        forms.append(_form_of(request))
        return httpx.Response(200, json=SUCCESS_BODY)

    provider = DelegatedProvider(
        DelegationRequest(token_endpoint=TOKEN_ENDPOINT, client_id="c", impersonation=True),
        subject=TokenSource.static_token("user_at"),
    )
    assert await provider.get_token(_client(handler)) == "delegated_at"
    assert all(not key.startswith("actor_token") for key, _ in forms[0])


async def test_provider_single_flights_concurrent_callers():
    exchanges = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal exchanges
        exchanges += 1
        # Slow, so the other callers are reliably queued behind the leader
        # rather than racing it.
        await asyncio.sleep(0.05)
        return httpx.Response(200, json=SUCCESS_BODY)

    provider = _provider()
    client = _client(handler)

    results = await asyncio.gather(*(provider.get_token(client) for _ in range(5)))

    assert results == ["delegated_at"] * 5
    assert exchanges == 1


async def test_a_failed_exchange_leaves_no_token_cached():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error": "invalid_grant"})

    provider = _provider()
    with pytest.raises(DelegationError):
        await provider.get_token(_client(handler))
    assert provider.token() is None


def test_provider_repr_never_prints_tokens_or_secrets():
    rendered = repr(_provider())
    assert "agent_secret" not in rendered
    assert "user_at" not in rendered
    assert "agent_at" not in rendered
    assert "agent_client" in rendered


def test_request_repr_never_prints_tokens_or_secrets():
    rendered = repr(_request())
    assert "agent_secret" not in rendered
    assert "user_at" not in rendered
    assert "agent_at" not in rendered
    assert "agent_client" in rendered


# ─── cross-language contract ─────────────────────────────────────────────────
#
# ``testdata/contract.json`` holds the delegation fixture every language SDK
# checks: the grant type, the token-type URNs, the exact form body a fixture
# request must produce, the issued-token shape, the error kinds and the server
# error codes. See ``testdata/README.md``.

CONTRACT: Dict[str, Any] = json.loads(
    (Path(__file__).resolve().parents[2] / "testdata" / "contract.json").read_text()
)["delegation"]


def test_contract_fixture_pins_the_grant_type():
    assert GRANT_TYPE == CONTRACT["grant_type"]


def test_contract_fixture_pins_the_token_type_urns():
    urns = CONTRACT["token_types"]
    ours = {
        "access_token": TokenType.ACCESS_TOKEN,
        "jwt": TokenType.JWT,
        "id_token": TokenType.ID_TOKEN,
        "refresh_token": TokenType.REFRESH_TOKEN,
        "saml2": TokenType.SAML2,
    }
    # Fails both ways: a URN in the fixture this SDK does not name, and a name
    # this SDK has that the fixture does not.
    assert sorted(urns) == sorted(ours)
    for name, token_type in ours.items():
        assert urns[name] == token_type.as_urn(), name


def test_contract_fixture_request_produces_exactly_the_fixture_form():
    # The request fixture is what a port builds; ``request_form`` is the body
    # it must post, field for field and in order.
    fixture = CONTRACT["request"]
    request = DelegationRequest(
        token_endpoint=fixture["token_endpoint"],
        client_id=fixture["client_id"],
        client_secret=fixture["client_secret"],
        subject_token=fixture["subject_token"],
        subject_token_type=TokenType.from_urn(fixture["subject_token_type"]),
        actor_token=fixture["actor_token"],
        actor_token_type=TokenType.from_urn(fixture["actor_token_type"]),
        audience=fixture["audience"],
        resource=fixture["resource"],
        scope=fixture["scope"],
        requested_token_type=TokenType.from_urn(fixture["requested_token_type"]),
    )

    expected = [(key, value) for key, value in CONTRACT["request_form"]]
    assert request.form_params() == expected


async def test_contract_fixture_form_is_what_actually_goes_on_the_wire():
    # form_params() is only a promise; this reads the encoded body back.
    fixture = CONTRACT["request"]
    seen: List[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=CONTRACT["wire_response"])

    request = DelegationRequest(
        token_endpoint=fixture["token_endpoint"],
        client_id=fixture["client_id"],
        client_secret=fixture["client_secret"],
        subject_token=fixture["subject_token"],
        subject_token_type=TokenType.from_urn(fixture["subject_token_type"]),
        actor_token=fixture["actor_token"],
        actor_token_type=TokenType.from_urn(fixture["actor_token_type"]),
        audience=fixture["audience"],
        resource=fixture["resource"],
        scope=fixture["scope"],
        requested_token_type=TokenType.from_urn(fixture["requested_token_type"]),
    )
    await request.exchange(_client(handler))

    assert str(seen[0].url) == fixture["token_endpoint"]
    assert _form_of(seen[0]) == [(key, value) for key, value in CONTRACT["request_form"]]


def test_contract_fixture_token_loads_field_for_field():
    token = DelegatedToken.from_dict(CONTRACT["token"])
    assert token.access_token == "delegated_contract_fixture"
    assert token.issued_token_type == TokenType.ACCESS_TOKEN
    assert token.token_type == "Bearer"
    assert token.expires_at == 1_700_000_000
    assert token.scope == "mcp tools"


def test_contract_fixture_token_serializes_identically():
    assert DelegatedToken.from_dict(CONTRACT["token"]).to_dict() == CONTRACT["token"]


def test_contract_fixture_minimal_token_omits_absent_optionals():
    minimal = CONTRACT["token_minimal"]
    token = DelegatedToken.from_dict(minimal)
    assert token.expires_at is None
    assert not token.is_expired()
    # Not ``"scope": null`` — another SDK reading this must see absence.
    assert token.to_dict() == minimal


def test_contract_fixture_wire_response_parses_to_the_fixture_token():
    # The server's relative ``expires_in`` becomes an absolute ``expires_at``.
    # Everything else copies across unchanged.
    before = int(time.time())
    token = DelegatedToken.from_wire(CONTRACT["wire_response"])
    after = int(time.time())
    expected = DelegatedToken.from_dict(CONTRACT["token"])

    assert token.access_token == expected.access_token
    assert token.issued_token_type == expected.issued_token_type
    assert token.token_type == expected.token_type
    assert token.scope == expected.scope
    assert token.expires_at is not None
    assert before + 900 <= token.expires_at <= after + 900


def test_contract_fixture_pins_the_error_taxonomy():
    # A real Enum, so this fails both ways: a kind added to the SDK and not to
    # the fixture, and a kind in the fixture this SDK does not define.
    assert sorted(kind.value for kind in DelegationErrorKind) == sorted(CONTRACT["error_kinds"])


def test_contract_fixture_pins_the_server_error_codes():
    assert sorted(SERVER_ERROR_CODES) == sorted(CONTRACT["server_error_codes"])
    assert SERVER_ERROR_CODES == frozenset(code.value for code in ServerErrorCode)
