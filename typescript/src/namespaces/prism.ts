/**
 * Prism namespace — data transformation, charting, rendering, and export.
 */

import type {
  RefractOptions,
  ChartOptions,
  PrismFocusOptions,
} from '../types';

export class PrismNamespace {
  /** @internal */
  constructor(private callDg: (tool: string, params: Record<string, any>) => Promise<any>,
              private warn: (method: string) => void) {}

  /** AI-driven data transformation (`data-grout/prism.refract`). */
  async refract(options: RefractOptions): Promise<any> {
    this.warn('prism.refract');
    const params: Record<string, any> = {
      goal: options.goal,
      payload: options.payload,
    };
    if (options.verbose !== undefined) params.verbose = options.verbose;
    if (options.chart !== undefined) params.chart = options.chart;
    return this.callDg('prism.refract', params);
  }

  /** AI-driven charting (`data-grout/prism.chart`). */
  async chart(options: ChartOptions): Promise<any> {
    this.warn('prism.chart');
    const params: Record<string, any> = {
      goal: options.goal,
      payload: options.payload,
    };
    if (options.format) params.format = options.format;
    if (options.chartType) params.chart_type = options.chartType;
    if (options.title) params.title = options.title;
    if (options.xLabel) params.x_label = options.xLabel;
    if (options.yLabel) params.y_label = options.yLabel;
    if (options.width !== undefined) params.width = options.width;
    if (options.height !== undefined) params.height = options.height;
    return this.callDg('prism.chart', params);
  }

  /** Generate a document toward a natural-language goal (`data-grout/prism.render`). */
  async render(options: { goal: string; payload?: any; format?: string; sections?: any[]; [k: string]: any }): Promise<any> {
    this.warn('prism.render');
    const { goal, format = 'markdown', payload, sections, ...rest } = options;
    const params: Record<string, any> = { goal, format, ...rest };
    if (payload !== undefined) params.payload = payload;
    if (sections !== undefined) params.sections = sections;
    return this.callDg('prism.render', params);
  }

  /** Convert content to another format without LLM (`data-grout/prism.export`). */
  async export(options: { content: any; format: string; style?: Record<string, any>; metadata?: Record<string, any>; [k: string]: any }): Promise<any> {
    this.warn('prism.export');
    const { content, format, ...rest } = options;
    const params: Record<string, any> = { content, format, ...rest };
    return this.callDg('prism.export', params);
  }

  /** Semantic type transformation (`data-grout/prism.focus`). */
  async focus(options: PrismFocusOptions): Promise<any> {
    this.warn('prism.focus');
    const params: Record<string, any> = {
      data: options.data,
      source_type: options.sourceType,
      target_type: options.targetType,
      ...(options.sourceAnnotations && { source_annotations: options.sourceAnnotations }),
      ...(options.targetAnnotations && { target_annotations: options.targetAnnotations }),
      ...(options.context && { context: options.context }),
    };
    return this.callDg('prism.focus', params);
  }
}
