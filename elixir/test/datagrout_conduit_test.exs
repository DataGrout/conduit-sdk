defmodule DatagroutConduitTest do
  use ExUnit.Case, async: true

  describe "version/0" do
    test "returns a semver string" do
      version = DatagroutConduit.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+$/
    end
  end

  describe "is_dg_url?/1" do
    test "returns true for datagrout.ai URLs" do
      assert DatagroutConduit.is_dg_url?("https://gateway.datagrout.ai/servers/123/mcp")
      assert DatagroutConduit.is_dg_url?("https://app.datagrout.ai")
      assert DatagroutConduit.is_dg_url?("https://datagrout.ai")
    end

    test "returns true for datagrout.dev URLs" do
      assert DatagroutConduit.is_dg_url?("https://gateway.datagrout.dev/servers/123/mcp")
      assert DatagroutConduit.is_dg_url?("https://app.datagrout.dev")
    end

    test "returns false for non-DG URLs" do
      refute DatagroutConduit.is_dg_url?("https://example.com/mcp")
      refute DatagroutConduit.is_dg_url?("https://notdatagrout.ai/mcp")
      refute DatagroutConduit.is_dg_url?("https://datagrout.com")
    end

    test "returns false for non-string inputs" do
      refute DatagroutConduit.is_dg_url?(nil)
      refute DatagroutConduit.is_dg_url?(42)
    end
  end

  describe "extract_meta/1" do
    test "extracts receipt from _meta key" do
      result = %{
        "_meta" => %{
          "receipt" => %{
            "receipt_id" => "rcpt-1",
            "actual_credits" => 0.5
          }
        }
      }

      meta = DatagroutConduit.extract_meta(result)
      assert meta.receipt.receipt_id == "rcpt-1"
      assert meta.receipt.actual_credits == 0.5
    end

    test "extracts receipt from _datagrout key" do
      result = %{
        "_datagrout" => %{
          "receipt" => %{
            "receipt_id" => "rcpt-2",
            "actual_credits" => 1.5,
            "net_credits" => 1.2
          }
        }
      }

      meta = DatagroutConduit.extract_meta(result)
      assert meta.receipt.receipt_id == "rcpt-2"
      assert meta.receipt.actual_credits == 1.5
      assert meta.receipt.net_credits == 1.2
    end

    test "prefers _datagrout over _meta" do
      result = %{
        "_datagrout" => %{
          "receipt" => %{"receipt_id" => "from-datagrout"}
        },
        "_meta" => %{
          "receipt" => %{"receipt_id" => "from-meta"}
        }
      }

      meta = DatagroutConduit.extract_meta(result)
      assert meta.receipt.receipt_id == "from-datagrout"
    end

    test "extracts from ToolResult struct" do
      result = %DatagroutConduit.Types.ToolResult{
        content: [],
        meta: %{
          "receipt" => %{"actual_credits" => 1.0}
        }
      }

      meta = DatagroutConduit.extract_meta(result)
      assert meta.receipt.actual_credits == 1.0
    end

    test "returns empty ToolMeta for nil input" do
      meta = DatagroutConduit.extract_meta(nil)
      assert meta == %DatagroutConduit.Types.ToolMeta{}
    end

    test "extracts credit_estimate" do
      result = %{
        "_meta" => %{
          "credit_estimate" => %{
            "estimated_total" => 2.5,
            "net_total" => 2.0
          }
        }
      }

      meta = DatagroutConduit.extract_meta(result)
      assert meta.credit_estimate.estimated_total == 2.5
      assert meta.credit_estimate.net_total == 2.0
    end
  end
end
