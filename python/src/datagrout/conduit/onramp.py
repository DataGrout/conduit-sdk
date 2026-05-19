"""Autonomous agent self-registration (onramp) for DataGrout.

The onramp flow lets a machine intelligence register itself with DG
without a human in the loop, using only plain HTTP JSON — no MCP client
required. This matters because many agent harnesses gate or restrict MCP
connections but allow arbitrary HTTP requests.

Flow
----
1. POST to ``/onramp`` with agent identity metadata (no auth).
2. DG returns a short-lived ``session_token`` (5 minutes).
3. POST to ``/onramp/complete`` with ``Authorization: Bearer <session_token>``.
4. DG issues provisional ``client_id`` + ``client_secret`` (restricted scopes).

The two-step handshake stops fire-and-forget scripts from bulk-registering
without completing the flow.

The credentials returned by :func:`register_only` can be passed directly to
:meth:`~datagrout.conduit.Client.bootstrap_identity_oauth` or the all-in-one
:meth:`~datagrout.conduit.Client.bootstrap_onramp`.

Example
-------
::

    from datagrout.conduit import Client
    from datagrout.conduit.onramp import OnrampOptions

    # One-shot convenience — full onramp + mTLS bootstrap in a single call.
    client = await Client.bootstrap_onramp(
        OnrampOptions(
            gateway="https://app.datagrout.ai",
            agent_name="my-research-agent",
            agent_type="claude-sonnet-4-6",
            intended_use="Summarise documents and extract entities.",
        )
    )
    await client.connect()
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

import httpx


@dataclass
class OnrampOptions:
    """Options for the autonomous agent onramp flow."""

    #: DataGrout gateway base URL (e.g. ``"https://app.datagrout.ai"``).
    gateway: str
    #: Human-readable name for this agent instance.
    agent_name: str
    #: Model or framework identifier (e.g. ``"claude-sonnet-4-6"``).
    agent_type: Optional[str] = None
    #: Plain-language description of what the agent intends to do.
    intended_use: Optional[str] = None
    #: Optional access code from the server owner — reserved for scope elevation.
    access_code: Optional[str] = None


@dataclass
class OnrampCredentials:
    """Provisional credentials returned by the DG onramp complete endpoint.

    Store ``client_id`` and ``client_secret`` securely — the secret is shown
    exactly once and cannot be recovered.

    ``mcp_url`` and ``rpc_url`` are provisioned as part of the identity
    registration step and may be absent from the initial onramp response.
    Use :meth:`~datagrout.conduit.Client.bootstrap_onramp` for the all-in-one
    flow that handles this transparently.
    """

    #: OAuth client ID.
    client_id: str
    #: OAuth client secret. Store this securely — shown once.
    client_secret: str
    #: Token endpoint for the ``client_credentials`` grant.
    token_url: str
    #: Granted OAuth scopes.
    scopes: List[str] = field(default_factory=list)
    #: Provisional credential TTL in seconds.
    expires_in: int = 0
    #: JSON-RPC endpoint. Absent until identity is registered.
    rpc_url: Optional[str] = None
    #: MCP endpoint. Absent until identity is registered.
    mcp_url: Optional[str] = None


class OnrampError(Exception):
    """Errors from the onramp flow."""


# ---------------------------------------------------------------------------
# Internal helpers (also used by Client.bootstrap_onramp)
# ---------------------------------------------------------------------------


async def _register(http: httpx.AsyncClient, opts: OnrampOptions) -> OnrampCredentials:
    base = opts.gateway.rstrip("/")

    body: dict = {"agent_name": opts.agent_name}
    if opts.agent_type is not None:
        body["agent_type"] = opts.agent_type
    if opts.intended_use is not None:
        body["intended_use"] = opts.intended_use
    if opts.access_code is not None:
        body["access_code"] = opts.access_code

    resp = await http.post(f"{base}/onramp", json=body)
    if not resp.is_success:
        raise OnrampError(f"onramp init rejected (HTTP {resp.status_code}): {resp.text}")

    session_token = resp.json()["session_token"]

    resp = await http.post(
        f"{base}/onramp/complete",
        headers={"Authorization": f"Bearer {session_token}"},
    )
    if not resp.is_success:
        raise OnrampError(f"onramp complete rejected (HTTP {resp.status_code}): {resp.text}")

    data = resp.json()
    return OnrampCredentials(
        client_id=data["client_id"],
        client_secret=data["client_secret"],
        token_url=data["token_url"],
        scopes=data.get("scopes", []),
        expires_in=data.get("expires_in", 0),
        rpc_url=data.get("rpc_url"),
        mcp_url=data.get("mcp_url"),
    )


async def _exchange_token(http: httpx.AsyncClient, creds: OnrampCredentials) -> str:
    resp = await http.post(
        creds.token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": creds.client_id,
            "client_secret": creds.client_secret,
        },
    )
    if not resp.is_success:
        raise OnrampError(f"token exchange failed (HTTP {resp.status_code}): {resp.text}")
    return resp.json()["access_token"]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def register_only(opts: OnrampOptions) -> OnrampCredentials:
    """Perform the onramp handshake and return provisional OAuth credentials.

    This is the low-level entry point. Most callers should use
    :meth:`~datagrout.conduit.Client.bootstrap_onramp` instead, which chains
    onramp → token exchange → mTLS identity bootstrap in a single call.

    Args:
        opts: Onramp registration options.

    Returns:
        :class:`OnrampCredentials` containing ``client_id`` and ``client_secret``.
    """
    async with httpx.AsyncClient() as http:
        return await _register(http, opts)


async def register_and_exchange(opts: OnrampOptions) -> Tuple[OnrampCredentials, str]:
    """Perform the full onramp handshake and OAuth token exchange.

    Returns the provisional credentials alongside a short-lived access token
    ready for use with
    :meth:`~datagrout.conduit.Client.bootstrap_identity`.

    Args:
        opts: Onramp registration options.

    Returns:
        Tuple of ``(OnrampCredentials, access_token_string)``.
    """
    async with httpx.AsyncClient() as http:
        creds = await _register(http, opts)
        token = await _exchange_token(http, creds)
        return creds, token
