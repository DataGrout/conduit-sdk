"""Capture the OAuth redirect on ``127.0.0.1``.

A native app has no web server to redirect to, so it runs one for a few
seconds: bind a loopback port, send the user to the consent page, and read the
``code`` off the single request the browser makes coming back.

This lives in its own module rather than in :mod:`~datagrout.conduit.authcode`
so a headless caller can take the flow without a listener it will never bind —
the same split every conduit SDK makes, so the surface looks the same in every
language. It needs no dependency beyond :mod:`asyncio`.

Example::

    from datagrout.conduit.authcode import AuthCodeFlow
    from datagrout.conduit.loopback import LoopbackListener

    listener = await LoopbackListener.bind()
    async with await AuthCodeFlow.discover(GATEWAY) as flow:
        await flow.register("My App", listener.redirect_uri)
        url, pending = flow.authorize_url()
        print(f"Open: {url}")
        redirect = await listener.wait(timeout=300)
        grant = await flow.exchange(pending, redirect.code, redirect.state)
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Dict, Optional
from urllib.parse import unquote_plus, urlparse

from .authcode import AuthCodeError, AuthCodeErrorKind

#: Most bytes read from a redirect request. A URL longer than this is not a
#: redirect we can use.
_MAX_REQUEST_BYTES = 8192


@dataclass(frozen=True)
class Redirect:
    """What the authorization server sent back to the redirect URI."""

    #: The authorization code.
    code: str
    #: The ``state`` parameter, to be checked against the pending request.
    state: str


class LoopbackListener:
    """A one-shot loopback listener for the OAuth redirect."""

    def __init__(self, server: asyncio.AbstractServer, port: int, path: str) -> None:
        self._server = server
        self._port = port
        self._path = path
        self._result: asyncio.Future[Redirect] = asyncio.get_running_loop().create_future()

    # ─── Binding ──────────────────────────────────────────────────────────────

    @classmethod
    async def bind(cls) -> LoopbackListener:
        """Bind an OS-assigned port on ``127.0.0.1``.

        Letting the OS choose avoids fighting whatever else owns a fixed port —
        and because registration happens after binding, the real port is
        already known by the time the redirect URI is registered.
        """
        return await cls.bind_on(0, "/callback")

    @classmethod
    async def bind_on(cls, port: int, path: str) -> LoopbackListener:
        """Bind a specific port and path.

        Use when the client was registered out of band against a fixed redirect
        URI and the authorization server will accept no other.
        """
        normalized = path if path.startswith("/") else f"/{path}"

        # The handler needs the listener, which needs the server, which needs
        # the handler. A holder breaks the cycle without a window in which a
        # request could arrive before the listener exists.
        holder: Dict[str, LoopbackListener] = {}

        async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            listener = holder.get("listener")
            if listener is None:  # pragma: no cover - a request beat the bind
                writer.close()
                return
            await listener._handle(reader, writer)

        try:
            server = await asyncio.start_server(handle, "127.0.0.1", port)
        except OSError as exc:
            raise AuthCodeError(
                AuthCodeErrorKind.HTTP, f"cannot bind loopback port: {exc}"
            ) from exc

        bound = server.sockets[0].getsockname()[1] if server.sockets else port
        listener = cls(server, bound, normalized)
        holder["listener"] = listener
        return listener

    @classmethod
    async def bind_for(cls, redirect_uri: str) -> LoopbackListener:
        """Re-bind the exact port and path of a previously registered URI.

        Needed whenever a saved :class:`~datagrout.conduit.authcode.RegisteredClient`
        is reused: the authorization server matches the redirect URI exactly, so
        the listener has to come back on the same port it registered.

        Raises if that port is occupied. The right recovery is to :meth:`bind` a
        fresh port and register a new client — not to retry, and not to
        authorize against a URI the server will reject.
        """
        parsed = urlparse(redirect_uri)
        if not parsed.scheme or not parsed.hostname:
            raise AuthCodeError(AuthCodeErrorKind.HTTP, f"bad redirect_uri {redirect_uri}")
        if not parsed.port:
            raise AuthCodeError(
                AuthCodeErrorKind.HTTP, f"redirect_uri {redirect_uri} names no port"
            )
        return await cls.bind_on(parsed.port, parsed.path or "/")

    # ─── Accessors ────────────────────────────────────────────────────────────

    @property
    def port(self) -> int:
        """The port actually bound."""
        return self._port

    @property
    def redirect_uri(self) -> str:
        """The redirect URI to register and to send in the authorize request.

        Uses ``127.0.0.1`` rather than ``localhost``: RFC 8252 recommends the
        literal address, and it sidesteps hosts where ``localhost`` resolves to
        IPv6 first while the listener is bound to IPv4.
        """
        return f"http://127.0.0.1:{self._port}{self._path}"

    # ─── Waiting ──────────────────────────────────────────────────────────────

    async def wait(self, timeout: float = 300.0) -> Redirect:
        """Wait for the browser's redirect, up to ``timeout`` seconds.

        Serves a small page either way so the user sees an outcome rather than a
        browser error, then stops listening. Requests to other paths are
        answered 404 and ignored — browsers routinely ask for ``/favicon.ico``,
        and treating that as the redirect would abort the flow.
        """
        try:
            return await asyncio.wait_for(asyncio.shield(self._result), timeout)
        except asyncio.TimeoutError as exc:
            raise AuthCodeError(
                AuthCodeErrorKind.HTTP,
                f"timed out after {timeout:.0f}s waiting for the authorization " f"redirect",
            ) from exc
        finally:
            await self.aclose()

    async def aclose(self) -> None:
        """Stop listening. Safe to call more than once."""
        self._server.close()
        try:
            await self._server.wait_closed()
        except Exception:  # pragma: no cover - platform dependent
            pass

    async def __aenter__(self) -> LoopbackListener:
        return self

    async def __aexit__(self, *_exc: object) -> None:
        await self.aclose()

    # ─── Request handling ─────────────────────────────────────────────────────

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            raw = await reader.read(_MAX_REQUEST_BYTES)
            target = _request_target(raw.decode("utf-8", "replace"))
            if target is None:
                return

            path, _, query = target.partition("?")

            if path != self._path:
                await _respond(writer, 404, "Not found")
                return

            params = _parse_query(query)

            if "error" in params:
                await _respond(writer, 200, "Authorization was denied. You can close this window.")
                description = params.get("error_description")
                self._fail(
                    AuthCodeError(
                        AuthCodeErrorKind.DENIED,
                        f"authorization denied: {params['error']}"
                        + (f" — {description}" if description else ""),
                    )
                )
                return

            if "code" in params and "state" in params:
                await _respond(
                    writer,
                    200,
                    "Signed in. You can close this window and return to the app.",
                )
                self._succeed(Redirect(code=params["code"], state=params["state"]))
                return

            await _respond(writer, 400, "Missing code or state.")
            self._fail(
                AuthCodeError(
                    AuthCodeErrorKind.DISCOVERY,
                    "redirect carried neither an error nor a code/state pair",
                )
            )
        finally:
            writer.close()

    def _succeed(self, redirect: Redirect) -> None:
        if not self._result.done():
            self._result.set_result(redirect)

    def _fail(self, error: AuthCodeError) -> None:
        if not self._result.done():
            self._result.set_exception(error)


def _request_target(request: str) -> Optional[str]:
    """The request target from a raw HTTP request line."""
    first = request.split("\r\n", 1)[0].split("\n", 1)[0]
    parts = first.split()
    return parts[1] if len(parts) >= 2 else None


def _parse_query(query: str) -> Dict[str, str]:
    """Decode a query string.

    Authorization codes and state values are opaque and routinely contain
    characters that must survive a round trip through the query string, so
    ``%XX`` escapes and ``+`` are decoded.
    """
    out: Dict[str, str] = {}
    for pair in query.split("&"):
        if not pair:
            continue
        key, sep, value = pair.partition("=")
        if not sep:
            continue
        out[unquote_plus(key)] = unquote_plus(value)
    return out


async def _respond(writer: asyncio.StreamWriter, status: int, message: str) -> None:
    body = (
        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>DataGrout</title>'
        "<style>body{font:15px/1.5 system-ui,sans-serif;margin:16vh auto;"
        "max-width:26rem;text-align:center;color-scheme:light dark}</style></head>"
        f"<body><p>{message}</p></body></html>"
    ).encode("utf-8")

    head = (
        f"HTTP/1.1 {status} OK\r\n"
        "content-type: text/html; charset=utf-8\r\n"
        f"content-length: {len(body)}\r\n"
        "connection: close\r\n\r\n"
    ).encode("ascii")

    writer.write(head + body)
    try:
        await writer.drain()
    except Exception:  # pragma: no cover - client may have closed already
        pass
