# frozen_string_literal: true

module DatagroutConduit
  class EphemeralsNamespace
    def initialize(client)
      @client = client
    end

    def list(params = {})
      dg_call("ephemerals.list", "data-grout/ephemerals.list", params)
    end

    def inspect(cache_ref)
      dg_call("ephemerals.inspect", "data-grout/ephemerals.inspect", { "cache_ref" => cache_ref })
    end

    private

    def dg_call(label, tool_name, params)
      @client.send(:warn_if_not_dg, label)
      @client.send(:ensure_initialized!)
      @client.send(:call_dg_tool, tool_name, params)
    end
  end
end
