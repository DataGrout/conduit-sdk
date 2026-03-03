# frozen_string_literal: true

module DatagroutConduit
  Tool = Struct.new(:name, :description, :input_schema, :annotations, keyword_init: true) do
    def self.from_hash(hash)
      hash = normalize_keys(hash)
      new(
        name: hash[:name],
        description: hash[:description],
        input_schema: hash[:input_schema] || hash[:inputschema],
        annotations: hash[:annotations]
      )
    end

    def self.normalize_keys(hash)
      hash.each_with_object({}) do |(k, v), memo|
        memo[k.to_s.downcase.to_sym] = v
      end
    end
  end

  Byok = Struct.new(:enabled, :discount_applied, :discount_rate, keyword_init: true) do
    def self.from_hash(hash)
      return new(enabled: false, discount_applied: 0.0, discount_rate: 0.0) if hash.nil?

      hash = hash.transform_keys(&:to_s)
      new(
        enabled: hash["enabled"] || false,
        discount_applied: (hash["discount_applied"] || 0.0).to_f,
        discount_rate: (hash["discount_rate"] || 0.0).to_f
      )
    end
  end

  Receipt = Struct.new(
    :receipt_id, :transaction_id, :timestamp,
    :estimated_credits, :actual_credits, :net_credits,
    :savings, :savings_bonus,
    :balance_before, :balance_after,
    :breakdown, :byok,
    keyword_init: true
  ) do
    def self.from_hash(hash)
      return nil if hash.nil?

      hash = hash.transform_keys(&:to_s)
      new(
        receipt_id: hash["receipt_id"],
        transaction_id: hash["transaction_id"],
        timestamp: hash["timestamp"],
        estimated_credits: hash["estimated_credits"]&.to_f,
        actual_credits: hash["actual_credits"]&.to_f,
        net_credits: hash["net_credits"]&.to_f,
        savings: (hash["savings"] || 0.0).to_f,
        savings_bonus: (hash["savings_bonus"] || 0.0).to_f,
        balance_before: hash["balance_before"]&.to_f,
        balance_after: hash["balance_after"]&.to_f,
        breakdown: hash["breakdown"] || {},
        byok: Byok.from_hash(hash["byok"])
      )
    end
  end

  CreditEstimate = Struct.new(
    :estimated_total, :actual_total, :net_total, :breakdown,
    keyword_init: true
  ) do
    def self.from_hash(hash)
      return nil if hash.nil?

      hash = hash.transform_keys(&:to_s)
      new(
        estimated_total: hash["estimated_total"]&.to_f,
        actual_total: hash["actual_total"]&.to_f,
        net_total: hash["net_total"]&.to_f,
        breakdown: hash["breakdown"] || {}
      )
    end
  end

  ToolMeta = Struct.new(:receipt, :credit_estimate, keyword_init: true) do
    def self.from_hash(hash)
      return nil if hash.nil?

      hash = hash.transform_keys(&:to_s)
      new(
        receipt: Receipt.from_hash(hash["receipt"]),
        credit_estimate: CreditEstimate.from_hash(hash["credit_estimate"])
      )
    end
  end

  DiscoveredTool = Struct.new(:name, :description, :input_schema, :score, :integration, :server, keyword_init: true) do
    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_s)
      # DG returns "tool_name" (not "name") and "input_contract" (not "input_schema")
      new(
        name: hash["tool_name"] || hash["name"],
        description: hash["description"],
        input_schema: hash["input_contract"] || hash["input_schema"] || hash["inputSchema"],
        score: hash["score"]&.to_f,
        integration: hash["integration"],
        server: hash["server"]
      )
    end
  end

  DiscoverResult = Struct.new(:tools, :query, :total, keyword_init: true) do
    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_s)
      # DG returns "results" (not "tools") and "goal_used" (not "query")
      tools_raw = hash["results"] || hash["tools"] || []
      tools = tools_raw.map { |t| DiscoveredTool.from_hash(t) }
      new(
        tools: tools,
        query: hash["goal_used"] || hash["query"],
        total: hash["total"] || tools.size
      )
    end
  end

  GuideOption = Struct.new(:id, :label, :description, keyword_init: true) do
    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_s)
      new(id: hash["id"], label: hash["label"], description: hash["description"])
    end
  end

  GuideState = Struct.new(:session_id, :status, :options, :result, :step, keyword_init: true) do
    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_s)
      opts = hash["options"]&.map { |o| GuideOption.from_hash(o) }
      new(
        session_id: hash["session_id"] || hash["sessionId"],
        status: hash["status"],
        options: opts,
        result: hash["result"],
        step: hash["step"]
      )
    end
  end
end
