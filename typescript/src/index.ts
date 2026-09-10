/**
 * DataGrout Conduit SDK for TypeScript/JavaScript
 */

export { Client, GuidedSession, isDgUrl } from "./client";
export type { Subscription, SubscriptionEvent } from "./transports/ws";
export { WsTransport, SUBPROTOCOL as WS_SUBPROTOCOL } from "./transports/ws";
export { ConduitIdentity, fetchWithIdentity } from "./identity";
export type { MtlsConfig } from "./identity";
export { OAuthTokenProvider, deriveTokenEndpoint } from "./oauth";
export {
  AuthCodeFlow,
  AuthCodeProvider,
  AuthCodeError,
  DEFAULT_SCOPE,
  authCodeProviderFrom,
  challengeS256,
  generateVerifier,
  isGrantExpired,
  isGrantRefreshable,
  refreshGrant,
  supportsS256,
} from "./authcode";
export type {
  AuthCodeErrorKind,
  AuthServerMetadata,
  Grant,
  PendingAuthorization,
  RegisteredClient,
} from "./authcode";
// RFC 8693 delegation — an agent acting *for* a user. Named "delegation" and
// "exchange" throughout: "token exchange" already means the client-credentials
// grant here (`AuthCodeError`'s `token_exchange` kind, the onramp's
// `token_exchange` stage), and one label cannot mean two grants.
export {
  DelegatedProvider,
  DelegationError,
  DelegationRequest,
  TokenSource,
  GRANT_TYPE as DELEGATION_GRANT_TYPE,
  SERVER_ERROR_CODES as DELEGATION_SERVER_ERROR_CODES,
  TOKEN_TYPES,
  isDelegatedTokenExpired,
  tokenTypeName,
} from "./delegation";
export type {
  ClientAuth,
  DelegatedToken,
  DelegationErrorKind,
  NamedTokenTypeUrn,
  ServerErrorCode,
  TokenSourceKind,
  TokenType,
  TokenTypeName,
} from "./delegation";
// The loopback listener is its own module so a headless caller can import the
// flow without an HTTP server; it is re-exported here for convenience.
export { LoopbackListener } from "./loopback";
export type { Redirect } from "./loopback";
export {
  DG_CA_URL,
  DG_SUBSTRATE_ENDPOINT,
  DEFAULT_IDENTITY_DIR,
  fetchDgCaCert,
  generateKeypair,
  refreshCaCert,
  registerIdentity,
  rotateIdentity,
  saveIdentity,
} from "./registration";
export type {
  Keypair,
  RegisteredIdentity,
  RegistrationOptions,
  RenewalOptions,
  RotationOptions,
  SavedPaths,
} from "./registration";
export {
  ConduitError,
  NotInitializedError,
  RateLimitError,
  AuthError,
  NetworkError,
  ServerError,
  InvalidConfigError,
} from "./errors";
export { extractMeta } from "./types";
export type * from "./types";

export { registerOnly, registerAndExchange } from "./onramp";
export type { OnrampOptions, OnrampCredentials } from "./onramp";

export { version } from "./version";
