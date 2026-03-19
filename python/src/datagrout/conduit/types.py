"""Type definitions for DataGrout Conduit."""

from typing import Any, Dict, List, Literal, Optional, Union
from pydantic import BaseModel, Field
from .registration import Receipt


class ToolInfo(BaseModel):
    """Tool information from discovery."""

    tool_name: str
    integration: str
    server_id: Optional[str] = None
    score: Optional[float] = None
    distance: Optional[float] = None
    description: Optional[str] = None
    side_effects: Optional[str] = None
    input_schema: Optional[Dict[str, Any]] = None
    output_schema: Optional[Dict[str, Any]] = None


class DiscoverResult(BaseModel):
    """Result from discovery operation."""

    query_used: str
    results: List[ToolInfo]
    total: int
    limit: int


class PerformResult(BaseModel):
    """Result from perform operation."""

    success: bool
    result: Any
    tool: str
    metadata: Dict[str, Any] = Field(default_factory=dict)
    receipt: Optional[Receipt] = None


class GuideOptions(BaseModel):
    """Options in a guided workflow step."""

    id: str
    label: str
    cost: float
    viable: bool
    metadata: Dict[str, Any] = Field(default_factory=dict)


class GuideState(BaseModel):
    """State of a guided workflow session."""

    session_id: str
    step: str
    message: str
    status: str
    options: List[GuideOptions] = Field(default_factory=list)
    path_taken: List[str] = Field(default_factory=list)
    total_cost: float = 0.0
    result: Optional[Any] = None
    progress: Optional[str] = None


# ─── Rate limiting ────────────────────────────────────────────────────────────


class RateLimitPerHour(BaseModel):
    """A fixed per-hour call cap returned in ``X-RateLimit-Limit`` headers."""

    per_hour: int


# Either the literal string "unlimited" (authenticated DG users) or a per-hour cap.
RateLimit = Union[Literal["unlimited"], RateLimitPerHour]


class RateLimitStatus(BaseModel):
    """Parsed rate limit state from a DataGrout gateway response.

    Surfaced via :class:`RateLimitError` when the client receives HTTP 429.

    - Authenticated DataGrout users always receive ``limit="unlimited"``.
    - Unauthenticated callers are subject to ``RateLimitPerHour``.
    """

    used: int
    """Calls made in the current 1-hour window."""

    limit: RateLimit
    """Total allowed calls in the window, or ``"unlimited"``."""

    is_limited: bool
    """``True`` when the caller has been throttled."""

    remaining: Optional[int]
    """Remaining calls this window, or ``None`` for unlimited."""

    @classmethod
    def unlimited(cls) -> "RateLimitStatus":
        """Construct an unlimited status (authenticated DG user)."""
        return cls(used=0, limit="unlimited", is_limited=False, remaining=None)

    @classmethod
    def from_headers(cls, used: int, limit_str: str) -> "RateLimitStatus":
        """Parse a ``RateLimitStatus`` from ``X-RateLimit-*`` header values."""
        if limit_str.lower() == "unlimited":
            return cls.unlimited()
        per_hour = int(limit_str)
        is_limited = used >= per_hour
        remaining = max(0, per_hour - used)
        return cls(
            used=used,
            limit=RateLimitPerHour(per_hour=per_hour),
            is_limited=is_limited,
            remaining=remaining,
        )


def extract_meta(result: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Extract DataGrout metadata from a tool-call result.

    Checks sources in priority order:
    1. ``result["_meta"]["datagrout"]`` — rich format
    2. ``result["_datagrout"]`` / ``result["_meta"]`` — legacy
    3. ``result["_dg"]`` — compact inline (synthesized)

    Returns ``None`` when no metadata is found.
    """
    import logging

    _log = logging.getLogger("datagrout.conduit")

    # 1. Rich: _meta.datagrout
    rich = (result.get("_meta") or {}).get("datagrout")
    if rich and isinstance(rich, dict) and "receipt" in rich:
        return rich

    # 2. Legacy: _datagrout or bare _meta
    for key in ("_datagrout", "_meta"):
        legacy = result.get(key)
        if legacy and isinstance(legacy, dict) and "receipt" in legacy:
            return legacy

    # 3. Compact: _dg (synthesize)
    dg = result.get("_dg")
    if dg and isinstance(dg, dict):
        credits = dg.get("credits", {})
        breakdown = {}
        if "premium" in credits:
            breakdown["premium"] = credits["premium"]
        if "llm" in credits:
            breakdown["llm"] = credits["llm"]
        return {
            "receipt": {
                "receipt_id": "",
                "timestamp": "",
                "estimated_credits": credits.get("estimated", 0.0),
                "actual_credits": credits.get("charged", 0.0),
                "net_credits": credits.get("charged", 0.0),
                "savings": 0.0,
                "savings_bonus": 0.0,
                "balance_after": credits.get("remaining"),
                "breakdown": breakdown,
                "byok": {"enabled": False, "discount_applied": 0.0, "discount_rate": 0.0},
            }
        }

    _log.warning(
        "No DataGrout metadata found in tool result. "
        "Cost tracking data is unavailable. Enable 'Include DG Inline' "
        "or 'Include DataGrout Metadata' in your server settings."
    )
    return None
