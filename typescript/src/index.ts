/**
 * DataGrout Conduit SDK for TypeScript/JavaScript
 */

export { Client, GuidedSession, isDgUrl } from './client';
export { ConduitIdentity } from './identity';
export type { MtlsConfig } from './identity';
export { OAuthTokenProvider, deriveTokenEndpoint } from './oauth';
export {
  DG_CA_URL,
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
export { extractMeta } from './types';
export type { Byok, CreditEstimate, Receipt, ToolMeta } from './types';
export { RateLimitError } from './transports/jsonrpc';
export type * from './types';

export const version = '0.1.0';
