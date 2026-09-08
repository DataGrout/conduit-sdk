"""OAuth 2.1 **authorization code + PKCE** — browser-consent sign-in.

The ``client_credentials`` grant in :mod:`datagrout.conduit.oauth`
authenticates a *machine*: it needs a client secret issued out of band. This
module authenticates a *person*: the app opens a browser, the user consents at
the gateway, and the app receives a grant bound to that user's account. It is
what a desktop or CLI application needs, and the only way to use
``https://gateway.datagrout.ai/connect``, where the server binding is chosen at
consent time and lives in the token rather than the URL.

Flow:

1. :meth:`AuthCodeFlow.discover` — protected-resource metadata, then the
   authorization server's metadata.
2. :meth:`AuthCodeFlow.register` — RFC 7591 dynamic client registration, as a
   **public client** (no secret; PKCE takes its place).
3. :meth:`AuthCodeFlow.authorize_url` — build the consent URL and hold the PKCE
   verifier and CSRF state in a :class:`PendingAuthorization`.
4. The caller opens that URL and captures the redirect.
   :mod:`datagrout.conduit.loopback` can do the capturing.
5. :meth:`AuthCodeFlow.exchange` — trade the code for a :class:`Grant`.

Example::

    from datagrout.conduit.authcode import AuthCodeFlow

    async with await AuthCodeFlow.discover(
        "https://gateway.datagrout.ai/connect"
    ) as flow:
        registered = await flow.register("My App", "http://127.0.0.1:8765/callback")
        url, pending = flow.authorize_url()
        print(f"Open: {url}")
        grant = await flow.exchange(pending, code, state)

**Persisting the grant.** This module owns the :class:`Grant` shape and its
refresh logic; it deliberately does *not* choose where a grant is stored. That
is the application's decision — an OS keychain, a config file, a vault — and
baking a filesystem opinion into an SDK makes it wrong for half its callers.

:attr:`Grant.expires_at` is Unix **seconds**, not a monotonic clock reading
(which is what :mod:`~datagrout.conduit.oauth` uses for its in-memory cache).
The difference matters: a grant is written by one process and read by another,
possibly in a different language, and a monotonic value is meaningless once
serialized.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import logging
import secrets
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote, urlparse

import httpx

from .errors import ConduitError

logger = logging.getLogger(__name__)

#: Scopes requested when the caller does not specify.
#:
#: Matches the authorization server's own registration default rather than
#: inventing a finer-grained vocabulary: DataGrout splits the scope string on
#: whitespace and stores what it is given, so a made-up scope is accepted
#: silently and then means nothing.
DEFAULT_SCOPE = "mcp tools"

#: Refresh this many seconds before the token actually expires.
_REFRESH_SKEW_SECS = 60


# ─── Errors ──────────────────────────────────────────────────────────────────


class AuthCodeErrorKind(str, Enum):
    """The distinguishable failures of the authorization-code flow.

    The taxonomy is part of the cross-language contract: every conduit SDK
    distinguishes these same cases, so callers can branch identically.
    """

    #: Metadata discovery failed or returned something unusable.
    DISCOVERY = "discovery"
    #: The authorization server does not advertise dynamic client registration.
    NO_REGISTRATION_ENDPOINT = "no_registration_endpoint"
    #: Dynamic client registration was rejected.
    REGISTRATION_REJECTED = "registration_rejected"
    #: ``authorize_url`` was called before a client id was known.
    NO_CLIENT_ID = "no_client_id"
    #: The server does not support PKCE with S256.
    PKCE_UNSUPPORTED = "pkce_unsupported"
    #: The ``state`` returned by the redirect did not match the one sent.
    STATE_MISMATCH = "state_mismatch"
    #: The token endpoint rejected the exchange or refresh.
    TOKEN_EXCHANGE = "token_exchange"
    #: The grant has no refresh token, so it cannot be renewed.
    NOT_REFRESHABLE = "not_refreshable"
    #: The authorization server returned an error at the redirect.
    DENIED = "denied"
    #: Transport failure talking to the authorization server.
    HTTP = "http"


class AuthCodeError(ConduitError):
    """An error from the authorization-code flow, tagged with its kind."""

    def __init__(
        self,
        kind: AuthCodeErrorKind,
        message: str,
        *,
        status: Optional[int] = None,
        body: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.kind = kind
        #: HTTP status, for ``REGISTRATION_REJECTED`` and ``TOKEN_EXCHANGE``.
        self.status = status
        #: Response body, for ``REGISTRATION_REJECTED`` and ``TOKEN_EXCHANGE``.
        self.body = body


# ─── Metadata ────────────────────────────────────────────────────────────────


@dataclass
class AuthServerMetadata:
    """RFC 8414 authorization server metadata (the fields this flow uses)."""

    authorization_endpoint: str
    token_endpoint: str
    issuer: str = ""
    registration_endpoint: Optional[str] = None
    code_challenge_methods_supported: List[str] = field(default_factory=list)
    grant_types_supported: List[str] = field(default_factory=list)
    scopes_supported: List[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> AuthServerMetadata:
        """Parse a metadata document, ignoring fields this flow does not use."""
        try:
            return cls(
                authorization_endpoint=data["authorization_endpoint"],
                token_endpoint=data["token_endpoint"],
                issuer=data.get("issuer", ""),
                registration_endpoint=data.get("registration_endpoint"),
                code_challenge_methods_supported=list(
                    data.get("code_challenge_methods_supported") or []
                ),
                grant_types_supported=list(data.get("grant_types_supported") or []),
                scopes_supported=list(data.get("scopes_supported") or []),
            )
        except KeyError as exc:
            raise AuthCodeError(
                AuthCodeErrorKind.DISCOVERY,
                f"OAuth discovery failed: metadata is missing {exc.args[0]}",
            ) from exc

    def supports_s256(self) -> bool:
        """Whether S256 is usable.

        An empty list means the server did not advertise. RFC 8414 makes the
        field optional and DataGrout omits it on some paths, so absence is
        treated as "assume S256" rather than as a refusal — a server that truly
        cannot do S256 will reject the authorize request anyway.
        """
        if not self.code_challenge_methods_supported:
            return True
        return any(m.upper() == "S256" for m in self.code_challenge_methods_supported)


# ─── Grant ───────────────────────────────────────────────────────────────────


@dataclass
class RegisteredClient:
    """A dynamically-registered client: the id **and** its redirect URI.

    These travel together because an authorization server matches the redirect
    URI *exactly* against the value registered — there is no loopback-port
    exemption to rely on. Persisting the id alone means a later re-authorization
    on a freshly-chosen port is rejected as ``invalid_redirect_uri``, and the
    failure only shows up once the first grant can no longer be refreshed.
    """

    client_id: str
    redirect_uri: str

    def to_dict(self) -> Dict[str, str]:
        return {"client_id": self.client_id, "redirect_uri": self.redirect_uri}

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> RegisteredClient:
        return cls(client_id=data["client_id"], redirect_uri=data["redirect_uri"])


@dataclass
class Grant:
    """A user's authorization, ready to persist.

    The serialized shape is part of the cross-language contract: a grant written
    by one conduit SDK must be readable by another. Field names are therefore
    fixed, and ``expires_at`` is Unix seconds.
    """

    access_token: str
    client_id: str
    token_endpoint: str
    refresh_token: Optional[str] = None
    #: Absolute expiry, Unix seconds. ``None`` means the server did not say.
    expires_at: Optional[int] = None
    scope: Optional[str] = None
    #: The resource this grant is bound to (RFC 8707).
    resource: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """The JSON form, omitting absent optionals.

        Omission rather than ``null`` keeps the document identical to what the
        other SDKs write, so a grant round-trips between languages byte for byte.
        """
        data: Dict[str, Any] = {
            "access_token": self.access_token,
            "client_id": self.client_id,
            "token_endpoint": self.token_endpoint,
        }
        if self.refresh_token is not None:
            data["refresh_token"] = self.refresh_token
        if self.expires_at is not None:
            data["expires_at"] = self.expires_at
        if self.scope is not None:
            data["scope"] = self.scope
        if self.resource is not None:
            data["resource"] = self.resource
        return data

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> Grant:
        """Read a grant written by any conduit SDK."""
        return cls(
            access_token=data["access_token"],
            client_id=data["client_id"],
            token_endpoint=data["token_endpoint"],
            refresh_token=data.get("refresh_token"),
            expires_at=data.get("expires_at"),
            scope=data.get("scope"),
            resource=data.get("resource"),
        )

    def is_expired(self) -> bool:
        """True when the access token is expired, or within the refresh skew.

        A grant with no stated expiry is treated as live: the server chose not
        to say, and guessing an expiry would throw away working tokens.
        """
        if self.expires_at is None:
            return False
        return _now_secs() + _REFRESH_SKEW_SECS >= self.expires_at

    def is_refreshable(self) -> bool:
        """Whether this grant can renew itself without user interaction."""
        return bool(self.refresh_token)

    async def refresh(self, http_client: httpx.AsyncClient) -> Grant:
        """Exchange the refresh token for a fresh grant.

        Returns a *new* grant; the old one should be discarded. DataGrout
        rotates refresh tokens, so keeping the previous grant around and using
        it again can invalidate the whole family.
        """
        if not self.refresh_token:
            raise AuthCodeError(
                AuthCodeErrorKind.NOT_REFRESHABLE,
                "grant has expired and carries no refresh_token — re-authorize",
            )

        form = {
            "grant_type": "refresh_token",
            "refresh_token": self.refresh_token,
            "client_id": self.client_id,
        }
        if self.resource:
            form["resource"] = self.resource

        token = await _post_form(http_client, self.token_endpoint, form)

        expires_in = token.get("expires_in")
        return Grant(
            access_token=token["access_token"],
            client_id=self.client_id,
            token_endpoint=self.token_endpoint,
            # A server that does not rotate returns no new refresh token; keep
            # the existing one rather than silently making the grant
            # unrefreshable from here on.
            refresh_token=token.get("refresh_token") or self.refresh_token,
            expires_at=None if expires_in is None else _now_secs() + int(expires_in),
            scope=token.get("scope") or self.scope,
            resource=self.resource,
        )


# ─── Pending authorization ───────────────────────────────────────────────────


@dataclass(frozen=True)
class PendingAuthorization:
    """The secrets held between building the consent URL and redeeming the code.

    Frozen so a verifier cannot be mutated between authorize and exchange.
    """

    code_verifier: str
    state: str
    redirect_uri: str


# ─── The flow ────────────────────────────────────────────────────────────────


class AuthCodeFlow:
    """Drives discovery, registration, consent, and exchange.

    Holds an :class:`httpx.AsyncClient`. If one is not supplied to
    :meth:`discover`, the flow creates and owns it; use the flow as an async
    context manager, or call :meth:`aclose`, so it is not left open.
    """

    def __init__(
        self,
        http_client: httpx.AsyncClient,
        metadata: AuthServerMetadata,
        resource: str,
        *,
        owns_client: bool = False,
    ) -> None:
        self._http = http_client
        self._owns_client = owns_client
        self._metadata = metadata
        self._resource = resource
        self._client_id: Optional[str] = None
        self._redirect_uri: Optional[str] = None
        self._scope = DEFAULT_SCOPE

    # ─── Lifecycle ────────────────────────────────────────────────────────────

    @classmethod
    async def discover(
        cls,
        resource_url: str,
        http_client: Optional[httpx.AsyncClient] = None,
    ) -> AuthCodeFlow:
        """Discover the authorization server protecting ``resource_url``.

        ``resource_url`` is the MCP endpoint being connected to — for DataGrout,
        ``https://gateway.datagrout.ai/connect`` or a ``.../servers/{uuid}/mcp``
        URL.

        Tries RFC 9728 protected-resource metadata first, then RFC 8414
        authorization-server metadata on whatever that names. Falls back to the
        resource's own origin, which is where DataGrout serves it.
        """
        resource = resource_url.rstrip("/")
        owns = http_client is None
        http = http_client or httpx.AsyncClient()

        try:
            prm = await _fetch_resource_metadata(http, resource)
            issuer: Optional[str] = None
            if prm and prm.get("authorization_servers"):
                issuer = prm["authorization_servers"][0]
            else:
                # No PRM, or it named no servers: DataGrout serves AS metadata
                # at the origin, so try there before giving up.
                issuer = origin_of(resource)

            if not issuer:
                raise AuthCodeError(AuthCodeErrorKind.DISCOVERY, f"not a URL: {resource}")

            metadata = await _fetch_as_metadata(http, issuer)
            if not metadata.supports_s256():
                raise AuthCodeError(
                    AuthCodeErrorKind.PKCE_UNSUPPORTED,
                    "authorization server does not support PKCE S256; " "refusing to downgrade",
                )
        except BaseException:
            # Do not leak a client we created when discovery fails.
            if owns:
                await http.aclose()
            raise

        return cls(http, metadata, resource, owns_client=owns)

    async def aclose(self) -> None:
        """Close the HTTP client, if this flow created it."""
        if self._owns_client:
            await self._http.aclose()

    async def __aenter__(self) -> AuthCodeFlow:
        return self

    async def __aexit__(self, *_exc: Any) -> None:
        await self.aclose()

    # ─── Configuration ────────────────────────────────────────────────────────

    def with_client_id(self, client_id: str, redirect_uri: str) -> AuthCodeFlow:
        """Use a client id registered out of band, skipping dynamic registration."""
        self._client_id = client_id
        self._redirect_uri = redirect_uri
        return self

    def with_registered_client(self, client: RegisteredClient) -> AuthCodeFlow:
        """Reuse a client registered on a previous run.

        Prefer this over :meth:`with_client_id`: it carries the redirect URI
        with the id, which is not optional bookkeeping — an authorization
        server matches the redirect URI *exactly* against what was registered,
        so a client id reused with a different URI is rejected.
        """
        return self.with_client_id(client.client_id, client.redirect_uri)

    def with_scope(self, scope: str) -> AuthCodeFlow:
        """Request scopes other than :data:`DEFAULT_SCOPE`."""
        self._scope = scope
        return self

    @property
    def metadata(self) -> AuthServerMetadata:
        """The discovered metadata."""
        return self._metadata

    @property
    def client_id(self) -> Optional[str]:
        """The client id, once registered or supplied."""
        return self._client_id

    @property
    def redirect_uri(self) -> Optional[str]:
        """The redirect URI this flow is bound to."""
        return self._redirect_uri

    # ─── Steps ────────────────────────────────────────────────────────────────

    async def register(self, client_name: str, redirect_uri: str) -> RegisteredClient:
        """Register this application via RFC 7591 dynamic client registration.

        Registers a **public client** — ``token_endpoint_auth_method: "none"``,
        no secret issued. A desktop or CLI application cannot keep a secret, and
        PKCE is what stands in for one.

        Returns the id **and** the redirect URI it is bound to. Persist the pair
        and restore it with :meth:`with_registered_client` — re-registering on
        every launch creates a new client record each time, and reusing an id
        against a different redirect URI is rejected.
        """
        endpoint = self._metadata.registration_endpoint
        if not endpoint:
            raise AuthCodeError(
                AuthCodeErrorKind.NO_REGISTRATION_ENDPOINT,
                "authorization server has no registration endpoint — register a "
                "client manually and use with_client_id()",
            )

        body = {
            "client_name": client_name,
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        }

        try:
            resp = await self._http.post(endpoint, json=body)
        except httpx.RequestError as exc:
            raise AuthCodeError(AuthCodeErrorKind.HTTP, f"HTTP error: {exc}") from exc

        if resp.status_code >= 400:
            raise AuthCodeError(
                AuthCodeErrorKind.REGISTRATION_REJECTED,
                f"client registration rejected (HTTP {resp.status_code}): {resp.text}",
                status=resp.status_code,
                body=resp.text,
            )

        try:
            client_id = resp.json()["client_id"]
        except (ValueError, KeyError) as exc:
            raise AuthCodeError(
                AuthCodeErrorKind.HTTP, f"bad registration response: {exc}"
            ) from exc

        self._client_id = client_id
        self._redirect_uri = redirect_uri
        return RegisteredClient(client_id=client_id, redirect_uri=redirect_uri)

    def authorize_url(self) -> Tuple[str, PendingAuthorization]:
        """Build the consent URL and the pending authorization to redeem it.

        The caller opens the URL however suits it — a browser, a printed
        instruction, a QR code. This SDK does not launch browsers.
        """
        if not self._client_id or not self._redirect_uri:
            raise AuthCodeError(
                AuthCodeErrorKind.NO_CLIENT_ID,
                "no client_id — call register() or with_client_id() first",
            )

        code_verifier = generate_verifier()
        state = _generate_state()

        params = [
            ("response_type", "code"),
            ("client_id", self._client_id),
            ("redirect_uri", self._redirect_uri),
            ("scope", self._scope),
            ("state", state),
            ("code_challenge", challenge_s256(code_verifier)),
            ("code_challenge_method", "S256"),
            # RFC 8707: bind the token to this resource so it cannot be replayed
            # against a different one.
            ("resource", self._resource),
        ]
        query = "&".join(f"{k}={_urlencode(v)}" for k, v in params)

        separator = "&" if "?" in self._metadata.authorization_endpoint else "?"
        url = f"{self._metadata.authorization_endpoint}{separator}{query}"

        return url, PendingAuthorization(
            code_verifier=code_verifier,
            state=state,
            redirect_uri=self._redirect_uri,
        )

    async def exchange(
        self,
        pending: PendingAuthorization,
        code: str,
        returned_state: str,
    ) -> Grant:
        """Redeem an authorization code for a :class:`Grant`.

        ``returned_state`` is the ``state`` parameter from the redirect. It is
        checked against the pending request *before anything is sent*: a
        mismatch means the response belongs to a different authorization
        request, and the exchange is refused rather than attempted.
        """
        if not hmac.compare_digest(pending.state, returned_state):
            raise AuthCodeError(
                AuthCodeErrorKind.STATE_MISMATCH,
                "state mismatch — the authorization response does not match " "this request",
            )

        if not self._client_id:
            raise AuthCodeError(
                AuthCodeErrorKind.NO_CLIENT_ID,
                "no client_id — call register() or with_client_id() first",
            )

        token = await _post_form(
            self._http,
            self._metadata.token_endpoint,
            {
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": pending.redirect_uri,
                "client_id": self._client_id,
                "code_verifier": pending.code_verifier,
                "resource": self._resource,
            },
        )

        expires_in = token.get("expires_in")
        return Grant(
            access_token=token["access_token"],
            client_id=self._client_id,
            token_endpoint=self._metadata.token_endpoint,
            refresh_token=token.get("refresh_token"),
            expires_at=None if expires_in is None else _now_secs() + int(expires_in),
            scope=token.get("scope"),
            resource=self._resource,
        )


# ─── Provider ────────────────────────────────────────────────────────────────


class AuthCodeProvider:
    """Holds a :class:`Grant` and keeps its access token fresh.

    Mirrors :class:`~datagrout.conduit.oauth.OAuthTokenProvider` so both grant
    types reach the transports through the same path — ``get_token`` on the way
    out, ``invalidate`` on a 401.
    """

    def __init__(self, grant: Grant) -> None:
        self._grant = grant
        self._dirty = False
        # Held only to hand off leadership of a refresh, never across the
        # request itself. The in-flight refresh is shared as a task so
        # concurrent callers await one round trip and one outcome.
        self._lock = asyncio.Lock()
        self._refresh: Optional["asyncio.Task[Grant]"] = None

    async def get_token(self, http_client: httpx.AsyncClient) -> str:
        """The current access token, refreshing first if it is at or near expiry.

        Concurrent callers that arrive while a refresh is in flight await that
        same refresh rather than starting their own, and share its outcome —
        including its failure. A dead token endpoint therefore costs one
        request, not one per waiter.
        """
        grant = self._grant
        if not grant.is_expired():
            return grant.access_token

        return (await self._refresh_once(http_client)).access_token

    async def _refresh_once(self, http_client: httpx.AsyncClient) -> Grant:
        async with self._lock:
            # Re-check: a refresh may have landed while we waited for the lock.
            if not self._grant.is_expired():
                return self._grant

            task = self._refresh
            if task is None or task.done():
                task = asyncio.create_task(self._grant.refresh(http_client))
                self._refresh = task

        # The lock is released before awaiting, so the state stays readable —
        # a persistence loop calling take_if_dirty() must not stall behind a
        # slow token endpoint. Shielded because a caller giving up must not
        # cancel the refresh every other waiter is depending on.
        refreshed = await asyncio.shield(task)

        async with self._lock:
            # Whichever waiter gets here first applies it; the rest find it
            # already applied and leave it alone.
            if self._refresh is task:
                self._grant = refreshed
                self._dirty = True
                self._refresh = None
                logger.debug("conduit: refreshed authorization-code grant")

        return refreshed

    def grant(self) -> Grant:
        """A snapshot of the current grant, for persisting."""
        return self._grant

    def is_dirty(self) -> bool:
        """Whether the grant changed since the last :meth:`take_if_dirty`."""
        return self._dirty

    def take_if_dirty(self) -> Optional[Grant]:
        """Return the grant if it changed since the last call, clearing the flag.

        The intended use is a persistence loop: call periodically and write
        whatever comes back, so a rotated refresh token is never lost.
        """
        if not self._dirty:
            return None
        self._dirty = False
        return self._grant

    def invalidate(self) -> None:
        """Force the next :meth:`get_token` to refresh. Call on a 401."""
        # Expire in the past rather than clearing the token: the refresh token
        # is what matters, and dropping the grant would make recovery
        # impossible.
        self._grant = Grant(
            access_token=self._grant.access_token,
            client_id=self._grant.client_id,
            token_endpoint=self._grant.token_endpoint,
            refresh_token=self._grant.refresh_token,
            expires_at=0,
            scope=self._grant.scope,
            resource=self._grant.resource,
        )


def provider_from_auth(value: Any) -> Optional[AuthCodeProvider]:
    """Coerce an ``authorization_code`` auth entry into a provider.

    A caller who passes a bare :class:`Grant` (or its dict form) gets one made
    for them; a caller who passes their own :class:`AuthCodeProvider` keeps it,
    so a rotated refresh token stays visible to them through
    :meth:`AuthCodeProvider.take_if_dirty`.
    """
    if value is None:
        return None
    if isinstance(value, AuthCodeProvider):
        return value
    if isinstance(value, Grant):
        return AuthCodeProvider(value)
    if isinstance(value, dict):
        return AuthCodeProvider(Grant.from_dict(value))
    raise AuthCodeError(
        AuthCodeErrorKind.NOT_REFRESHABLE,
        f"authorization_code must be a Grant, a provider, or a dict — got "
        f"{type(value).__name__}",
    )


# ─── PKCE and helpers ────────────────────────────────────────────────────────


def generate_verifier() -> str:
    """Generate an RFC 7636 code verifier: 43 characters of base64url."""
    return _b64url(secrets.token_bytes(32))


def challenge_s256(verifier: str) -> str:
    """The S256 challenge for a verifier: ``base64url(sha256(verifier))``."""
    return _b64url(hashlib.sha256(verifier.encode("utf-8")).digest())


def origin_of(url: str) -> Optional[str]:
    """Scheme, host and port of a URL, with no path."""
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.hostname:
        return None
    if parsed.port:
        return f"{parsed.scheme}://{parsed.hostname}:{parsed.port}"
    return f"{parsed.scheme}://{parsed.hostname}"


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _generate_state() -> str:
    return _b64url(secrets.token_bytes(16))


def _now_secs() -> int:
    """Unix seconds. Deliberately not ``time.monotonic`` — see the module docs."""
    return int(time.time())


def _urlencode(value: str) -> str:
    """Percent-encode a query parameter value.

    ``safe=""`` so ``/`` and ``:`` are escaped too: they appear in redirect URIs
    and resource URLs, and must not be taken as structure by the authorization
    server.
    """
    return quote(value, safe="")


async def _fetch_resource_metadata(
    http_client: httpx.AsyncClient, resource: str
) -> Optional[Dict[str, Any]]:
    """RFC 9728 protected-resource metadata, or ``None`` if unavailable."""
    origin = origin_of(resource)
    candidates = [f"{resource}/.well-known/oauth-protected-resource"]
    if origin:
        candidates.append(f"{origin}/.well-known/oauth-protected-resource")

    for url in candidates:
        try:
            resp = await http_client.get(url)
        except httpx.RequestError:
            continue
        if resp.status_code < 400:
            try:
                body = resp.json()
            except ValueError:
                continue
            # A non-object body is not metadata; fall through to the next
            # candidate rather than handing the caller something unusable.
            if isinstance(body, dict):
                return body
    return None


async def _fetch_as_metadata(http_client: httpx.AsyncClient, issuer: str) -> AuthServerMetadata:
    base = issuer.rstrip("/")
    candidates = [
        f"{base}/.well-known/oauth-authorization-server",
        f"{base}/.well-known/openid-configuration",
    ]

    last = ""
    for url in candidates:
        try:
            resp = await http_client.get(url)
        except httpx.RequestError as exc:
            last = f"{url} → {exc}"
            continue
        if resp.status_code < 400:
            try:
                return AuthServerMetadata.from_dict(resp.json())
            except ValueError as exc:
                raise AuthCodeError(
                    AuthCodeErrorKind.DISCOVERY,
                    f"OAuth discovery failed: bad metadata at {url}: {exc}",
                ) from exc
        last = f"{url} → HTTP {resp.status_code}"

    raise AuthCodeError(
        AuthCodeErrorKind.DISCOVERY,
        f"OAuth discovery failed: no authorization server metadata found "
        f"(last attempt: {last})",
    )


async def _post_form(
    http_client: httpx.AsyncClient, endpoint: str, form: Dict[str, str]
) -> Dict[str, Any]:
    try:
        resp = await http_client.post(endpoint, data=form)
    except httpx.RequestError as exc:
        raise AuthCodeError(AuthCodeErrorKind.HTTP, f"HTTP error: {exc}") from exc

    if resp.status_code >= 400:
        raise AuthCodeError(
            AuthCodeErrorKind.TOKEN_EXCHANGE,
            f"token exchange failed (HTTP {resp.status_code}): {resp.text}",
            status=resp.status_code,
            body=resp.text,
        )

    try:
        body = resp.json()
    except ValueError as exc:
        raise AuthCodeError(AuthCodeErrorKind.HTTP, f"bad token response: {exc}") from exc

    if not isinstance(body, dict):
        raise AuthCodeError(
            AuthCodeErrorKind.HTTP,
            f"bad token response: expected a JSON object, got {type(body).__name__}",
        )
    return body
