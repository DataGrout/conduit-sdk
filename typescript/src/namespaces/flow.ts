/**
 * Flow namespace — orchestration, routing, approvals, and execution history.
 */

import type { FlowOptions } from '../types';

export class FlowNamespace {
  /** @internal */
  constructor(private callDg: (tool: string, params: Record<string, any>) => Promise<any>,
              private warn: (method: string) => void) {}

  /** Execute a multi-step workflow plan (`data-grout/flow.into`). */
  async run(options: FlowOptions): Promise<any> {
    this.warn('flow.into');
    const params: Record<string, any> = {
      plan: options.plan,
      validate_ctc: options.validateCtc ?? true,
      save_as_skill: options.saveAsSkill ?? false,
    };
    if (options.inputData) params.input_data = options.inputData;
    return this.callDg('flow.into', params);
  }

  /** Conditional dispatch with predicate-based branching (`data-grout/flow.route`). */
  async route(options: {
    branches: Array<Record<string, any>>;
    payload?: any;
    cacheRef?: string;
    else?: any;
    [k: string]: any;
  }): Promise<any> {
    this.warn('flow.route');
    const { branches, payload, cacheRef, else: elseTarget, ...rest } = options;
    const params: Record<string, any> = { branches, ...rest };
    if (payload !== undefined) params.payload = payload;
    if (cacheRef !== undefined) params.cache_ref = cacheRef;
    if (elseTarget !== undefined) params.else = elseTarget;
    return this.callDg('flow.route', params);
  }

  /** Pause workflow for human approval (`data-grout/flow.request-approval`). */
  async requestApproval(options: { action: string; details?: Record<string, any>; reason?: string; context?: Record<string, any>; [k: string]: any }): Promise<any> {
    this.warn('flow.request-approval');
    const { action, details, reason, context, ...rest } = options;
    const params: Record<string, any> = { action, ...rest };
    if (details !== undefined) params.details = details;
    if (reason !== undefined) params.reason = reason;
    if (context !== undefined) params.context = context;
    return this.callDg('flow.request-approval', params);
  }

  /** Request user clarification for missing fields (`data-grout/flow.request-feedback`). */
  async requestFeedback(options: { missing_fields: string[]; reason: string; current_data?: Record<string, any>; suggestions?: Record<string, any>; context?: Record<string, any>; [k: string]: any }): Promise<any> {
    this.warn('flow.request-feedback');
    const { missing_fields, reason, ...rest } = options;
    const params: Record<string, any> = { missing_fields, reason, ...rest };
    return this.callDg('flow.request-feedback', params);
  }

  /** List recent tool executions (`data-grout/inspect.execution-history`). */
  async history(options: { limit?: number; offset?: number; status?: string; refractions_only?: boolean; [k: string]: any } = {}): Promise<any> {
    this.warn('inspect.execution-history');
    const params: Record<string, any> = {
      limit: options.limit ?? 50,
      offset: options.offset ?? 0,
      refractions_only: options.refractions_only ?? false,
      ...options,
    };
    if (options.status !== undefined) params.status = options.status;
    return this.callDg('inspect.execution-history', params);
  }

  /** Get details for a specific execution (`data-grout/inspect.execution-details`). */
  async details(executionId: string): Promise<any> {
    this.warn('inspect.execution-details');
    return this.callDg('inspect.execution-details', { execution_id: executionId });
  }
}
