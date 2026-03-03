defmodule DatagroutConduit.Transport.Behaviour do
  @moduledoc """
  Behaviour for MCP/JSONRPC transport implementations.

  Both transports send HTTP POST requests to the remote server.
  The transport is responsible for framing and parsing the protocol envelope.
  """

  @type connect_opts :: %{
          url: String.t(),
          identity: DatagroutConduit.Identity.t() | nil,
          auth: DatagroutConduit.Client.auth() | nil
        }

  @type request_opts :: %{
          method: String.t(),
          params: map(),
          id: String.t() | integer()
        }

  @doc "Build a configured Req client for the given endpoint."
  @callback connect(connect_opts()) :: {:ok, Req.Request.t()} | {:error, term()}

  @doc """
  Send a request and return the parsed result body.

  MCP transport may return `{:ok, result, session_id}` with the
  `mcp-session-id` response header. JSON-RPC transport returns `{:ok, result}`.
  """
  @callback send_request(Req.Request.t(), request_opts()) ::
              {:ok, map()} | {:ok, map(), String.t() | nil} | {:error, term()}
end
