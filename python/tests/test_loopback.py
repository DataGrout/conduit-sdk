"""Tests for the loopback redirect listener.

Ports the Rust reference suite. These bind real sockets on 127.0.0.1 and drive
them with real requests, because the failures worth catching here are exactly
the ones a mocked server cannot have: a port that will not re-bind, a favicon
request mistaken for the redirect, a response that never flushes.
"""

from __future__ import annotations

import asyncio

import httpx
import pytest

from datagrout.conduit.authcode import AuthCodeError, AuthCodeErrorKind
from datagrout.conduit.loopback import LoopbackListener


async def _get(url: str) -> httpx.Response:
    async with httpx.AsyncClient(timeout=5.0) as client:
        return await client.get(url)


async def test_binds_a_loopback_port_and_reports_it():
    listener = await LoopbackListener.bind()
    try:
        assert listener.port > 0
        assert listener.redirect_uri == f"http://127.0.0.1:{listener.port}/callback"
    finally:
        await listener.aclose()


async def test_redirect_uri_uses_the_literal_address_not_localhost():
    # RFC 8252, and it avoids IPv6-vs-IPv4 resolution surprises.
    listener = await LoopbackListener.bind()
    try:
        assert "127.0.0.1" in listener.redirect_uri
        assert "localhost" not in listener.redirect_uri
    finally:
        await listener.aclose()


async def test_bind_for_reuses_the_exact_port_and_path_of_a_saved_uri():
    # A saved client id is bound to its redirect URI exactly, so a later run
    # has to come back on the same port.
    first = await LoopbackListener.bind_on(0, "/cb")
    uri, port = first.redirect_uri, first.port
    await first.aclose()

    again = await LoopbackListener.bind_for(uri)
    try:
        assert again.port == port
        assert again.redirect_uri == uri
    finally:
        await again.aclose()


async def test_bind_for_fails_loudly_when_the_port_is_taken():
    held = await LoopbackListener.bind()
    try:
        # Better a clear failure the caller can answer by re-registering than
        # authorizing against a URI the server will reject.
        with pytest.raises(AuthCodeError) as exc:
            await LoopbackListener.bind_for(held.redirect_uri)
        assert "cannot bind loopback port" in str(exc.value)
    finally:
        await held.aclose()


async def test_bind_for_rejects_a_uri_with_no_port():
    with pytest.raises(AuthCodeError) as exc:
        await LoopbackListener.bind_for("https://example.com/callback")
    assert "names no port" in str(exc.value)


async def test_normalises_a_path_without_a_leading_slash():
    listener = await LoopbackListener.bind_on(0, "cb")
    try:
        assert listener.redirect_uri.endswith("/cb")
    finally:
        await listener.aclose()


async def test_captures_code_and_state_from_the_redirect():
    listener = await LoopbackListener.bind()
    waiting = asyncio.create_task(listener.wait(timeout=5))

    response = await _get(f"{listener.redirect_uri}?code=the_code&state=the_state")
    assert response.status_code == 200
    # The user sees an outcome rather than a browser error.
    assert "Signed in" in response.text

    redirect = await waiting
    assert redirect.code == "the_code"
    assert redirect.state == "the_state"


async def test_ignores_a_favicon_request_and_keeps_waiting():
    listener = await LoopbackListener.bind()
    waiting = asyncio.create_task(listener.wait(timeout=5))

    # A browser asks for this unprompted; treating it as the redirect would
    # abort the flow.
    favicon = await _get(f"http://127.0.0.1:{listener.port}/favicon.ico")
    assert favicon.status_code == 404

    await _get(f"{listener.redirect_uri}?code=c2&state=s2")
    redirect = await waiting
    assert redirect.code == "c2"


async def test_surfaces_a_denial_as_a_typed_error():
    listener = await LoopbackListener.bind()
    waiting = asyncio.create_task(listener.wait(timeout=5))

    await _get(f"{listener.redirect_uri}?error=access_denied&error_description=User%20said%20no")

    with pytest.raises(AuthCodeError) as exc:
        await waiting
    assert exc.value.kind is AuthCodeErrorKind.DENIED
    assert "access_denied — User said no" in str(exc.value)


async def test_rejects_a_redirect_with_neither_an_error_nor_a_code():
    listener = await LoopbackListener.bind()
    waiting = asyncio.create_task(listener.wait(timeout=5))

    response = await _get(listener.redirect_uri)
    assert response.status_code == 400

    with pytest.raises(AuthCodeError) as exc:
        await waiting
    assert "neither an error nor a code" in str(exc.value)


async def test_times_out_when_no_redirect_arrives():
    listener = await LoopbackListener.bind()
    with pytest.raises(AuthCodeError) as exc:
        await listener.wait(timeout=0.1)
    assert "timed out" in str(exc.value)


async def test_decodes_percent_escapes_in_the_code_and_state():
    # Codes and state values are opaque and routinely contain characters that
    # must survive a round trip through the query string.
    listener = await LoopbackListener.bind()
    waiting = asyncio.create_task(listener.wait(timeout=5))

    await _get(f"{listener.redirect_uri}?code=a%2Fb&state=x%20y")
    redirect = await waiting
    assert redirect.code == "a/b"
    assert redirect.state == "x y"


async def test_wait_stops_listening_afterwards():
    # One-shot: the port is released once the redirect is captured, so a later
    # run can re-bind it.
    listener = await LoopbackListener.bind()
    port = listener.port
    waiting = asyncio.create_task(listener.wait(timeout=5))
    await _get(f"{listener.redirect_uri}?code=c&state=s")
    await waiting

    again = await LoopbackListener.bind_on(port, "/callback")
    await again.aclose()


async def test_works_as_an_async_context_manager():
    async with await LoopbackListener.bind() as listener:
        assert listener.port > 0
    # Closed on exit, so the port is free again.
    again = await LoopbackListener.bind_on(listener.port, "/callback")
    await again.aclose()
