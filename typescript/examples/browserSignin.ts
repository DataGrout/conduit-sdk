/**
 * Browser-consent sign-in with OAuth 2.1 authorization code + PKCE.
 *
 * Run once and it opens a consent page, captures the redirect on 127.0.0.1,
 * and writes the grant to disk. Run again and it reuses what it saved.
 *
 *   npx tsx examples/browserSignin.ts
 *
 * Two things this example exists to demonstrate, both of which are easy to get
 * wrong and only fail later:
 *
 *  1. The registered client id is persisted **with its redirect URI**, and the
 *     listener re-binds that exact port on the next run. Authorization servers
 *     match redirect URIs exactly, with no loopback-port exemption.
 *  2. DataGrout rotates refresh tokens, so a refreshed grant is written back.
 *     A grant that is refreshed and not persisted leaves a consumed token on
 *     disk, and the next run fails with `invalid_grant`.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

import {
  AuthCodeFlow,
  AuthCodeProvider,
  Client,
  LoopbackListener,
  type Grant,
  type RegisteredClient,
} from "@datagrout/conduit";

const GATEWAY = "https://gateway.datagrout.ai/connect";

/**
 * Where this example keeps its credentials.
 *
 * A file, and deliberately called out as such: it holds a refresh token, which
 * is a long-lived credential. A real application should prefer the OS keychain.
 * The SDK does not choose for you.
 */
const STORE = join(homedir(), ".config", "conduit-example", "signin.json");

interface Saved {
  registered: RegisteredClient;
  grant: Grant;
}

function load(): Saved | undefined {
  try {
    return JSON.parse(readFileSync(STORE, "utf8")) as Saved;
  } catch {
    return undefined;
  }
}

function save(saved: Saved): void {
  mkdirSync(dirname(STORE), { recursive: true });
  writeFileSync(STORE, JSON.stringify(saved, null, 2), { mode: 0o600 });
}

/** Run the full consent flow and return something worth persisting. */
async function signIn(existing?: RegisteredClient): Promise<Saved> {
  // Bind first: the real port has to be known before the redirect URI is
  // registered. Reusing a saved registration means re-binding its exact port.
  const listener = existing
    ? await LoopbackListener.bindFor(existing.redirect_uri).catch(() => {
        console.warn(
          `port ${existing.redirect_uri} is taken — registering a fresh client`,
        );
        return LoopbackListener.bind();
      })
    : await LoopbackListener.bind();

  const flow = await AuthCodeFlow.discover(GATEWAY);

  // A saved registration is only reusable if the listener came back on its
  // port; otherwise register anew rather than authorize against a URI the
  // server will reject.
  const reusable = existing && listener.redirectUri === existing.redirect_uri;
  const registered = reusable
    ? (flow.withRegisteredClient(existing), existing)
    : await flow.register("Conduit Example", listener.redirectUri);

  const { url, pending } = flow.authorizeUrl();
  console.log(`\nOpen this URL to sign in:\n\n  ${url}\n`);

  const redirect = await listener.wait(300_000);
  const grant = await flow.exchange(pending, redirect.code, redirect.state);

  return { registered, grant };
}

async function main() {
  let saved = load();

  if (saved) {
    console.log("using the saved sign-in");
  } else {
    saved = await signIn();
    save(saved);
    console.log(`signed in; credentials written to ${STORE}`);
  }

  // Own the provider so a rotated refresh token can be written back.
  const provider = new AuthCodeProvider(saved.grant);

  const client = new Client({
    url: GATEWAY,
    auth: { authorizationCode: provider },
  });
  await client.connect();

  try {
    const tools = await client.listTools();
    console.log(`\n${tools.length} tools available on this server:`);
    for (const tool of tools.slice(0, 5)) {
      console.log(`  - ${tool.name}`);
    }
  } finally {
    const rotated = provider.takeIfDirty();
    if (rotated) {
      save({ registered: saved.registered, grant: rotated });
      console.log("\n(the grant was refreshed and re-saved)");
    }
    await client.disconnect();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
