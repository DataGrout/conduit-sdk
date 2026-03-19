# frozen_string_literal: true

module DatagroutConduit
  class WardenNamespace
    def initialize(client)
      @client = client
    end

    def canary(params = {})
      dg_call("warden.canary", params)
    end

    def verify_intent(params = {})
      dg_call("warden.intent", params)
    end

    def adjudicate(params = {})
      dg_call("warden.adjudicate", params)
    end

    def ensemble(params = {})
      dg_call("warden.ensemble", params)
    end

    private

    def dg_call(short_name, params)
      @client.send(:warn_if_not_dg, short_name)
      @client.send(:ensure_initialized!)
      @client.send(:call_dg_tool, "data-grout/#{short_name}", params)
    end
  end
end
