"""Type definitions for DataGrout Conduit."""

from typing import Any, Dict, List, Optional, Union
from pydantic import BaseModel, Field


class Receipt(BaseModel):
    """Credit receipt for an operation."""

    receipt_id: str
    estimated_credits: float
    actual_credits: float
    net_credits: float
    savings: float = 0.0
    savings_bonus: float = 0.0
    breakdown: Dict[str, Any] = Field(default_factory=dict)
    byok: Dict[str, Any] = Field(default_factory=dict)


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
