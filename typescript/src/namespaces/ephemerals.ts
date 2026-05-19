/**
 * Ephemerals namespace — cache management and inspection.
 */

export class EphemeralsNamespace {
  /** @internal */
  constructor(
    private callDg: (tool: string, params: Record<string, any>) => Promise<any>,
    private warn: (method: string) => void,
  ) {}

  /** List cached results (`data-grout/ephemerals.list`). */
  async list(params: Record<string, any> = {}): Promise<any> {
    this.warn("ephemerals.list");
    return this.callDg("ephemerals.list", params);
  }

  /** Inspect a specific cache entry (`data-grout/ephemerals.inspect`). */
  async inspect(cacheRef: string): Promise<any> {
    this.warn("ephemerals.inspect");
    return this.callDg("ephemerals.inspect", { cache_ref: cacheRef });
  }
}
