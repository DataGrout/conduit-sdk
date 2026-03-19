# frozen_string_literal: true

module DatagroutConduit
  class PrismNamespace
    def initialize(client)
      @client = client
    end

    def refract(goal:, payload:, **opts)
      params = { "goal" => goal, "payload" => payload }
      params["verbose"] = opts[:verbose] if opts.key?(:verbose)
      params["chart"] = opts[:chart] if opts.key?(:chart)
      dg_call("prism.refract", params)
    end

    def chart(goal:, payload:, **opts)
      params = { "goal" => goal, "payload" => payload }
      params["format"] = opts[:format] if opts[:format]
      params["chart_type"] = opts[:chart_type] if opts[:chart_type]
      params["title"] = opts[:title] if opts[:title]
      params["x_label"] = opts[:x_label] if opts[:x_label]
      params["y_label"] = opts[:y_label] if opts[:y_label]
      params["width"] = opts[:width] if opts[:width]
      params["height"] = opts[:height] if opts[:height]
      dg_call("prism.chart", params)
    end

    def render(goal:, payload: nil, format: "markdown", sections: nil, **opts)
      params = { "goal" => goal, "format" => format }.merge(@client.send(:normalize_hash, opts))
      params["payload"] = payload if payload
      params["sections"] = sections if sections
      dg_call("prism.render", params)
    end

    def export(content:, format:, style: nil, metadata: nil, **opts)
      params = { "content" => content, "format" => format }.merge(@client.send(:normalize_hash, opts))
      params["style"] = style if style
      params["metadata"] = metadata if metadata
      dg_call("prism.export", params)
    end

    def focus(data:, source_type:, target_type:, source_annotations: nil, target_annotations: nil, context: nil)
      params = { "data" => data, "source_type" => source_type, "target_type" => target_type }
      params["source_annotations"] = source_annotations if source_annotations
      params["target_annotations"] = target_annotations if target_annotations
      params["context"] = context if context
      dg_call("prism.focus", params)
    end

    private

    def dg_call(short_name, params)
      @client.send(:warn_if_not_dg, short_name)
      @client.send(:ensure_initialized!)
      @client.send(:call_dg_tool, "data-grout/#{short_name}", params)
    end
  end
end
