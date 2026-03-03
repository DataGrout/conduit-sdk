"""Exception hierarchy for DataGrout Conduit.

All SDK exceptions derive from :class:`ConduitError` so callers can catch the
entire family with a single ``except ConduitError`` clause, or handle specific
failure modes individually.

Multiple-inheritance from built-in exception types (``RuntimeError``,
``ValueError``) is intentional: it preserves backward compatibility with
existing code that catches the standard Python exceptions.
"""

from typing import Optional


class ConduitError(Exception):
    """Base exception for all DataGrout Conduit errors."""


class NotInitializedError(ConduitError, RuntimeError):
    """Raised when a :class:`~datagrout.conduit.Client` method is called before
    :meth:`~datagrout.conduit.Client.connect` (or ``async with``)."""


class RateLimitError(ConduitError):
    """Raised when the server returns HTTP 429.

    Authenticated DataGrout users are never rate-limited. Unauthenticated
    callers that exceed the hourly cap receive this error.

    Args:
        message: Human-readable description of the limit exceeded.
        retry_after: Seconds to wait before retrying, if provided by the server.
    """

    def __init__(self, message: str, retry_after: Optional[float] = None) -> None:
        super().__init__(message)
        self.retry_after = retry_after


class AuthError(ConduitError):
    """Raised on HTTP 401 authentication failures (after any OAuth retry)."""


class NetworkError(ConduitError):
    """Raised on connection or network-level failures (timeouts, DNS, etc.)."""


class ServerError(ConduitError):
    """Raised for unexpected server-side errors (e.g. HTTP 5xx).

    Args:
        message: Human-readable summary.
        code: HTTP status code.
        server_message: Raw error body/message returned by the server.
    """

    def __init__(self, message: str, code: int, server_message: str) -> None:
        super().__init__(message)
        self.code = code
        self.server_message = server_message


class InvalidConfigError(ConduitError, ValueError):
    """Raised when required arguments are missing or mutually exclusive.

    Inherits from :class:`ValueError` for backward compatibility with callers
    that catch the standard Python exception.
    """
