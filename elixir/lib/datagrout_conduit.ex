defmodule DatagroutConduit do
  @moduledoc """
  Production-ready MCP client with mTLS, OAuth 2.1, and semantic discovery.

  DataGrout Conduit is a **client** library that connects to remote MCP and
  JSON-RPC servers over HTTP/HTTPS, sends requests, and parses responses.

  ## Quick Start

      {:ok, client} = DatagroutConduit.Client.start_link(
        url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
        auth: {:bearer, "token"}
      )

      {:ok, tools} = DatagroutConduit.Client.list_tools(client)
      {:ok, result} = DatagroutConduit.Client.call_tool(client, "my-tool", %{key: "value"})
  """

  @version "0.1.0"

  @dg_hosts ["datagrout.ai", "datagrout.dev"]
  @dg_ca_url "https://ca.datagrout.ai/ca.pem"
  @dg_substrate_endpoint "https://app.datagrout.ai/api/v1/substrate/identity"

  @doc "Returns the library version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the canonical URL for the DataGrout CA certificate."
  @spec dg_ca_url() :: String.t()
  def dg_ca_url, do: @dg_ca_url

  @doc "Returns the default endpoint for Substrate identity registration."
  @spec dg_substrate_endpoint() :: String.t()
  def dg_substrate_endpoint, do: @dg_substrate_endpoint

  @doc """
  Extracts a `%DatagroutConduit.Types.ToolMeta{}` from a tool result's `_meta` field.

  Returns `%ToolMeta{}` with receipt and credit estimate if present.
  """
  @spec extract_meta(map()) :: DatagroutConduit.Types.ToolMeta.t()
  def extract_meta(%{meta: meta}) when is_map(meta) do
    DatagroutConduit.Types.parse_tool_meta(meta)
  end

  def extract_meta(%DatagroutConduit.Types.ToolResult{meta: meta}) do
    DatagroutConduit.Types.parse_tool_meta(meta)
  end

  def extract_meta(%{"_datagrout" => meta}) when is_map(meta) do
    DatagroutConduit.Types.parse_tool_meta(meta)
  end

  def extract_meta(%{"_meta" => meta}) when is_map(meta) do
    DatagroutConduit.Types.parse_tool_meta(meta)
  end

  def extract_meta(_), do: %DatagroutConduit.Types.ToolMeta{}

  @doc """
  Returns `true` if the given URL points to a DataGrout host
  (`datagrout.ai` or `datagrout.dev`).
  """
  @spec is_dg_url?(String.t()) :: boolean()
  def is_dg_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        Enum.any?(@dg_hosts, fn dg_host ->
          host == dg_host or String.ends_with?(host, "." <> dg_host)
        end)

      _ ->
        false
    end
  end

  def is_dg_url?(_), do: false
end
