/**
 * The package version, in one place.
 *
 * A leaf module so anything can read it — including the transports, which
 * `index.ts` re-exports and therefore cannot be imported *from* without a
 * cycle. The MCP handshake reports this to the server, and it used to be a
 * separate hardcoded literal that had drifted six minor versions behind.
 */
export const version = "0.8.1";
