defmodule DatagroutConduit.Types do
  @moduledoc """
  Type definitions for MCP protocol objects and DataGrout extensions.
  """

  defmodule Tool do
    @moduledoc "An MCP tool descriptor."
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            annotations: map() | nil,
            input_schema: map()
          }
    defstruct [:name, :description, :annotations, input_schema: %{}]
  end

  defmodule Resource do
    @moduledoc "An MCP resource descriptor."
    @type t :: %__MODULE__{
            uri: String.t(),
            name: String.t(),
            description: String.t() | nil,
            mime_type: String.t() | nil
          }
    defstruct [:uri, :name, :description, :mime_type]
  end

  defmodule ResourceContent do
    @moduledoc "Content returned from reading a resource."
    @type t :: %__MODULE__{
            uri: String.t(),
            mime_type: String.t() | nil,
            text: String.t() | nil,
            blob: binary() | nil
          }
    defstruct [:uri, :mime_type, :text, :blob]
  end

  defmodule Prompt do
    @moduledoc "An MCP prompt descriptor."
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            arguments: [map()]
          }
    defstruct [:name, :description, arguments: []]
  end

  defmodule PromptMessage do
    @moduledoc "A message returned from getting a prompt."
    @type t :: %__MODULE__{role: String.t(), content: map()}
    defstruct [:role, :content]
  end

  defmodule ToolResult do
    @moduledoc "Result from calling a tool."
    @type t :: %__MODULE__{
            content: [map()],
            is_error: boolean(),
            meta: map()
          }
    defstruct [content: [], is_error: false, meta: %{}]
  end

  defmodule Byok do
    @moduledoc "Bring-your-own-key info attached to a receipt."
    @type t :: %__MODULE__{
            enabled: boolean(),
            discount_applied: boolean(),
            discount_rate: float() | nil
          }
    defstruct [enabled: false, discount_applied: false, discount_rate: nil]
  end

  defmodule Receipt do
    @moduledoc "A credit receipt from a DG tool call."
    @type t :: %__MODULE__{
            receipt_id: String.t() | nil,
            transaction_id: String.t() | nil,
            timestamp: String.t() | nil,
            estimated_credits: float() | nil,
            actual_credits: float() | nil,
            net_credits: float() | nil,
            savings: float() | nil,
            savings_bonus: float() | nil,
            balance_before: float() | nil,
            balance_after: float() | nil,
            breakdown: map() | nil,
            byok: Byok.t() | nil
          }
    defstruct [:receipt_id, :transaction_id, :timestamp, :estimated_credits, :actual_credits,
               :net_credits, :savings, :savings_bonus, :balance_before, :balance_after,
               :breakdown, :byok]
  end

  defmodule CreditEstimate do
    @moduledoc "A cost estimate before executing a tool."
    @type t :: %__MODULE__{
            estimated_total: float() | nil,
            actual_total: float() | nil,
            net_total: float() | nil,
            breakdown: map() | nil
          }
    defstruct [:estimated_total, :actual_total, :net_total, :breakdown]
  end

  defmodule ToolMeta do
    @moduledoc "Extracted metadata from a tool result (_meta / _datagrout field)."
    @type t :: %__MODULE__{
            receipt: Receipt.t() | nil,
            credit_estimate: CreditEstimate.t() | nil,
            raw: map()
          }
    defstruct [:receipt, :credit_estimate, raw: %{}]
  end

  defmodule DiscoveredTool do
    @moduledoc "A tool returned from semantic discovery with its score."
    @type t :: %__MODULE__{
            tool: Tool.t() | nil,
            score: float(),
            integration: String.t() | nil,
            server: String.t() | nil
          }
    defstruct [:tool, :integration, :server, score: 0.0]
  end

  defmodule DiscoverResult do
    @moduledoc "Result from semantic discovery."
    @type t :: %__MODULE__{
            tools: [DiscoveredTool.t()],
            query: String.t() | nil,
            total: integer()
          }
    defstruct [tools: [], query: nil, total: 0]
  end

  defmodule GuideOption do
    @moduledoc "An option presented during guided execution."
    @type t :: %__MODULE__{
            tool_name: String.t(),
            description: String.t() | nil,
            arguments: map()
          }
    defstruct [:tool_name, :description, arguments: %{}]
  end

  defmodule GuideState do
    @moduledoc "State of a guided execution session."
    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            status: String.t() | nil,
            options: [GuideOption.t()],
            result: map() | nil,
            step: integer() | nil
          }
    defstruct [:session_id, :status, :result, :step, options: []]
  end

  defmodule FlowResult do
    @moduledoc "Result from executing a guided plan."
    @type t :: %__MODULE__{
            results: [map()],
            session_id: String.t() | nil
          }
    defstruct [:session_id, results: []]
  end

  defmodule PrismFocusResult do
    @moduledoc "Result from prism focus."
    @type t :: %__MODULE__{
            output: term(),
            source_type: String.t() | nil,
            target_type: String.t() | nil
          }
    defstruct [:output, :source_type, :target_type]
  end

  @doc "Parse a raw map into a Tool struct."
  @spec parse_tool(map()) :: Tool.t()
  def parse_tool(raw) when is_map(raw) do
    %Tool{
      name: raw["name"],
      description: raw["description"],
      annotations: raw["annotations"],
      input_schema: raw["inputSchema"] || raw["input_schema"] || %{}
    }
  end

  @doc "Parse a raw map into a Resource struct."
  @spec parse_resource(map()) :: Resource.t()
  def parse_resource(raw) when is_map(raw) do
    %Resource{
      uri: raw["uri"],
      name: raw["name"],
      description: raw["description"],
      mime_type: raw["mimeType"] || raw["mime_type"]
    }
  end

  @doc "Parse a raw map into a ResourceContent struct."
  @spec parse_resource_content(map()) :: ResourceContent.t()
  def parse_resource_content(raw) when is_map(raw) do
    %ResourceContent{
      uri: raw["uri"],
      mime_type: raw["mimeType"] || raw["mime_type"],
      text: raw["text"],
      blob: raw["blob"]
    }
  end

  @doc "Parse a raw map into a Prompt struct."
  @spec parse_prompt(map()) :: Prompt.t()
  def parse_prompt(raw) when is_map(raw) do
    %Prompt{
      name: raw["name"],
      description: raw["description"],
      arguments: raw["arguments"] || []
    }
  end

  @doc "Parse a raw map into a PromptMessage struct."
  @spec parse_prompt_message(map()) :: PromptMessage.t()
  def parse_prompt_message(raw) when is_map(raw) do
    %PromptMessage{
      role: raw["role"],
      content: raw["content"]
    }
  end

  @doc "Parse a raw map into a Byok struct."
  @spec parse_byok(map()) :: Byok.t()
  def parse_byok(raw) when is_map(raw) do
    %Byok{
      enabled: raw["enabled"] == true,
      discount_applied: raw["discount_applied"] == true || raw["discountApplied"] == true,
      discount_rate: to_float_or_nil(raw["discount_rate"] || raw["discountRate"])
    }
  end

  def parse_byok(_), do: nil

  @doc "Parse a raw map into a Receipt struct."
  @spec parse_receipt(map()) :: Receipt.t()
  def parse_receipt(raw) when is_map(raw) do
    %Receipt{
      receipt_id: raw["receipt_id"] || raw["receiptId"],
      transaction_id: raw["transaction_id"] || raw["transactionId"],
      timestamp: raw["timestamp"],
      estimated_credits: to_float_or_nil(raw["estimated_credits"] || raw["estimatedCredits"]),
      actual_credits: to_float_or_nil(raw["actual_credits"] || raw["actualCredits"]),
      net_credits: to_float_or_nil(raw["net_credits"] || raw["netCredits"]),
      savings: to_float_or_nil(raw["savings"]),
      savings_bonus: to_float_or_nil(raw["savings_bonus"] || raw["savingsBonus"]),
      balance_before: to_float_or_nil(raw["balance_before"] || raw["balanceBefore"]),
      balance_after: to_float_or_nil(raw["balance_after"] || raw["balanceAfter"]),
      breakdown: raw["breakdown"],
      byok: if(raw["byok"], do: parse_byok(raw["byok"]))
    }
  end

  @doc "Parse a raw map into a CreditEstimate struct."
  @spec parse_credit_estimate(map()) :: CreditEstimate.t()
  def parse_credit_estimate(raw) when is_map(raw) do
    %CreditEstimate{
      estimated_total: to_float_or_nil(raw["estimated_total"] || raw["estimatedTotal"]),
      actual_total: to_float_or_nil(raw["actual_total"] || raw["actualTotal"]),
      net_total: to_float_or_nil(raw["net_total"] || raw["netTotal"]),
      breakdown: raw["breakdown"]
    }
  end

  @doc "Parse a raw map into a DiscoveredTool struct."
  @spec parse_discovered_tool(map()) :: DiscoveredTool.t()
  def parse_discovered_tool(raw) when is_map(raw) do
    # DG returns flat items: "tool_name", "description", "input_contract", "score", etc.
    # Also support the legacy nested "tool" map format for backwards compat.
    tool_data = raw["tool"]

    tool =
      cond do
        is_binary(raw["tool_name"]) ->
          %Tool{
            name: raw["tool_name"],
            description: raw["description"] || "",
            input_schema: raw["input_contract"] || %{}
          }

        is_map(tool_data) ->
          parse_tool(tool_data)

        true ->
          nil
      end

    %DiscoveredTool{
      tool: tool,
      score: to_float(raw["score"] || 0),
      integration: raw["integration"],
      server: raw["server"]
    }
  end

  @doc "Parse a raw map into a DiscoverResult struct."
  @spec parse_discover_result(map()) :: DiscoverResult.t()
  def parse_discover_result(raw) when is_map(raw) do
    # DG returns "results" (not "tools") and "goal_used" (not "query").
    tools_raw = raw["results"] || raw["tools"] || []
    %DiscoverResult{
      tools: Enum.map(tools_raw, &parse_discovered_tool/1),
      query: raw["goal_used"] || raw["query"],
      total: length(tools_raw)
    }
  end

  @doc "Parse a raw map into a GuideOption struct."
  @spec parse_guide_option(map()) :: GuideOption.t()
  def parse_guide_option(raw) when is_map(raw) do
    %GuideOption{
      tool_name: raw["tool_name"] || raw["toolName"],
      description: raw["description"],
      arguments: raw["arguments"] || %{}
    }
  end

  @doc "Parse a raw map into a GuideState struct."
  @spec parse_guide_state(map()) :: GuideState.t()
  def parse_guide_state(raw) when is_map(raw) do
    %GuideState{
      session_id: raw["session_id"] || raw["sessionId"],
      status: raw["status"],
      options: Enum.map(raw["options"] || [], &parse_guide_option/1),
      result: raw["result"],
      step: raw["step"]
    }
  end

  @doc "Parse _meta / _datagrout from a tool result into a ToolMeta struct."
  @spec parse_tool_meta(map()) :: ToolMeta.t()
  def parse_tool_meta(meta) when is_map(meta) do
    %ToolMeta{
      receipt: if(meta["receipt"], do: parse_receipt(meta["receipt"])),
      credit_estimate: if(meta["credit_estimate"] || meta["creditEstimate"],
        do: parse_credit_estimate(meta["credit_estimate"] || meta["creditEstimate"])),
      raw: meta
    }
  end

  def parse_tool_meta(_), do: %ToolMeta{}

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_binary(v), do: String.to_float(v)
  defp to_float(_), do: 0.0

  defp to_float_or_nil(nil), do: nil
  defp to_float_or_nil(v), do: to_float(v)
end
