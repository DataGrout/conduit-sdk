"""RFC 8693 **delegation** — an agent acting *for* a user.

The two grants this package already speaks each answer one question.
:mod:`datagrout.conduit.oauth` (``client_credentials``) says *which machine* is
calling; :mod:`datagrout.conduit.authcode` says *which person* consented.
Neither says both, and an agent working on a user's behalf needs to: the
resource server has to know whose data it is (``sub``) and who is actually
holding the connection (``act``). An RFC 8693 exchange produces exactly that
token, from two the caller already has.

Delegation, not impersonation
-----------------------------
RFC 8693 distinguishes the two. In **delegation** the issued token names the
user as ``sub`` and the agent in an ``act`` claim, so the resource server can
see — and audit, and rate-limit, and revoke — the agent separately from the
user. In **impersonation** the agent simply *becomes* the user, and the
resource server cannot tell the difference. DataGrout's authorization server
issues delegation tokens and requires an ``actor_token``; this module therefore
**requires an actor by default** and refuses to build a request without one.
Impersonation is an explicit opt-in via ``impersonation=True``, for RFC 8693
servers that support it.

Wire contract
-------------
``POST {token_endpoint}``, form-encoded, in this order:

===============================================  ==========================================
field                                            value
===============================================  ==========================================
``grant_type``                                   :data:`GRANT_TYPE`
``subject_token``, ``subject_token_type``        the user's token and its :class:`TokenType`
``actor_token``, ``actor_token_type``            the agent's token and URN — omitted only
                                                 under ``impersonation=True``
``client_id``, ``client_secret?``                client authentication, in the body by
                                                 default (see :class:`ClientAuth`)
``audience?``, ``resource?``, ``scope?``,        as set
``requested_token_type?``
===============================================  ==========================================

``resource`` is RFC 8707 and, when set, is always sent — the same invariant the
authorization-code module keeps, so a delegated token cannot be replayed
against a different resource.

**The client must be the actor.** The ``client_id`` authenticating the request
and the principal behind ``actor_token`` are expected to be the same agent.
This SDK does not verify that — it cannot, without decoding the actor token —
and the server enforces it (``unauthorized_client`` when they differ).

The response is ``{access_token, issued_token_type, token_type, expires_in?,
scope?}``; errors are RFC 6749 bodies ``{error, error_description?}``, with the
codes in :class:`ServerErrorCode`.

Example::

    from datagrout.conduit import (
        Client,
        DelegatedProvider,
        DelegationRequest,
        OAuthTokenProvider,
        TokenSource,
    )

    # The agent's own credential — the actor.
    agent = OAuthTokenProvider(
        client_id="agent_client_id",
        client_secret="agent_client_secret",
        token_endpoint="https://gateway.datagrout.ai/oauth/token",
    )

    # The user's token — the subject. Here one handed to the agent for this
    # run; a long-lived app would use TokenSource.authorization_code(provider).
    user = TokenSource.static_token(user_token)

    provider = DelegatedProvider(
        DelegationRequest(
            token_endpoint="https://gateway.datagrout.ai/oauth/token",
            client_id="agent_client_id",
            client_secret="agent_client_secret",
            resource="https://gateway.datagrout.ai/connect",
        ),
        subject=user,
        actor=TokenSource.client_credentials(agent),
    )

    client = Client(
        url="https://gateway.datagrout.ai/connect",
        auth={"delegation": provider},
    )
    await client.connect()

Naming
------
Elsewhere in this package "token exchange" already means redeeming a
``client_credentials`` grant (:attr:`AuthCodeErrorKind.TOKEN_EXCHANGE
<datagrout.conduit.authcode.AuthCodeErrorKind.TOKEN_EXCHANGE>`, the onramp's
``token_exchange`` stage). This module says *delegation* and *exchange* —
:meth:`DelegationRequest.exchange`, :class:`DelegatedToken` — and never reuses
that label, so a log line cannot be read two ways.

:attr:`DelegatedToken.expires_at` is Unix **seconds**, computed from the
server's relative ``expires_in`` at receipt — never a monotonic reading, so the
token means the same thing once written down.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import time
from dataclasses import dataclass, field, replace
from enum import Enum
from typing import (
    Any,
    Awaitable,
    Callable,
    ClassVar,
    Dict,
    List,
    Optional,
    Protocol,
    Tuple,
)

import httpx

from .errors import ConduitError, InvalidConfigError

logger = logging.getLogger(__name__)

#: The RFC 8693 grant type.
GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"

#: Re-exchange this many seconds before the delegated token actually expires.
#:
#: The same buffer :mod:`~datagrout.conduit.oauth` and
#: :mod:`~datagrout.conduit.authcode` use, so all three providers behave alike
#: under a clock skew.
_REFRESH_SKEW_SECS = 60

#: How much of an off-contract error body is quoted back in the message.
_BODY_EXCERPT_CHARS = 200


class ServerErrorCode(str, Enum):
    """RFC 6749 error codes a token-exchange endpoint returns.

    Named so callers and ports compare against a symbol rather than a string
    they typed. ``INVALID_TARGET`` is the one specific to RFC 8693: the
    ``audience`` or ``resource`` is not one this server issues tokens for.

    A server is free to return a code outside this set;
    :attr:`DelegationError.error` therefore stays a plain string.
    """

    #: Malformed request, or a required parameter missing.
    INVALID_REQUEST = "invalid_request"
    #: Client authentication failed.
    INVALID_CLIENT = "invalid_client"
    #: The subject or actor token is invalid, expired, or revoked.
    INVALID_GRANT = "invalid_grant"
    #: This client may not use this grant — including a client that is not the actor.
    UNAUTHORIZED_CLIENT = "unauthorized_client"
    #: The requested ``audience`` or ``resource`` is not served here (RFC 8693 §2.2.2).
    INVALID_TARGET = "invalid_target"
    #: A requested scope is unknown or exceeds what the subject token allows.
    INVALID_SCOPE = "invalid_scope"
    #: The server does not support token exchange.
    UNSUPPORTED_GRANT_TYPE = "unsupported_grant_type"


#: Every code in :class:`ServerErrorCode`, frozen, for the contract test.
SERVER_ERROR_CODES: frozenset[str] = frozenset(code.value for code in ServerErrorCode)


# ─── Token types ─────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class TokenType:
    """An RFC 8693 §3 token type identifier, carried as its URN.

    A thin frozen wrapper rather than an :class:`~enum.Enum` because the
    vocabulary is open: a URN this SDK does not name has to round-trip rather
    than fail, and an ``Enum`` cannot hold an unknown member. The five URNs the
    RFC names are class constants::

        TokenType.ACCESS_TOKEN
        TokenType.JWT
        TokenType.ID_TOKEN
        TokenType.REFRESH_TOKEN
        TokenType.SAML2
        TokenType.from_urn("urn:example:custom")  # anything else

    Frozen, so it is hashable and compares by URN — the same string in every
    language SDK.
    """

    urn: str

    ACCESS_TOKEN: ClassVar["TokenType"]
    JWT: ClassVar["TokenType"]
    ID_TOKEN: ClassVar["TokenType"]
    REFRESH_TOKEN: ClassVar["TokenType"]
    SAML2: ClassVar["TokenType"]

    def as_urn(self) -> str:
        """The URN sent on the wire."""
        return self.urn

    @classmethod
    def from_urn(cls, urn: str) -> "TokenType":
        """Read a URN. Anything unrecognised is kept verbatim."""
        return cls(urn)

    def __str__(self) -> str:
        return self.urn


TokenType.ACCESS_TOKEN = TokenType("urn:ietf:params:oauth:token-type:access_token")
TokenType.JWT = TokenType("urn:ietf:params:oauth:token-type:jwt")
TokenType.ID_TOKEN = TokenType("urn:ietf:params:oauth:token-type:id_token")
TokenType.REFRESH_TOKEN = TokenType("urn:ietf:params:oauth:token-type:refresh_token")
TokenType.SAML2 = TokenType("urn:ietf:params:oauth:token-type:saml2")


# ─── Errors ──────────────────────────────────────────────────────────────────


class DelegationErrorKind(str, Enum):
    """The distinguishable failures of an exchange.

    The taxonomy is part of the cross-language contract: every conduit SDK
    distinguishes these same cases under the same names, so callers can branch
    identically.
    """

    #: No subject token was set — there is nobody to act for.
    MISSING_SUBJECT = "missing_subject"
    #: No actor token was set and the request is not an impersonation.
    MISSING_ACTOR = "missing_actor"
    #: Transport failure talking to the token endpoint.
    HTTP = "http"
    #: The token endpoint refused, with an RFC 6749 error body.
    SERVER = "server"
    #: The endpoint answered with something that is not a token-exchange
    #: response — a success body missing required fields, or a failure whose
    #: body is not an RFC 6749 error.
    INVALID_RESPONSE = "invalid_response"


class DelegationError(ConduitError):
    """An error from an exchange, tagged with its :class:`DelegationErrorKind`."""

    def __init__(
        self,
        kind: DelegationErrorKind,
        message: str,
        *,
        status: Optional[int] = None,
        error: Optional[str] = None,
        error_description: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.kind = kind
        #: HTTP status, for ``SERVER`` and ``INVALID_RESPONSE``.
        self.status = status
        #: RFC 6749 error code, for ``SERVER``. See :class:`ServerErrorCode`.
        self.error = error
        #: Human-readable description, when the server gave one.
        self.error_description = error_description

    @classmethod
    def missing_subject(cls) -> "DelegationError":
        return cls(
            DelegationErrorKind.MISSING_SUBJECT,
            "no subject_token — set one on the request before exchanging",
        )

    @classmethod
    def missing_actor(cls) -> "DelegationError":
        return cls(
            DelegationErrorKind.MISSING_ACTOR,
            "no actor_token — delegation requires one; pass impersonation=True "
            "to opt out explicitly",
        )


# ─── Request ─────────────────────────────────────────────────────────────────


class ClientAuth(str, Enum):
    """How the client authenticates to the token endpoint."""

    #: ``client_id`` and ``client_secret`` as form fields (RFC 6749 §2.3.1
    #: ``client_secret_post``). The default, and what DataGrout expects.
    BODY = "body"
    #: ``Authorization: Basic base64(client_id:client_secret)``
    #: (``client_secret_basic``). ``client_id`` is still sent in the body, as
    #: RFC 6749 permits and some servers require.
    BASIC = "basic"


@dataclass(repr=False)
class DelegationRequest:
    """A token-exchange request, filled in and then :meth:`exchange`d.

    Copyable, so a :class:`DelegatedProvider` can hold one as a template and
    fill in fresh subject and actor tokens on each re-exchange — see
    :meth:`with_subject` and :meth:`with_actor`.

    The client should be the actor; see the module docs.
    """

    token_endpoint: str
    client_id: str
    client_secret: Optional[str] = None
    #: Where the client secret travels. Defaults to :attr:`ClientAuth.BODY`.
    client_auth: ClientAuth = ClientAuth.BODY
    #: The token being exchanged: the **user's**, whose identity the issued
    #: token will carry as ``sub``.
    subject_token: Optional[str] = None
    subject_token_type: TokenType = field(default_factory=lambda: TokenType.ACCESS_TOKEN)
    #: The **agent's** own token, which the issued token will name in ``act``.
    actor_token: Optional[str] = None
    actor_token_type: TokenType = field(default_factory=lambda: TokenType.ACCESS_TOKEN)
    #: Logical name of the service the token is for (RFC 8693 ``audience``).
    audience: Optional[str] = None
    #: URI of the resource the token is for (RFC 8707). Always sent when set,
    #: so the token cannot be replayed elsewhere.
    resource: Optional[str] = None
    #: Scopes to request, space-separated.
    scope: Optional[str] = None
    #: The kind of token wanted back. Servers default to an access token.
    requested_token_type: Optional[TokenType] = None
    #: Opt out of delegation: send no ``actor_token``, so the issued token has
    #: no ``act`` claim and the agent is indistinguishable from the user.
    #:
    #: DataGrout does not issue these. This exists for other RFC 8693 servers,
    #: and it is opt-in precisely so that forgetting to set an actor is an
    #: error instead of a silent downgrade.
    impersonation: bool = False

    def with_subject(
        self, token: str, token_type: Optional[TokenType] = None
    ) -> "DelegationRequest":
        """A copy carrying this subject token."""
        return replace(
            self,
            subject_token=token,
            subject_token_type=token_type or self.subject_token_type,
        )

    def with_actor(self, token: str, token_type: Optional[TokenType] = None) -> "DelegationRequest":
        """A copy carrying this actor token."""
        return replace(
            self,
            actor_token=token,
            actor_token_type=token_type or self.actor_token_type,
        )

    def form_params(self) -> List[Tuple[str, str]]:
        """The form body this request will post, in wire order.

        Raises before any network activity when the request is incomplete:
        :attr:`DelegationErrorKind.MISSING_SUBJECT`, or
        :attr:`DelegationErrorKind.MISSING_ACTOR` unless ``impersonation`` is
        set. Public so a caller — or another SDK's test suite — can check the
        body against the contract fixture without a server.
        """
        if not self.subject_token:
            raise DelegationError.missing_subject()

        form: List[Tuple[str, str]] = [
            ("grant_type", GRANT_TYPE),
            ("subject_token", self.subject_token),
            ("subject_token_type", self.subject_token_type.as_urn()),
        ]

        if self.actor_token:
            form.append(("actor_token", self.actor_token))
            form.append(("actor_token_type", self.actor_token_type.as_urn()))
        elif not self.impersonation:
            raise DelegationError.missing_actor()

        form.append(("client_id", self.client_id))
        if self.client_secret and self.client_auth is ClientAuth.BODY:
            form.append(("client_secret", self.client_secret))

        for key, value in (
            ("audience", self.audience),
            ("resource", self.resource),
            ("scope", self.scope),
        ):
            if value:
                form.append((key, value))
        if self.requested_token_type is not None:
            form.append(("requested_token_type", self.requested_token_type.as_urn()))

        return form

    async def exchange(self, http_client: httpx.AsyncClient) -> "DelegatedToken":
        """Perform the exchange.

        The form body is built first, so an incomplete request fails without
        touching the network.
        """
        form = self.form_params()

        headers: Dict[str, str] = {}
        if self.client_secret and self.client_auth is ClientAuth.BASIC:
            credentials = base64.b64encode(
                f"{self.client_id}:{self.client_secret}".encode()
            ).decode()
            headers["Authorization"] = f"Basic {credentials}"

        # httpx form-encodes a mapping, and a dict preserves insertion order,
        # so the body goes out in exactly the order form_params() returned.
        # (No field repeats, so nothing is lost by the conversion.)
        try:
            response = await http_client.post(self.token_endpoint, data=dict(form), headers=headers)
        except httpx.HTTPError as exc:
            raise DelegationError(DelegationErrorKind.HTTP, f"HTTP error: {exc}") from exc

        status = response.status_code
        body = response.text

        if status < 200 or status >= 300:
            raise _error_from_body(status, body)

        try:
            payload = json.loads(body)
            if not isinstance(payload, dict):
                raise ValueError("body is not a JSON object")
        except (json.JSONDecodeError, ValueError) as exc:
            raise DelegationError(
                DelegationErrorKind.INVALID_RESPONSE,
                f"invalid token exchange response: HTTP {status}: {exc}",
                status=status,
            ) from exc

        token = DelegatedToken.from_wire(payload, status=status)
        logger.debug(
            "conduit: exchanged for a delegated token (client_id=%s issued=%s expires_at=%s)",
            self.client_id,
            token.issued_token_type.as_urn(),
            token.expires_at,
        )
        return token

    def __repr__(self) -> str:
        # Never print the client secret or either token.
        return (
            f"DelegationRequest(token_endpoint={self.token_endpoint!r}, "
            f"client_id={self.client_id!r}, client_auth={self.client_auth.value!r}, "
            f"audience={self.audience!r}, resource={self.resource!r}, "
            f"scope={self.scope!r}, impersonation={self.impersonation!r})"
        )


def _error_from_body(status: int, body: str) -> DelegationError:
    """Classify a non-2xx body.

    A non-2xx body is an RFC 6749 error when it carries ``error``; anything
    else — a proxy's HTML, an empty body — is an invalid response, since it did
    not come from the token endpoint's contract.
    """
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        parsed = None

    if isinstance(parsed, dict) and isinstance(parsed.get("error"), str):
        code = parsed["error"]
        description = parsed.get("error_description")
        if not isinstance(description, str):
            description = None
        detail = f" — {description}" if description else ""
        return DelegationError(
            DelegationErrorKind.SERVER,
            f"token exchange refused (HTTP {status}): {code}{detail}",
            status=status,
            error=code,
            error_description=description,
        )

    excerpt = body[:_BODY_EXCERPT_CHARS]
    return DelegationError(
        DelegationErrorKind.INVALID_RESPONSE,
        f"invalid token exchange response: HTTP {status} with a non-OAuth body: {excerpt}",
        status=status,
    )


# ─── Token ───────────────────────────────────────────────────────────────────


@dataclass
class DelegatedToken:
    """A token issued by an exchange.

    The serialized shape is part of the cross-language contract, and is what
    ``testdata/contract.json`` pins: ``access_token``, ``issued_token_type`` (a
    URN string), ``token_type``, ``expires_at?``, ``scope?``. As with
    :class:`~datagrout.conduit.authcode.Grant`, ``expires_at`` is Unix
    **seconds** — computed from the server's relative ``expires_in`` at receipt
    — never a monotonic instant.
    """

    #: The bearer token to present.
    access_token: str
    #: What kind of token was issued.
    issued_token_type: TokenType
    #: How to present it — ``Bearer``, in practice.
    token_type: str
    #: Absolute expiry, Unix seconds. ``None`` means the server did not say.
    expires_at: Optional[int] = None
    #: Granted scopes, when the server reported them.
    scope: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """The JSON form, omitting absent optionals.

        Omission rather than ``null`` keeps the document identical to what the
        other SDKs write, so a token round-trips between languages.
        """
        data: Dict[str, Any] = {
            "access_token": self.access_token,
            "issued_token_type": self.issued_token_type.as_urn(),
            "token_type": self.token_type,
        }
        if self.expires_at is not None:
            data["expires_at"] = self.expires_at
        if self.scope is not None:
            data["scope"] = self.scope
        return data

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "DelegatedToken":
        """Read a token written by any conduit SDK."""
        return cls(
            access_token=data["access_token"],
            issued_token_type=TokenType.from_urn(data["issued_token_type"]),
            token_type=data["token_type"],
            expires_at=None if data.get("expires_at") is None else int(data["expires_at"]),
            scope=data.get("scope"),
        )

    @classmethod
    def from_wire(cls, payload: Dict[str, Any], *, status: int = 200) -> "DelegatedToken":
        """Read an RFC 8693 §2.2.1 success body, converting ``expires_in``.

        ``access_token``, ``issued_token_type`` and ``token_type`` are all
        REQUIRED by the RFC; a server that drops one is out of contract, and
        guessing would hide that.
        """
        for required in ("access_token", "issued_token_type", "token_type"):
            if not isinstance(payload.get(required), str):
                raise DelegationError(
                    DelegationErrorKind.INVALID_RESPONSE,
                    f"invalid token exchange response: HTTP {status}: "
                    f"missing required field {required!r}",
                    status=status,
                )

        expires_in = payload.get("expires_in")
        return cls(
            access_token=payload["access_token"],
            issued_token_type=TokenType.from_urn(payload["issued_token_type"]),
            token_type=payload["token_type"],
            expires_at=None if expires_in is None else _now_secs() + int(expires_in),
            scope=payload.get("scope"),
        )

    def is_expired(self) -> bool:
        """True when the token is expired, or within the refresh skew of it.

        A token with no stated expiry is treated as live: the server chose not
        to say, and guessing would throw away working tokens.
        """
        if self.expires_at is None:
            return False
        return _now_secs() + _REFRESH_SKEW_SECS >= self.expires_at


# ─── Token sources ───────────────────────────────────────────────────────────


class UpstreamProvider(Protocol):
    """What a provider-backed :class:`TokenSource` needs from a provider.

    Both :class:`~datagrout.conduit.oauth.OAuthTokenProvider` and
    :class:`~datagrout.conduit.authcode.AuthCodeProvider` satisfy it
    structurally, and so does anything else that keeps a bearer fresh.
    """

    async def get_token(self, http_client: httpx.AsyncClient) -> str: ...


class TokenSourceKind(str, Enum):
    """Where a :class:`TokenSource` gets its token."""

    STATIC = "static"
    CLIENT_CREDENTIALS = "client_credentials"
    AUTHORIZATION_CODE = "authorization_code"
    DYNAMIC = "dynamic"


class TokenSource:
    """Where a :class:`DelegatedProvider` gets a subject or actor token, and
    what :class:`TokenType` to declare it as.

    A source is consulted on **every** exchange, so a provider-backed source
    hands over a *fresh* token each time — the whole point of wrapping a
    provider rather than copying its current token out.

    Build one with :meth:`static_token`, :meth:`client_credentials`,
    :meth:`authorization_code` or :meth:`dynamic`.
    """

    def __init__(
        self,
        kind: TokenSourceKind,
        token_type: TokenType,
        *,
        token: Optional[str] = None,
        provider: Optional[UpstreamProvider] = None,
        fetch: Optional[Callable[[], Awaitable[str]]] = None,
    ) -> None:
        self._kind = kind
        self._token_type = token_type
        self._token = token
        self._provider = provider
        self._fetch = fetch

    # ─── Constructors ─────────────────────────────────────────────────────────

    @classmethod
    def static_token(cls, token: str, token_type: Optional[TokenType] = None) -> "TokenSource":
        """A fixed token, e.g. one handed to the agent for this run."""
        return cls(
            TokenSourceKind.STATIC,
            token_type or TokenType.ACCESS_TOKEN,
            token=token,
        )

    @classmethod
    def client_credentials(
        cls, provider: UpstreamProvider, token_type: Optional[TokenType] = None
    ) -> "TokenSource":
        """The agent's own :class:`~datagrout.conduit.oauth.OAuthTokenProvider`
        — the usual **actor**."""
        return cls(
            TokenSourceKind.CLIENT_CREDENTIALS,
            token_type or TokenType.ACCESS_TOKEN,
            provider=provider,
        )

    @classmethod
    def authorization_code(
        cls, provider: UpstreamProvider, token_type: Optional[TokenType] = None
    ) -> "TokenSource":
        """A user's :class:`~datagrout.conduit.authcode.AuthCodeProvider` — the
        usual **subject** in an app that signed the user in itself.

        Refreshes its grant as needed, so the exchange always sees a live
        subject token.
        """
        return cls(
            TokenSourceKind.AUTHORIZATION_CODE,
            token_type or TokenType.ACCESS_TOKEN,
            provider=provider,
        )

    @classmethod
    def dynamic(
        cls,
        fetch: Callable[[], Awaitable[str]],
        token_type: Optional[TokenType] = None,
    ) -> "TokenSource":
        """Any async callable that yields a token — a vault lookup, a header
        from an inbound request, another SDK's provider."""
        return cls(
            TokenSourceKind.DYNAMIC,
            token_type or TokenType.ACCESS_TOKEN,
            fetch=fetch,
        )

    # ─── Accessors ────────────────────────────────────────────────────────────

    def with_token_type(self, token_type: TokenType) -> "TokenSource":
        """A copy declaring a different :class:`TokenType`."""
        return TokenSource(
            self._kind,
            token_type,
            token=self._token,
            provider=self._provider,
            fetch=self._fetch,
        )

    @property
    def kind(self) -> TokenSourceKind:
        """Which flavour of source this is."""
        return self._kind

    @property
    def token_type(self) -> TokenType:
        """The declared token type."""
        return self._token_type

    async def resolve(self, http_client: httpx.AsyncClient) -> str:
        """The current token from this source."""
        if self._kind is TokenSourceKind.STATIC:
            assert self._token is not None
            return self._token
        if self._kind is TokenSourceKind.DYNAMIC:
            assert self._fetch is not None
            return await self._fetch()
        assert self._provider is not None
        return await self._provider.get_token(http_client)

    def __repr__(self) -> str:
        # Never print tokens.
        return f"TokenSource(kind={self._kind.value!r}, token_type={self._token_type.urn!r})"


