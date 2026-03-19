# frozen_string_literal: true

module DatagroutConduit
  class DeliverablesNamespace
    def initialize(client)
      @client = client
    end

    def register(params = {})
      dg_call("deliverables.register", params)
    end

    def list(params = {})
      dg_call("deliverables.list", params)
    end

    def get(ref_id)
      dg_call("deliverables.get", { "ref" => ref_id })
    end

    private

    def dg_call(short_name, params)
      @client.send(:warn_if_not_dg, short_name)
      @client.send(:ensure_initialized!)
      @client.send(:call_dg_tool, "data-grout/#{short_name}", params)
    end
  end
end
