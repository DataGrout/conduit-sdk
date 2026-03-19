/**
 * Logic Cell namespace — agent memory, facts, constraints, and hypotheticals.
 */

import { InvalidConfigError } from '../errors';
import type {
  RememberOptions,
  QueryCellOptions,
  ForgetOptions,
  ConstrainOptions,
  ReflectOptions,
} from '../types';

export class LogicNamespace {
  /** @internal */
  constructor(private callDg: (tool: string, params: Record<string, any>) => Promise<any>,
              private warn: (method: string) => void) {}

  /** Assert facts into the logic cell (`data-grout/logic.remember`). */
  async remember(statement: string, options?: RememberOptions): Promise<{ handles: string[]; facts: any[]; count: number; message: string }>;
  async remember(options: RememberOptions): Promise<{ handles: string[]; facts: any[]; count: number; message: string }>;
  async remember(
    statementOrOptions: string | RememberOptions,
    optionsArg?: RememberOptions
  ): Promise<{ handles: string[]; facts: any[]; count: number; message: string }> {
    let statement: string | undefined;
    let opts: RememberOptions | undefined;

    if (typeof statementOrOptions === 'string') {
      statement = statementOrOptions;
      opts = optionsArg;
    } else {
      opts = statementOrOptions;
      statement = opts.statement;
    }

    if (!statement && !opts?.facts?.length) {
      throw new InvalidConfigError('remember() requires either a statement or facts');
    }

    const params: Record<string, any> = { tag: opts?.tag ?? 'default' };
    if (opts?.facts) {
      params.facts = opts.facts;
    } else {
      params.statement = statement;
    }
    return this.callDg('logic.remember', params);
  }

  /** Query the logic cell with natural language (`data-grout/logic.query`). */
  async query(question: string, options?: QueryCellOptions): Promise<{ results: any[]; total: number; description: string; message: string }>;
  async query(options: QueryCellOptions): Promise<{ results: any[]; total: number; description: string; message: string }>;
  async query(
    questionOrOptions: string | QueryCellOptions,
    optionsArg?: QueryCellOptions
  ): Promise<{ results: any[]; total: number; description: string; message: string }> {
    let question: string | undefined;
    let opts: QueryCellOptions | undefined;

    if (typeof questionOrOptions === 'string') {
      question = questionOrOptions;
      opts = optionsArg;
    } else {
      opts = questionOrOptions;
      question = opts.question;
    }

    if (!question && !opts?.patterns?.length) {
      throw new InvalidConfigError('query() requires either a question or patterns');
    }

    const params: Record<string, any> = { limit: opts?.limit ?? 50 };
    if (opts?.patterns) {
      params.patterns = opts.patterns;
    } else {
      params.question = question;
    }
    return this.callDg('logic.query', params);
  }

  /** Retract facts from the logic cell (`data-grout/logic.forget`). */
  async forget(options: ForgetOptions): Promise<{ retracted: number; handles: string[]; message: string }> {
    if (!options.handles?.length && !options.pattern) {
      throw new InvalidConfigError('forget() requires either handles or pattern');
    }
    const params: Record<string, any> = {};
    if (options.handles) params.handles = options.handles;
    if (options.pattern) params.pattern = options.pattern;
    return this.callDg('logic.forget', params);
  }

  /** Reflect on the logic cell (`data-grout/logic.reflect`). */
  async reflect(options?: ReflectOptions): Promise<{ total: number; summary?: any; entity?: string; facts?: any[]; message: string }> {
    const params: Record<string, any> = { summary_only: options?.summaryOnly ?? false };
    if (options?.entity) params.entity = options.entity;
    return this.callDg('logic.reflect', params);
  }

  /** Add a constraint rule (`data-grout/logic.constrain`). */
  async constrain(rule: string, options?: ConstrainOptions): Promise<{ handle: string; name: string; rule: string; message: string }> {
    const params: Record<string, any> = { rule, tag: options?.tag ?? 'constraint' };
    return this.callDg('logic.constrain', params);
  }

  /** Hydrate the logic cell from external data (`data-grout/logic.hydrate`). */
  async hydrate(params: Record<string, any>): Promise<any> {
    this.warn('logic.hydrate');
    return this.callDg('logic.hydrate', params);
  }

  /** Export the logic cell contents (`data-grout/logic.export`). */
  async exportCell(params: Record<string, any> = {}): Promise<any> {
    this.warn('logic.export');
    return this.callDg('logic.export', params);
  }

  /** Import facts into the logic cell (`data-grout/logic.import`). */
  async importCell(params: Record<string, any>): Promise<any> {
    this.warn('logic.import');
    return this.callDg('logic.import', params);
  }

  /** Tabulate logic cell contents (`data-grout/logic.tabulate`). */
  async tabulate(params: Record<string, any> = {}): Promise<any> {
    this.warn('logic.tabulate');
    return this.callDg('logic.tabulate', params);
  }

  /** Manage hypothetical worlds (`data-grout/logic.worlds`). */
  async worlds(params: Record<string, any>): Promise<any> {
    this.warn('logic.worlds');
    return this.callDg('logic.worlds', params);
  }
}