# ─── Provider ────────────────────────────────────────────────────────────────


class DelegatedProvider:
    """Keeps a delegated token fresh, re-exchanging when it nears expiry.

    The third token provider in this package, shaped like the other two —
    :class:`~datagrout.conduit.oauth.OAuthTokenProvider` and
    :class:`~datagrout.conduit.authcode.AuthCodeProvider` — so every transport
    reaches it through the same path: ``get_token`` on the way out,
    ``invalidate`` on a 401. Each exchange pulls a fresh subject and actor
    token from its :class:`TokenSource`\\ s, so an expiring upstream credential
    is handled by the provider that owns it.

    Args:
        request: The request template. Any ``subject_token`` or ``actor_token``
            already on it is ignored; the sources supply them.
        subject: Where the user's token comes from.
        actor: Where the agent's own token comes from. ``None`` only with a
            request that set ``impersonation=True`` — otherwise every
            ``get_token`` fails with ``missing_actor``, which is the intended
            loud failure rather than a silent downgrade.
    """

    def __init__(
        self,
        request: DelegationRequest,
        subject: TokenSource,
        actor: Optional[TokenSource] = None,
    ) -> None:
        self._request = request
        self._subject = subject
        self._actor = actor
        self._cached: Optional[DelegatedToken] = None
        # Serializes exchanges so concurrent callers make one request rather
        # than a stampede. Waiters re-check the cache on entry, so a leader
        # that succeeded spares them the request entirely.
        self._lock = asyncio.Lock()

    async def get_token(self, http_client: httpx.AsyncClient) -> str:
        """The current delegated bearer, exchanging first if there is none or
        it is at or near expiry."""
        cached = self._cached
        if cached is not None and not cached.is_expired():
            return cached.access_token

        async with self._lock:
            # Re-check: an exchange may have landed while we waited.
            cached = self._cached
            if cached is not None and not cached.is_expired():
                return cached.access_token

            token = await self._exchange(http_client)
            self._cached = token
            return token.access_token

    def invalidate(self) -> None:
        """Force the next :meth:`get_token` to exchange again. Call on a 401.

        Only the delegated token is dropped. The subject and actor sources are
        left alone: a provider-backed source tracks its own expiry, and a 401
        from the resource server says nothing about them.
        """
        self._cached = None

    def token(self) -> Optional[DelegatedToken]:
        """A snapshot of the cached token, if any — for inspection or logging."""
        return self._cached

    @property
    def request(self) -> DelegationRequest:
        """The request template, without tokens."""
        return self._request

    @property
    def subject(self) -> TokenSource:
        return self._subject

    @property
    def actor(self) -> Optional[TokenSource]:
        return self._actor

    async def _exchange(self, http_client: httpx.AsyncClient) -> DelegatedToken:
        # Refuse before resolving anything: a missing actor is a configuration
        # mistake, and fetching a subject token first would only hide it.
        if self._actor is None and not self._request.impersonation:
            raise DelegationError.missing_actor()

        request = self._request.with_subject(
            await self._subject.resolve(http_client), self._subject.token_type
        )
        if self._actor is not None:
            request = request.with_actor(
                await self._actor.resolve(http_client), self._actor.token_type
            )

        return await request.exchange(http_client)

    def __repr__(self) -> str:
        # Never print tokens — and the request template carries the client
        # secret, so it is rendered by its own redacting repr.
        return (
            f"DelegatedProvider(token_endpoint={self._request.token_endpoint!r}, "
            f"client_id={self._request.client_id!r}, subject={self._subject!r}, "
            f"actor={self._actor!r})"
        )


def provider_from_auth(value: Any) -> Optional[DelegatedProvider]:
    """Coerce a ``delegation`` auth entry into a provider.

    Unlike the authorization-code entry there is no serialized form to accept:
    a delegation is a live pair of token sources, not a document, so the caller
    always builds the provider.
    """
    if value is None:
        return None
    if isinstance(value, DelegatedProvider):
        return value
    raise InvalidConfigError(
        f"auth['delegation'] must be a DelegatedProvider — got {type(value).__name__}"
    )


def _now_secs() -> int:
    """Unix seconds. Deliberately not ``time.monotonic`` — see the module docs."""
    return int(time.time())
