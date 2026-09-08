"""Tests for the OAuth 2.1 authorization-code + PKCE flow.

Ports the Rust reference suite: the same invariants, checked the same way, so a
behaviour that drifts in one language fails in the other. HTTP is stubbed with
:class:`httpx.MockTransport` rather than by patching, so the requests under
test are the real ones the SDK would send.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any, Callable, Dict, List, Optional

import httpx
import pytest

from datagrout.conduit.authcode import (
    DEFAULT_SCOPE,
    AuthCodeError,
    AuthCodeErrorKind,
    AuthCodeFlow,
    AuthCodeProvider,
    AuthServerMetadata,
    Grant,
    RegisteredClient,
    challenge_s256,
    generate_verifier,
    origin_of,
    provider_from_auth,
)

RESOURCE = "https://gateway.datagrout.ai/connect"

METADATA: Dict[str, Any] = {
    "issuer": "https://gateway.datagrout.ai",
    "authorization_endpoint": "https://gateway.datagrout.ai/oauth/authorize",
    "token_endpoint": "https://gateway.datagrout.ai/oauth/token",
    "registration_endpoint": "https://gateway.datagrout.ai/register",
    "code_challenge_methods_supported": ["S256"],
    "grant_types_supported": ["authorization_code", "refresh_token"],
}


def _client(handler: Callable[[httpx.Request], httpx.Response]) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _metadata_only(
    metadata: Optional[Dict[str, Any]] = None,
    *,
    seen: Optional[List[httpx.Request]] = None,
) -> httpx.AsyncClient:
    """A client that serves AS metadata and 404s everything else."""

    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        url = str(request.url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404, text="not found")
        if ".well-known" in url:
            return httpx.Response(200, json=metadata if metadata is not None else METADATA)
        return httpx.Response(404, text="unexpected")

    return _client(handler)


async def _flow(metadata: Optional[Dict[str, Any]] = None) -> AuthCodeFlow:
    """A flow standing where ``discover`` leaves it, with a client id set."""
    flow = await AuthCodeFlow.discover(RESOURCE, _metadata_only(metadata))
    return flow.with_client_id("client_abc", "http://127.0.0.1:8765/callback")


def _grant(expires_at: Optional[int] = None, refresh: Optional[str] = None) -> Grant:
    return Grant(
        access_token="at",
        client_id="client_abc",
        token_endpoint="https://gateway.datagrout.ai/oauth/token",
        refresh_token=refresh,
        expires_at=expires_at,
    )


def _now() -> int:
    return int(time.time())


# ─── PKCE ─────────────────────────────────────────────────────────────────────


def test_verifier_meets_rfc7636_length_and_alphabet():
    v = generate_verifier()
    assert len(v) == 43  # 32 bytes of base64url
    assert 43 <= len(v) <= 128
    assert all(c.isalnum() or c in "-._~" for c in v)


def test_verifiers_are_unique():
    assert generate_verifier() != generate_verifier()


def test_challenge_matches_the_rfc7636_test_vector():
    assert (
        challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    )


def test_challenge_is_unpadded_base64url():
    c = challenge_s256("anything")
    assert "=" not in c and "+" not in c and "/" not in c


# ─── authorize URL ────────────────────────────────────────────────────────────


async def test_authorize_url_carries_every_required_parameter():
    url, pending = (await _flow()).authorize_url()

    assert url.startswith("https://gateway.datagrout.ai/oauth/authorize?")
    assert "response_type=code" in url
    assert "client_id=client_abc" in url
    assert "code_challenge_method=S256" in url
    assert f"state={pending.state}" in url
    assert f"code_challenge={challenge_s256(pending.code_verifier)}" in url
    # The challenge travels; the verifier never does.
    assert pending.code_verifier not in url


async def test_authorize_url_percent_encodes_redirect_and_resource():
    url, _ = (await _flow()).authorize_url()
    assert "redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback" in url
    assert "resource=https%3A%2F%2Fgateway.datagrout.ai%2Fconnect" in url


async def test_authorize_url_binds_the_token_to_the_resource():
    # RFC 8707 — without this a token could be replayed at another server.
    url, _ = (await _flow()).authorize_url()
    assert "resource=" in url


async def test_authorize_url_requires_a_client_id():
    flow = await AuthCodeFlow.discover(RESOURCE, _metadata_only())
    with pytest.raises(AuthCodeError) as exc:
        flow.authorize_url()
    assert exc.value.kind is AuthCodeErrorKind.NO_CLIENT_ID


async def test_authorize_url_appends_when_the_endpoint_already_has_a_query():
    metadata = dict(METADATA, authorization_endpoint="https://example.com/authorize?foo=1")
    url, _ = (await _flow(metadata)).authorize_url()
    assert "/authorize?foo=1&response_type=code" in url


async def test_authorize_url_requests_the_default_scope():
    url, _ = (await _flow()).authorize_url()
    assert "scope=mcp%20tools" in url


# ─── state / CSRF ─────────────────────────────────────────────────────────────


async def test_exchange_refuses_a_mismatched_state():
    flow = await _flow()
    _, pending = flow.authorize_url()
    with pytest.raises(AuthCodeError) as exc:
        await flow.exchange(pending, "the_code", "not_the_state")
    assert exc.value.kind is AuthCodeErrorKind.STATE_MISMATCH


async def test_exchange_refuses_an_empty_state():
    flow = await _flow()
    _, pending = flow.authorize_url()
    with pytest.raises(AuthCodeError) as exc:
        await flow.exchange(pending, "code", "")
    assert exc.value.kind is AuthCodeErrorKind.STATE_MISMATCH


async def test_exchange_sends_the_verifier_and_resource_and_returns_a_grant():
    posted: Dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404)
        if ".well-known" in url:
            return httpx.Response(200, json=METADATA)
        posted.update(dict(pair.split("=", 1) for pair in request.content.decode().split("&")))
        return httpx.Response(
            200,
            json={
                "access_token": "new_at",
                "refresh_token": "new_rt",
                "expires_in": 3600,
                "scope": "mcp tools",
            },
        )

    flow = (await AuthCodeFlow.discover(RESOURCE, _client(handler))).with_client_id(
        "client_abc", "http://127.0.0.1:8765/callback"
    )
    _, pending = flow.authorize_url()
    grant = await flow.exchange(pending, "the_code", pending.state)

    assert posted["grant_type"] == "authorization_code"
    assert posted["code_verifier"] == pending.code_verifier
    assert posted["resource"] == "https%3A%2F%2Fgateway.datagrout.ai%2Fconnect"
    assert grant.access_token == "new_at"
    assert grant.refresh_token == "new_rt"
    assert grant.client_id == "client_abc"
    assert grant.resource == RESOURCE
    assert grant.expires_at is not None and grant.expires_at > _now()


async def test_exchange_reports_a_rejection_with_its_status_and_body():
    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404)
        if ".well-known" in url:
            return httpx.Response(200, json=METADATA)
        return httpx.Response(400, text='{"error":"invalid_grant"}')

    flow = (await AuthCodeFlow.discover(RESOURCE, _client(handler))).with_client_id(
        "c", "http://127.0.0.1:1/cb"
    )
    _, pending = flow.authorize_url()

    with pytest.raises(AuthCodeError) as exc:
        await flow.exchange(pending, "code", pending.state)
    assert exc.value.kind is AuthCodeErrorKind.TOKEN_EXCHANGE
    assert exc.value.status == 400
    assert "invalid_grant" in (exc.value.body or "")


async def test_exchange_refuses_a_token_response_that_is_not_an_object():
    # A 200 carrying a JSON array or string is not a token response. Reporting
    # it beats an attribute error deep in the parse.
    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404)
        if ".well-known" in url:
            return httpx.Response(200, json=METADATA)
        return httpx.Response(200, json=["not", "an", "object"])

    flow = (await AuthCodeFlow.discover(RESOURCE, _client(handler))).with_client_id(
        "c", "http://127.0.0.1:1/cb"
    )
    _, pending = flow.authorize_url()

    with pytest.raises(AuthCodeError) as exc:
        await flow.exchange(pending, "code", pending.state)
    assert exc.value.kind is AuthCodeErrorKind.HTTP
    assert "expected a JSON object" in str(exc.value)


# ─── Grant ────────────────────────────────────────────────────────────────────


def test_a_grant_with_no_stated_expiry_is_not_expired():
    assert not _grant().is_expired()


def test_a_grant_expires_early_by_the_refresh_skew():
    # Expires in 30s, skew is 60s → already due for refresh.
    assert _grant(_now() + 30, "rt").is_expired()
    assert not _grant(_now() + 600, "rt").is_expired()


async def test_refreshing_without_a_refresh_token_is_a_typed_error():
    with pytest.raises(AuthCodeError) as exc:
        await _grant(0).refresh(_client(lambda r: httpx.Response(200, json={})))
    assert exc.value.kind is AuthCodeErrorKind.NOT_REFRESHABLE


async def test_refresh_keeps_the_old_token_when_the_server_does_not_rotate():
    client = _client(lambda r: httpx.Response(200, json={"access_token": "at2", "expires_in": 60}))
    refreshed = await _grant(0, "original_rt").refresh(client)
    assert refreshed.access_token == "at2"
    # Silently dropping it would make the grant unrefreshable from here on.
    assert refreshed.refresh_token == "original_rt"


async def test_refresh_sends_the_resource_when_the_grant_is_bound():
    posted: Dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        posted.update(dict(pair.split("=", 1) for pair in request.content.decode().split("&")))
        return httpx.Response(200, json={"access_token": "at2"})

    grant = Grant(
        access_token="at",
        client_id="c",
        token_endpoint="https://e/t",
        refresh_token="rt",
        expires_at=0,
        resource=RESOURCE,
    )
    await grant.refresh(_client(handler))
    assert posted["grant_type"] == "refresh_token"
    assert posted["resource"] == "https%3A%2F%2Fgateway.datagrout.ai%2Fconnect"


def test_grant_round_trips_with_the_cross_language_field_names():
    # A grant written by one SDK must be readable by another.
    data = _grant(1_800_000_000, "rt").to_dict()
    assert data["access_token"] == "at"
    assert data["refresh_token"] == "rt"
    assert data["expires_at"] == 1_800_000_000
    assert data["client_id"] == "client_abc"
    assert isinstance(data["token_endpoint"], str)

    back = Grant.from_dict(json.loads(json.dumps(data)))
    assert back.access_token == "at"
    assert back.expires_at == 1_800_000_000


def test_grant_omits_absent_optionals():
    data = _grant().to_dict()
    assert "refresh_token" not in data
    assert "expires_at" not in data
    assert "scope" not in data
    assert "resource" not in data


def test_grant_reads_a_minimal_payload():
    g = Grant.from_dict({"access_token": "at", "client_id": "c", "token_endpoint": "https://e/t"})
    assert not g.is_refreshable()
    assert not g.is_expired()


async def test_expires_at_is_unix_seconds_not_a_monotonic_reading():
    # A monotonic value is meaningless once serialized, and process uptime is
    # nowhere near the epoch — this is the check that catches the mix-up.
    client = _client(
        lambda r: httpx.Response(200, json={"access_token": "at2", "expires_in": 3600})
    )
    refreshed = await _grant(0, "rt").refresh(client)
    assert refreshed.expires_at is not None
    assert abs(refreshed.expires_at - (_now() + 3600)) < 5
    assert refreshed.expires_at > 1_700_000_000


# ─── provider ─────────────────────────────────────────────────────────────────


async def test_provider_returns_a_live_token_without_refreshing():
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json={"access_token": "should_not_be_used"})

    provider = AuthCodeProvider(_grant(_now() + 3600, "rt"))
    assert await provider.get_token(_client(handler)) == "at"
    assert calls == 0
    assert not provider.is_dirty()


async def test_provider_refreshes_and_reports_a_rotated_grant():
    client = _client(
        lambda r: httpx.Response(
            200,
            json={"access_token": "fresh", "refresh_token": "rt2", "expires_in": 3600},
        )
    )
    provider = AuthCodeProvider(_grant(_now() - 10, "rt"))

    assert await provider.get_token(client) == "fresh"
    assert provider.is_dirty()

    # A rotated refresh token must reach the application, or the stored grant
    # goes stale and eventually invalidates the family.
    taken = provider.take_if_dirty()
    assert taken is not None and taken.refresh_token == "rt2"
    assert provider.take_if_dirty() is None


async def test_provider_de_duplicates_concurrent_refreshes():
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json={"access_token": "fresh", "expires_in": 3600})

    client = _client(handler)
    provider = AuthCodeProvider(_grant(_now() - 10, "rt"))

    tokens = await asyncio.gather(provider.get_token(client), provider.get_token(client))
    assert tokens == ["fresh", "fresh"]
    assert calls == 1


async def test_provider_invalidate_forces_the_next_fetch_to_refresh():
    provider = AuthCodeProvider(_grant(_now() + 3600))
    provider.invalidate()
    # No refresh token, so the forced refresh surfaces rather than silently
    # returning the stale token.
    with pytest.raises(AuthCodeError) as exc:
        await provider.get_token(_client(lambda r: httpx.Response(200, json={})))
    assert exc.value.kind is AuthCodeErrorKind.NOT_REFRESHABLE


def test_provider_invalidate_keeps_the_refresh_token():
    # Dropping the grant would make recovery impossible.
    provider = AuthCodeProvider(_grant(_now() + 3600, "rt"))
    provider.invalidate()
    assert provider.grant().refresh_token == "rt"
    assert provider.grant().is_expired()


def test_take_if_dirty_is_empty_until_something_changes():
    assert AuthCodeProvider(_grant(_now() + 3600, "rt")).take_if_dirty() is None


def test_provider_from_auth_accepts_every_shape():
    assert provider_from_auth(None) is None
    assert isinstance(provider_from_auth(_grant()), AuthCodeProvider)
    assert isinstance(provider_from_auth(_grant().to_dict()), AuthCodeProvider)

    mine = AuthCodeProvider(_grant())
    # Identity matters: the caller polls their own provider for a rotated grant.
    assert provider_from_auth(mine) is mine


def test_provider_from_auth_rejects_nonsense():
    with pytest.raises(AuthCodeError):
        provider_from_auth(42)


async def test_a_failing_refresh_costs_one_request_for_every_waiter():
    # The refresh is single-flighted, so waiters share the leader's outcome —
    # including its failure. Before, each queued caller re-acquired the lock,
    # found the grant still expired and tried again, so a dead token endpoint
    # cost one round trip per waiter.
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(400, json={"error": "invalid_grant"})

    provider = AuthCodeProvider(_grant(0, "rt"))
    client = _client(handler)

    results = await asyncio.gather(
        *[provider.get_token(client) for _ in range(5)], return_exceptions=True
    )

    assert all(isinstance(r, AuthCodeError) for r in results)
    assert calls == 1


async def test_concurrent_callers_share_one_successful_refresh():
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(
            200, json={"access_token": "at_2", "refresh_token": "rt_2", "expires_in": 3600}
        )

    provider = AuthCodeProvider(_grant(0, "rt_1"))
    client = _client(handler)

    tokens = await asyncio.gather(*[provider.get_token(client) for _ in range(5)])

    assert tokens == ["at_2"] * 5
    assert calls == 1


async def test_a_later_call_retries_after_a_failure_rather_than_replaying_it():
    # The shared failure belongs to the callers that queued behind that
    # attempt, not to the future: once it has settled, the next call tries
    # again.
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(400, json={"error": "temporarily_unavailable"})
        return httpx.Response(200, json={"access_token": "at_2", "expires_in": 3600})

    provider = AuthCodeProvider(_grant(0, "rt"))
    client = _client(handler)

    with pytest.raises(AuthCodeError):
        await provider.get_token(client)

    assert await provider.get_token(client) == "at_2"


async def test_the_grant_stays_readable_while_a_refresh_is_in_flight():
    started = asyncio.Event()
    release = asyncio.Event()

    async def handler(request: httpx.Request) -> httpx.Response:
        started.set()
        await release.wait()
        return httpx.Response(200, json={"access_token": "at_2", "expires_in": 3600})

    provider = AuthCodeProvider(_grant(0, "rt"))
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    pending = asyncio.create_task(provider.get_token(client))
    await asyncio.wait_for(started.wait(), timeout=2)

    # The lock is not held across the request, so a persistence loop keeps
    # working while a slow token endpoint is being waited on.
    assert provider.grant().access_token == "at"
    assert provider.take_if_dirty() is None

    release.set()
    assert await asyncio.wait_for(pending, timeout=2) == "at_2"


# ─── metadata / discovery ─────────────────────────────────────────────────────


def test_s256_support_is_assumed_when_unadvertised():
    assert AuthServerMetadata.from_dict(
        {"authorization_endpoint": "a", "token_endpoint": "t"}
    ).supports_s256()
    assert AuthServerMetadata.from_dict(
        dict(METADATA, code_challenge_methods_supported=[])
    ).supports_s256()


def test_a_server_advertising_only_plain_is_refused():
    assert not AuthServerMetadata.from_dict(
        dict(METADATA, code_challenge_methods_supported=["plain"])
    ).supports_s256()


def test_metadata_tolerates_a_missing_registration_endpoint():
    m = AuthServerMetadata.from_dict(
        {"authorization_endpoint": "https://e/a", "token_endpoint": "https://e/t"}
    )
    assert m.registration_endpoint is None


def test_metadata_without_the_required_endpoints_is_a_discovery_error():
    with pytest.raises(AuthCodeError) as exc:
        AuthServerMetadata.from_dict({"issuer": "https://e"})
    assert exc.value.kind is AuthCodeErrorKind.DISCOVERY


async def test_discover_refuses_to_downgrade_pkce():
    client = _metadata_only(dict(METADATA, code_challenge_methods_supported=["plain"]))
    with pytest.raises(AuthCodeError) as exc:
        await AuthCodeFlow.discover(RESOURCE, client)
    assert exc.value.kind is AuthCodeErrorKind.PKCE_UNSUPPORTED


async def test_discover_follows_protected_resource_metadata():
    seen: List[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        seen.append(url)
        if "oauth-protected-resource" in url:
            return httpx.Response(200, json={"authorization_servers": ["https://as.example.com"]})
        return httpx.Response(200, json=METADATA)

    await AuthCodeFlow.discover(RESOURCE, _client(handler))
    assert any(u.startswith("https://as.example.com/.well-known/") for u in seen)


async def test_discover_falls_back_to_the_resource_origin():
    seen: List[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        seen.append(url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404)
        return httpx.Response(200, json=METADATA)

    await AuthCodeFlow.discover(RESOURCE, _client(handler))
    # DataGrout serves AS metadata at the origin, not under /connect.
    assert "https://gateway.datagrout.ai/.well-known/oauth-authorization-server" in seen


async def test_discover_reports_failure_when_no_metadata_is_found():
    client = _client(lambda r: httpx.Response(404, text="nope"))
    with pytest.raises(AuthCodeError) as exc:
        await AuthCodeFlow.discover(RESOURCE, client)
    assert exc.value.kind is AuthCodeErrorKind.DISCOVERY


async def test_discover_ignores_resource_metadata_that_is_not_an_object():
    # A proxy or captive portal answering 200 with a string body is not
    # metadata; discovery should carry on to the resource origin.
    seen: List[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        seen.append(url)
        if "oauth-protected-resource" in url:
            return httpx.Response(200, json="not an object")
        return httpx.Response(200, json=METADATA)

    await AuthCodeFlow.discover(RESOURCE, _client(handler))
    assert "https://gateway.datagrout.ai/.well-known/oauth-authorization-server" in seen


async def test_discover_does_not_leak_a_client_it_created_on_failure():
    # `discover` owns the client when the caller passes none; a failure must
    # not strand it.
    created: List[httpx.AsyncClient] = []
    real_init = httpx.AsyncClient.__init__

    def spy(self: httpx.AsyncClient, *args: Any, **kwargs: Any) -> None:
        real_init(self, *args, **kwargs)
        created.append(self)

    httpx.AsyncClient.__init__ = spy  # type: ignore[method-assign]
    try:
        with pytest.raises(AuthCodeError):
            await AuthCodeFlow.discover("not a url")
    finally:
        httpx.AsyncClient.__init__ = real_init  # type: ignore[method-assign]

    assert created, "discover should have created a client"
    assert all(c.is_closed for c in created)


async def test_flow_as_a_context_manager_closes_only_a_client_it_owns():
    borrowed = _metadata_only()
    async with await AuthCodeFlow.discover(RESOURCE, borrowed):
        pass
    # The caller's client is theirs to close.
    assert not borrowed.is_closed
    await borrowed.aclose()


async def test_register_sends_a_public_client_and_returns_the_pair():
    body: Dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404)
        if ".well-known" in url:
            return httpx.Response(200, json=METADATA)
        body.update(json.loads(request.content.decode()))
        return httpx.Response(201, json={"client_id": "issued_id"})

    flow = await AuthCodeFlow.discover(RESOURCE, _client(handler))
    client = await flow.register("My App", "http://127.0.0.1:9/cb")

    # A desktop app cannot keep a secret; PKCE stands in for one.
    assert body["token_endpoint_auth_method"] == "none"
    assert body["redirect_uris"] == ["http://127.0.0.1:9/cb"]
    assert "refresh_token" in body["grant_types"]
    assert client == RegisteredClient("issued_id", "http://127.0.0.1:9/cb")
    # The flow is now ready to authorize without further setup.
    assert flow.client_id == "issued_id"
    assert flow.redirect_uri == "http://127.0.0.1:9/cb"


async def test_register_without_an_endpoint_is_a_distinct_error():
    metadata = {k: v for k, v in METADATA.items() if k != "registration_endpoint"}
    flow = await AuthCodeFlow.discover(RESOURCE, _metadata_only(metadata))
    with pytest.raises(AuthCodeError) as exc:
        await flow.register("App", "http://127.0.0.1:9/cb")
    assert exc.value.kind is AuthCodeErrorKind.NO_REGISTRATION_ENDPOINT


async def test_register_rejection_carries_the_status_and_body():
    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth-protected-resource" in url:
            return httpx.Response(404)
        if ".well-known" in url:
            return httpx.Response(200, json=METADATA)
        return httpx.Response(400, text="bad redirect_uri")

    flow = await AuthCodeFlow.discover(RESOURCE, _client(handler))
    with pytest.raises(AuthCodeError) as exc:
        await flow.register("App", "http://127.0.0.1:9/cb")
    assert exc.value.kind is AuthCodeErrorKind.REGISTRATION_REJECTED
    assert exc.value.status == 400
    assert exc.value.body == "bad redirect_uri"


async def test_restoring_a_registered_client_restores_both_halves():
    # Reusing an id against a different redirect URI is rejected by the server,
    # so the pair must survive together.
    flow = (await AuthCodeFlow.discover(RESOURCE, _metadata_only())).with_registered_client(
        RegisteredClient("saved_id", "http://127.0.0.1:9999/cb")
    )
    assert flow.client_id == "saved_id"
    assert flow.redirect_uri == "http://127.0.0.1:9999/cb"

    url, _ = flow.authorize_url()
    assert "client_id=saved_id" in url
    assert "redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb" in url


def test_registered_client_round_trips():
    client = RegisteredClient("client_abc", "http://127.0.0.1:8765/callback")
    assert RegisteredClient.from_dict(client.to_dict()) == client


# ─── helpers ──────────────────────────────────────────────────────────────────


def test_origin_strips_paths_and_keeps_ports():
    assert origin_of("https://gateway.datagrout.ai/connect") == "https://gateway.datagrout.ai"
    assert origin_of("http://localhost:4000/servers/abc/mcp") == "http://localhost:4000"
    assert origin_of("not a url") is None


def test_default_scope_matches_the_servers_own_vocabulary():
    # Inventing finer-grained scopes is worse than useless here: the server
    # splits on whitespace and stores what it is handed, so a made-up scope is
    # accepted silently and then means nothing.
    assert DEFAULT_SCOPE == "mcp tools"


def test_error_kinds_use_the_shared_wire_names():
    # The taxonomy is a cross-language contract, so the names are load-bearing.
    assert AuthCodeErrorKind.STATE_MISMATCH.value == "state_mismatch"
    assert AuthCodeErrorKind.NOT_REFRESHABLE.value == "not_refreshable"
    assert AuthCodeErrorKind.NO_REGISTRATION_ENDPOINT.value == "no_registration_endpoint"
