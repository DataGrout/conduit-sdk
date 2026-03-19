# frozen_string_literal: true

module DatagroutConduit
  class LogicNamespace
    def initialize(client)
      @client = client
    end

    def remember(statement: nil, facts: nil, tag: nil)
      raise ArgumentError, "must provide statement or facts" unless statement || facts

      params = {}
      params["statement"] = statement if statement
      params["facts"] = facts if facts
      params["tag"] = tag if tag
      dg_call("logic.remember", params)
    end

    def query(question: nil, patterns: nil, limit: nil)
      raise ArgumentError, "must provide question or patterns" unless question || patterns

      params = {}
      params["question"] = question if question
      params["patterns"] = patterns if patterns
      params["limit"] = limit if limit
      dg_call("logic.query", params)
    end

    def forget(handles: nil, pattern: nil)
      raise ArgumentError, "must provide handles or pattern" unless handles || pattern

      params = {}
      params["handles"] = handles if handles
      params["pattern"] = pattern if pattern
      dg_call("logic.forget", params)
    end

    def constrain(rule:, tag: nil)
      params = { "rule" => rule }
      params["tag"] = tag if tag
      dg_call("logic.constrain", params)
    end

    def reflect(entity: nil, summary_only: false)
      params = { "summary_only" => summary_only }
      params["entity"] = entity if entity
      dg_call("logic.reflect", params)
    end

    def hydrate(params = {})
      dg_call("logic.hydrate", params)
    end

    def export_cell(params = {})
      dg_call("logic.export", params)
    end

    def import_cell(params = {})
      dg_call("logic.import", params)
    end

    def tabulate(params = {})
      dg_call("logic.tabulate", params)
    end

    def worlds(params = {})
      dg_call("logic.worlds", params)
    end

    private

    def dg_call(short_name, params)
      @client.send(:warn_if_not_dg, short_name)
      @client.send(:ensure_initialized!)
      @client.send(:call_dg_tool, "data-grout/#{short_name}", params)
    end
  end
end
