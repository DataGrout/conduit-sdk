# frozen_string_literal: true

module DatagroutConduit
  class FlowNamespace
    def initialize(client)
      @client = client
    end

    def run(plan, validate_ctc: true, save_as_skill: false, input_data: nil)
      params = {
        "plan" => plan,
        "validate_ctc" => validate_ctc,
        "save_as_skill" => save_as_skill
      }
      params["input_data"] = input_data if input_data
      dg_call("flow.into", "data-grout/flow.into", params)
    end

    def route(branches:, payload: nil, cache_ref: nil, else_target: nil, **opts)
      params = { "branches" => branches }
      params["payload"] = payload if payload
      params["cache_ref"] = cache_ref if cache_ref
      params["else"] = else_target if else_target
      dg_call("flow.route", "data-grout/flow.route", @client.send(:normalize_hash, opts).merge(params))
    end

    def request_approval(action:, details: nil, reason: nil, context: nil, **opts)
      params = { "action" => action }.merge(@client.send(:normalize_hash, opts))
      params["details"] = details if details
      params["reason"] = reason if reason
      params["context"] = context if context
      dg_call("flow.request-approval", "data-grout/flow.request-approval", params)
    end

    def request_feedback(missing_fields:, reason:, current_data: nil, suggestions: nil, context: nil, **opts)
      params = { "missing_fields" => missing_fields, "reason" => reason }.merge(@client.send(:normalize_hash, opts))
      params["current_data"] = current_data if current_data
      params["suggestions"] = suggestions if suggestions
      params["context"] = context if context
      dg_call("flow.request-feedback", "data-grout/flow.request-feedback", params)
    end

    def history(limit: 50, offset: 0, status: nil, refractions_only: false, **opts)
      params = { "limit" => limit, "offset" => offset, "refractions_only" => refractions_only }.merge(@client.send(:normalize_hash, opts))
      params["status"] = status if status
      dg_call("inspect.execution-history", "data-grout/inspect.execution-history", params)
    end

    def details(execution_id:)
      params = { "execution_id" => execution_id }
      dg_call("inspect.execution-details", "data-grout/inspect.execution-details", params)
    end

    private

    def dg_call(label, tool_name, params)
      @client.send(:warn_if_not_dg, label)
      @client.send(:ensure_initialized!)
      @client.send(:call_dg_tool, tool_name, params)
    end
  end
end
