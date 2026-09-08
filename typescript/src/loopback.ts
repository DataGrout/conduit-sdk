/**
 * Capture the OAuth redirect on `127.0.0.1`.
 *
 * A native app has no web server to redirect to, so it runs one for a few
 * seconds: bind a loopback port, send the user to the consent page, and read
 * the `code` off the single request the browser makes coming back.
 *
 * This lives in its own module rather than in `authcode` so a headless caller
 * can take the flow without pulling in an HTTP server — the same split every
 * conduit SDK makes, so the surface looks the same in every language.
 *
 * ```ts
 * import { AuthCodeFlow } from "@datagrout/conduit";
 * import { LoopbackListener } from "@datagrout/conduit";
 *
 * const listener = await LoopbackListener.bind();
 * const flow = await AuthCodeFlow.discover("https://gateway.datagrout.ai/connect");
 * await flow.register("My App", listener.redirectUri);
 *
 * const { url, pending } = flow.authorizeUrl();
 * // open `url` in a browser however suits the application
 *
 * const redirect = await listener.wait(300_000);
 * const grant = await flow.exchange(pending, redirect.code, redirect.state);
 * ```
 */

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { AuthCodeError } from "./authcode";

/** What the authorization server sent back to the redirect URI. */
export interface Redirect {
  /** The authorization code. */
  code: string;
  /** The `state` parameter, to be checked against the pending request. */
  state: string;
}

/** A one-shot loopback listener for the OAuth redirect. */
export class LoopbackListener {
  private readonly server: Server;
  private readonly boundPort: number;
  private readonly path: string;
  private settled = false;

  private constructor(server: Server, port: number, path: string) {
    this.server = server;
    this.boundPort = port;
    this.path = path;
  }

  /**
   * Bind an OS-assigned port on `127.0.0.1`.
   *
   * Letting the OS choose avoids fighting whatever else owns a fixed port —
   * and because registration happens after binding, the real port is already
   * known by the time the redirect URI is registered.
   */
  static bind(): Promise<LoopbackListener> {
    return LoopbackListener.bindOn(0, "/callback");
  }

  /**
   * Bind a specific port and path.
   *
   * Use when the client was registered out of band against a fixed redirect
   * URI and the authorization server will accept no other.
   */
  static bindOn(port: number, path: string): Promise<LoopbackListener> {
    const normalized = path.startsWith("/") ? path : `/${path}`;

    return new Promise((resolve, reject) => {
      const server = createServer();

      server.once("error", (err) => {
        reject(new AuthCodeError("http", `cannot bind loopback port: ${err}`));
      });

      server.listen(port, "127.0.0.1", () => {
        const address = server.address() as AddressInfo | null;
        if (!address) {
          server.close();
          reject(
            new AuthCodeError("http", "cannot bind loopback port: no address"),
          );
          return;
        }
        resolve(new LoopbackListener(server, address.port, normalized));
      });
    });
  }

  /**
   * Re-bind the exact port and path of a previously registered redirect URI.
   *
   * Needed whenever a saved registration is reused: the authorization server
   * matches the redirect URI exactly, so the listener has to come back on the
   * same port it registered.
   *
   * Rejects if that port is occupied. The right recovery is to {@link bind} a
   * fresh port and register a new client — not to retry, and not to authorize
   * against a URI the server will reject.
   */
  static bindFor(redirectUri: string): Promise<LoopbackListener> {
    let parsed: URL;
    try {
      parsed = new URL(redirectUri);
    } catch (err) {
      return Promise.reject(
        new AuthCodeError("http", `bad redirect_uri ${redirectUri}: ${err}`),
      );
    }

    if (!parsed.port) {
      return Promise.reject(
        new AuthCodeError("http", `redirect_uri ${redirectUri} names no port`),
      );
    }

    return LoopbackListener.bindOn(Number(parsed.port), parsed.pathname);
  }

  /** The port actually bound. */
  get port(): number {
    return this.boundPort;
  }

  /**
   * The redirect URI to register and to send in the authorize request.
   *
   * Uses `127.0.0.1` rather than `localhost`: RFC 8252 recommends the literal
   * address, and it sidesteps hosts where `localhost` resolves to IPv6 first
   * while the listener is bound to IPv4.
   */
  get redirectUri(): string {
    return `http://127.0.0.1:${this.boundPort}${this.path}`;
  }

  /** Stop listening. Safe to call more than once. */
  close(): void {
    this.server.close();
  }

  /**
   * Wait for the browser's redirect, up to `timeoutMs`.
   *
   * Serves a small page either way so the user sees an outcome rather than a
   * browser error, then stops listening. Requests to other paths are answered
   * 404 and ignored — browsers routinely ask for `/favicon.ico`, and treating
   * that as the redirect would abort the flow.
   */
  wait(timeoutMs: number): Promise<Redirect> {
    return new Promise<Redirect>((resolve, reject) => {
      const finish = (fn: () => void) => {
        if (this.settled) return;
        this.settled = true;
        clearTimeout(timer);
        this.server.removeAllListeners("request");
        this.close();
        fn();
      };

      const timer = setTimeout(() => {
        finish(() =>
          reject(
            new AuthCodeError(
              "http",
              `timed out after ${Math.round(
                timeoutMs / 1000,
              )}s waiting for the authorization redirect`,
            ),
          ),
        );
      }, timeoutMs);
      // Do not hold the event loop open on account of the timeout itself.
      timer.unref?.();

      this.server.on("request", (req, res) => {
        const target = new URL(req.url ?? "/", "http://127.0.0.1");

        if (target.pathname !== this.path) {
          respond(res, 404, "Not found");
          return;
        }

        const error = target.searchParams.get("error");
        if (error) {
          respond(
            res,
            200,
            "Authorization was denied. You can close this window.",
          );
          const description = target.searchParams.get("error_description");
          finish(() =>
            reject(
              new AuthCodeError(
                "denied",
                `authorization denied: ${error}${
                  description ? ` — ${description}` : ""
                }`,
              ),
            ),
          );
          return;
        }

        const code = target.searchParams.get("code");
        const state = target.searchParams.get("state");
        if (code !== null && state !== null) {
          respond(
            res,
            200,
            "Signed in. You can close this window and return to the app.",
          );
          finish(() => resolve({ code, state }));
          return;
        }

        respond(res, 400, "Missing code or state.");
        finish(() =>
          reject(
            new AuthCodeError(
              "discovery",
              "redirect carried neither an error nor a code/state pair",
            ),
          ),
        );
      });
    });
  }
}

function respond(
  res: import("node:http").ServerResponse,
  status: number,
  message: string,
): void {
  const body =
    `<!DOCTYPE html><html><head><meta charset="utf-8"><title>DataGrout</title>` +
    `<style>body{font:15px/1.5 system-ui,sans-serif;margin:16vh auto;max-width:26rem;` +
    `text-align:center;color-scheme:light dark}</style></head>` +
    `<body><p>${message}</p></body></html>`;

  res.writeHead(status, {
    "content-type": "text/html; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    connection: "close",
  });
  res.end(body);
}
