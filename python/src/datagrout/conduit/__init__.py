"""DataGrout Conduit SDK for Python."""

from .client import Client, GuidedSession, is_dg_url
from .identity import ConduitIdentity
from .oauth import OAuthTokenProvider, derive_token_endpoint
from .registration import (
    DG_CA_URL,
    Byok,
    CreditEstimate,
    Receipt,
    RegistrationResponse,
    SavedIdentityPaths,
    ToolMeta,
    default_identity_dir,
    extract_meta,
    fetch_dg_ca_cert,
    generate_keypair,
    refresh_ca_cert,
    register_identity,
    rotate_identity,
    save_identity,
)
from .transports import Transport, MCPTransport, JSONRPCTransport
from .transports.jsonrpc_transport import RateLimitError
from .types import (
    DiscoverResult,
    PerformResult,
    RateLimit,
    RateLimitPerHour,
    RateLimitStatus,
)

__version__ = "0.1.0"

__all__ = [
    # Client
    "Client",
    "GuidedSession",
    "is_dg_url",
    # Identity / mTLS
    "ConduitIdentity",
    # Registration + CA
    "DG_CA_URL",
    "Byok",
    "CreditEstimate",
    "Receipt",
    "RegistrationResponse",
    "SavedIdentityPaths",
    "ToolMeta",
    "default_identity_dir",
    "extract_meta",
    "fetch_dg_ca_cert",
    "generate_keypair",
    "refresh_ca_cert",
    "register_identity",
    "rotate_identity",
    "save_identity",
    # OAuth 2.1
    "OAuthTokenProvider",
    "derive_token_endpoint",
    # Rate limiting
    "RateLimitError",
    "RateLimit",
    "RateLimitPerHour",
    "RateLimitStatus",
    # Common types
    "DiscoverResult",
    "PerformResult",
    # Transports
    "Transport",
    "MCPTransport",
    "JSONRPCTransport",
]
