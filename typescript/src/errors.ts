/**
 * Typed error classes for the DataGrout Conduit SDK.
 *
 * All errors extend `ConduitError` so callers can catch the whole family with
 * a single `instanceof ConduitError` check, or target specific subclasses.
 */

import type { RateLimitStatus } from './types';

/**
 * Base class for all errors thrown by the Conduit SDK.
 *
 * Fixes the prototype chain so `instanceof` works correctly when compiling
 * to CommonJS / ES5 targets.
 */
export class ConduitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = this.constructor.name;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/**
 * Thrown when a `Client` method is called before `connect()` has been invoked,
 * or after `disconnect()` has been called.
 */
export class NotInitializedError extends ConduitError {
  constructor() {
    super('Client not initialized. Call connect() first.');
  }
}

/**
 * Thrown when the DataGrout gateway returns HTTP 429 (Too Many Requests).
 *
 * Authenticated DataGrout users are never rate-limited. Unauthenticated
 * callers hitting the hourly cap will receive this error.
 *
 * @property status  - Parsed rate-limit header state.
 * @property retryAfter - Seconds to wait before retrying (from `Retry-After` header), if present.
 */
export class RateLimitError extends ConduitError {
  readonly status: RateLimitStatus;
  readonly retryAfter?: number;

  constructor(status: RateLimitStatus, retryAfter?: number) {
    const limitStr =
      status.limit === 'unlimited'
        ? 'unlimited'
        : `${(status.limit as { perHour: number }).perHour}/hour`;
    super(`Rate limit exceeded (${status.used} / ${limitStr} calls this hour)`);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

/**
 * Thrown when the server returns HTTP 401 Unauthorized or HTTP 403 Forbidden.
 */
export class AuthError extends ConduitError {
  constructor(message = 'Authentication failed') {
    super(message);
  }
}

/**
 * Thrown on network-level failures such as fetch errors, connection refused,
 * or request timeouts.
 */
export class NetworkError extends ConduitError {
  constructor(message: string) {
    super(message);
  }
}

/**
 * Thrown when the server returns an unexpected non-success HTTP status or
 * a JSON-RPC error payload.
 *
 * @property code          - HTTP status code or JSON-RPC error code.
 * @property serverMessage - Raw error message from the server.
 */
export class ServerError extends ConduitError {
  readonly code: number;
  readonly serverMessage: string;

  constructor(code: number, serverMessage: string) {
    super(`Server error ${code}: ${serverMessage}`);
    this.code = code;
    this.serverMessage = serverMessage;
  }
}

/**
 * Thrown when required parameters are missing, mutually-exclusive option
 * combinations are invalid, or a method receives an unusable configuration.
 */
export class InvalidConfigError extends ConduitError {
  constructor(message: string) {
    super(message);
  }
}
