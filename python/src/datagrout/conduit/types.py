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
