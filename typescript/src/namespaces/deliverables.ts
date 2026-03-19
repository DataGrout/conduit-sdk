/**
 * Deliverables namespace — work product tracking and retrieval.
 */

export class DeliverablesNamespace {
  /** @internal */
  constructor(private callDg: (tool: string, params: Record<string, any>) => Promise<any>,
              private warn: (method: string) => void) {}

  /** Register a work product (`data-grout/deliverables.register`). */
  async register(params: Record<string, any>): Promise<any> {
    this.warn('deliverables.register');
    return this.callDg('deliverables.register', params);
  }

  /** List deliverables with optional semantic search (`data-grout/deliverables.list`). */
  async list(params: Record<string, any> = {}): Promise<any> {
    this.warn('deliverables.list');
    return this.callDg('deliverables.list', params);
  }

  /** Get a specific deliverable by reference (`data-grout/deliverables.get`). */
  async get(refId: string): Promise<any> {
    this.warn('deliverables.get');
    return this.callDg('deliverables.get', { ref: refId });
  }
}
