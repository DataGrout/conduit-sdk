/**
 * DataGrout Conduit SDK for TypeScript/JavaScript
 */

export { Client, GuidedSession, isDgUrl } from './client';
export type { Subscription, SubscriptionEvent } from './transports/ws';
export { WsTransport, SUBPROTOCOL as WS_SUBPROTOCOL } from './transports/ws';
export { ConduitIdentity, fetchWithIdentity } from './identity';
export type { MtlsConfig } from './identity';
export { OAuthTokenProvider, deriveTokenEndpoint } from './oauth';
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
} from './registration';
export type {
  Keypair,
  RegisteredIdentity,
  RegistrationOptions,
  RenewalOptions,
  RotationOptions,
  SavedPaths,
} from './registration';
export {
  ConduitError,
  NotInitializedError,
  RateLimitError,
  AuthError,
  NetworkError,
  ServerError,
  InvalidConfigError,
} from './errors';
export { extractMeta } from './types';
export type * from './types';

export const version = '0.4.0';
