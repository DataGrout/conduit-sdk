"""Browser-consent sign-in with OAuth 2.1 authorization code + PKCE.

Run once and it opens a consent page, captures the redirect on 127.0.0.1, and
writes the grant to disk. Run again and it reuses what it saved.

    python examples/browser_signin.py

Two things this example exists to demonstrate, both of which are easy to get
wrong and only fail later:

 1. The registered client id is persisted **with its redirect URI**, and the
    listener re-binds that exact port on the next run. Authorization servers
    match redirect URIs exactly, with no loopback-port exemption.
 2. DataGrout rotates refresh tokens, so a refreshed grant is written back. A
    grant that is refreshed and not persisted leaves a consumed token on disk,
    and the next run fails with ``invalid_grant``.
"""

import asyncio
import json
import os
from pathlib import Path
from typing import Optional, Tuple

from datagrout.conduit import (
    AuthCodeFlow,
    AuthCodeProvider,
    Client,
    Grant,
    LoopbackListener,
    RegisteredClient,
)

GATEWAY = "https://gateway.datagrout.ai/connect"

# Where this example keeps its credentials.
#
# A file, and deliberately called out as such: it holds a refresh token, which
# is a long-lived credential. A real application should prefer the OS keychain.
# The SDK does not choose for you.
STORE = Path.home() / ".config" / "conduit-example" / "signin.json"


def load() -> Optional[Tuple[RegisteredClient, Grant]]:
    try:
        saved = json.loads(STORE.read_text())
    except (OSError, ValueError):
        return None
    return (
        RegisteredClient.from_dict(saved["registered"]),
        Grant.from_dict(saved["grant"]),
    )


def save(registered: RegisteredClient, grant: Grant) -> None:
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(
        json.dumps({"registered": registered.to_dict(), "grant": grant.to_dict()}, indent=2)
    )
    os.chmod(STORE, 0o600)


async def sign_in(
    existing: Optional[RegisteredClient] = None,
) -> Tuple[RegisteredClient, Grant]:
    """Run the full consent flow and return something worth persisting."""
    # Bind first: the real port has to be known before the redirect URI is
    # registered. Reusing a saved registration means re-binding its exact port.
    if existing is not None:
        try:
            listener = await LoopbackListener.bind_for(existing.redirect_uri)
        except Exception:
            print(f"port for {existing.redirect_uri} is taken — registering a fresh client")
            listener = await LoopbackListener.bind()
    else:
        listener = await LoopbackListener.bind()

    async with await AuthCodeFlow.discover(GATEWAY) as flow:
        # A saved registration is only reusable if the listener came back on
        # its port; otherwise register anew rather than authorize against a URI
        # the server will reject.
        if existing is not None and listener.redirect_uri == existing.redirect_uri:
            flow.with_registered_client(existing)
            registered = existing
        else:
            registered = await flow.register("Conduit Example", listener.redirect_uri)

        url, pending = flow.authorize_url()
        print(f"\nOpen this URL to sign in:\n\n  {url}\n")

        redirect = await listener.wait(timeout=300)
        grant = await flow.exchange(pending, redirect.code, redirect.state)

    return registered, grant


async def main() -> None:
    saved = load()

    if saved is not None:
        print("using the saved sign-in")
        registered, grant = saved
    else:
        registered, grant = await sign_in()
        save(registered, grant)
        print(f"signed in; credentials written to {STORE}")

    # Own the provider so a rotated refresh token can be written back.
    provider = AuthCodeProvider(grant)

    client = Client(url=GATEWAY, auth={"authorization_code": provider})
    await client.connect()

    try:
        tools = await client.list_tools()
        print(f"\n{len(tools)} tools available on this server:")
        for tool in tools[:5]:
            print(f"  - {tool['name']}")
    finally:
        rotated = provider.take_if_dirty()
        if rotated is not None:
            save(registered, rotated)
            print("\n(the grant was refreshed and re-saved)")
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
