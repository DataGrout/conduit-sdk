# frozen_string_literal: true

require_relative "test_helper"

class DatagroutConduitTest < Minitest::Test
  def test_version
    refute_nil DatagroutConduit::VERSION
    assert_equal "0.1.0", DatagroutConduit::VERSION
  end

  def test_dg_url_recognizes_datagrout_ai
    assert DatagroutConduit.dg_url?("https://gateway.datagrout.ai/servers/abc/mcp")
    assert DatagroutConduit.dg_url?("https://app.datagrout.ai/servers/abc/mcp")
  end

  def test_dg_url_recognizes_datagrout_dev
    assert DatagroutConduit.dg_url?("https://dev.datagrout.dev/servers/abc/mcp")
  end

  def test_dg_url_rejects_other_urls
    refute DatagroutConduit.dg_url?("https://example.com/mcp")
    refute DatagroutConduit.dg_url?("https://my-server.io/jsonrpc")
  end

  def test_dg_url_handles_nil
    refute DatagroutConduit.dg_url?(nil)
  end

  def test_extract_meta_with_datagrout_key
    result = {
      "_datagrout" => {
        "receipt" => {
          "receipt_id" => "rcp_abc123",
          "timestamp" => "2026-01-15T10:00:00Z",
          "estimated_credits" => 2.0,
          "actual_credits" => 1.5,
          "net_credits" => 1.5,
          "savings" => 0.5,
          "savings_bonus" => 0.0,
          "breakdown" => { "base" => 1.0, "semantic_guard" => 0.5 },
          "byok" => { "enabled" => false, "discount_applied" => 0.0, "discount_rate" => 0.0 }
        },
        "credit_estimate" => {
          "estimated_total" => 2.0,
          "actual_total" => 1.5,
          "net_total" => 1.5,
          "breakdown" => {}
        }
      }
    }

    meta = DatagroutConduit.extract_meta(result)
    refute_nil meta
    assert_equal "rcp_abc123", meta.receipt.receipt_id
    assert_in_delta 1.5, meta.receipt.net_credits
    assert_in_delta 0.5, meta.receipt.savings
    refute meta.receipt.byok.enabled

    refute_nil meta.credit_estimate
    assert_in_delta 2.0, meta.credit_estimate.estimated_total
  end

  def test_extract_meta_with_nested_meta_datagrout
    result = {
      "_meta" => {
        "datagrout" => {
          "receipt" => {
            "receipt_id" => "rcp_nested",
            "timestamp" => "2026-01-15T10:00:00Z",
            "estimated_credits" => 3.0,
            "actual_credits" => 2.5,
            "net_credits" => 2.5,
            "savings" => 0.5,
            "savings_bonus" => 0.0,
            "breakdown" => {}
          }
        }
      }
    }

    meta = DatagroutConduit.extract_meta(result)
    refute_nil meta
    assert_equal "rcp_nested", meta.receipt.receipt_id
  end

  def test_extract_meta_with_nested_meta_datagrout_symbol_keys
    result = {
      _meta: {
        datagrout: {
          "receipt" => {
            "receipt_id" => "rcp_nested_sym",
            "timestamp" => "2026-01-15T10:00:00Z",
            "estimated_credits" => 1.0,
            "actual_credits" => 1.0,
            "net_credits" => 1.0,
            "savings" => 0.0,
            "savings_bonus" => 0.0,
            "breakdown" => {}
          }
        }
      }
    }

    meta = DatagroutConduit.extract_meta(result)
    refute_nil meta
    assert_equal "rcp_nested_sym", meta.receipt.receipt_id
  end

  def test_extract_meta_with_meta_key_fallback
    result = {
      "_meta" => {
        "receipt" => {
          "receipt_id" => "rcp_legacy",
          "timestamp" => "2026-01-15T10:00:00Z",
          "estimated_credits" => 1.0,
          "actual_credits" => 1.0,
          "net_credits" => 1.0,
          "savings" => 0.0,
          "savings_bonus" => 0.0,
          "breakdown" => {}
        }
      }
    }

    meta = DatagroutConduit.extract_meta(result)
    refute_nil meta
    assert_equal "rcp_legacy", meta.receipt.receipt_id
  end

  def test_extract_meta_returns_nil_for_no_meta
    assert_nil DatagroutConduit.extract_meta({})
    assert_nil DatagroutConduit.extract_meta({ "value" => 42 })
    assert_nil DatagroutConduit.extract_meta(nil)
  end

  def test_extract_meta_with_symbol_keys
    result = {
      _datagrout: {
        "receipt" => {
          "receipt_id" => "rcp_sym",
          "timestamp" => "2026-01-15T10:00:00Z",
          "estimated_credits" => 1.0,
          "actual_credits" => 1.0,
          "net_credits" => 1.0,
          "savings" => 0.0,
          "savings_bonus" => 0.0,
          "breakdown" => {}
        }
      }
    }

    meta = DatagroutConduit.extract_meta(result)
    refute_nil meta
    assert_equal "rcp_sym", meta.receipt.receipt_id
  end

  def test_tool_from_hash_with_string_keys
    tool = DatagroutConduit::Tool.from_hash(
      "name" => "my-tool",
      "description" => "Does stuff",
      "inputSchema" => { "type" => "object" }
    )
    assert_equal "my-tool", tool.name
    assert_equal "Does stuff", tool.description
    assert_equal({ "type" => "object" }, tool.input_schema)
  end

  def test_tool_from_hash_with_symbol_keys
    tool = DatagroutConduit::Tool.from_hash(
      name: "my-tool",
      description: "Does stuff"
    )
    assert_equal "my-tool", tool.name
  end

  def test_receipt_from_hash
    receipt = DatagroutConduit::Receipt.from_hash(
      "receipt_id" => "rcp_test",
      "timestamp" => "2026-01-01T00:00:00Z",
      "estimated_credits" => 5.0,
      "actual_credits" => 4.0,
      "net_credits" => 3.5,
      "savings" => 1.5,
      "savings_bonus" => 0.0,
      "balance_before" => 100.0,
      "balance_after" => 96.5,
      "breakdown" => { "base" => 3.0 },
      "byok" => { "enabled" => true, "discount_applied" => 0.5, "discount_rate" => 0.1 }
    )

    assert_equal "rcp_test", receipt.receipt_id
    assert_in_delta 3.5, receipt.net_credits
    assert_in_delta 96.5, receipt.balance_after
    assert receipt.byok.enabled
    assert_in_delta 0.5, receipt.byok.discount_applied
  end

  def test_discover_result_from_hash
    result = DatagroutConduit::DiscoverResult.from_hash(
      "tools" => [
        { "name" => "tool-a", "score" => 0.95, "description" => "A tool" },
        { "name" => "tool-b", "score" => 0.80 }
      ],
      "query" => "find invoices",
      "total" => 2
    )

    assert_equal 2, result.total
    assert_equal "find invoices", result.query
    assert_equal 2, result.tools.size
    assert_in_delta 0.95, result.tools.first.score
  end

  def test_guide_state_from_hash
    state = DatagroutConduit::GuideState.from_hash(
      "sessionId" => "sess_123",
      "status" => "in_progress",
      "step" => 2,
      "options" => [
        { "id" => "opt_a", "label" => "Option A", "description" => "First choice" }
      ]
    )

    assert_equal "sess_123", state.session_id
    assert_equal "in_progress", state.status
    assert_equal 2, state.step
    assert_equal 1, state.options.size
    assert_equal "opt_a", state.options.first.id
  end
end
