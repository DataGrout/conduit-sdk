defmodule DatagroutConduit.Error do
  @moduledoc """
  Structured error types for the Conduit SDK.

  All transports and client operations return `{:error, %DatagroutConduit.Error{}}` for
  typed error conditions (rate limit, auth). Other errors may still be `{:error, term}`.

  ## Example

      case DatagroutConduit.Client.list_tools(client) do
        {:ok, tools} -> tools
        {:error, %DatagroutConduit.Error{type: :rate_limit, retry_after: t}} ->
          Process.sleep(:timer.seconds(String.to_integer(t || "5")))
        {:error, %DatagroutConduit.Error{type: :auth, message: msg}} ->
          raise "Auth failure: \#{msg}"
        {:error, reason} ->
          raise "Unexpected error: \#{inspect(reason)}"
      end
  """

  defexception [:type, :message, :code, :retry_after]

  @type error_type ::
          :not_initialized
          | :rate_limit
          | :auth
          | :network
          | :protocol
          | :timeout
          | :invalid_config
          | :server
          | :other

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          code: integer() | nil,
          retry_after: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg || "Unknown Conduit error"

  @doc """
  Returns an error indicating the client has not been initialized.

  Used when a call is attempted before `start_link/1` succeeds.
  """
  @spec not_initialized(String.t()) :: t()
  def not_initialized(msg \\ "Client not initialized") do
    %__MODULE__{type: :not_initialized, message: msg}
  end

  @doc """
  Returns a rate-limit error with an optional `Retry-After` value from the server.

  The `retry_after` value, when present, is the raw string value of the
  `Retry-After` HTTP response header (e.g. `"30"` for 30 seconds).
  """
  @spec rate_limit(String.t(), String.t() | nil) :: t()
  def rate_limit(msg, retry_after \\ nil) do
    %__MODULE__{type: :rate_limit, message: msg, retry_after: retry_after}
  end

  @doc "Returns an authentication error (HTTP 401 or token rejection)."
  @spec auth(String.t()) :: t()
  def auth(msg) do
    %__MODULE__{type: :auth, message: msg}
  end

  @doc "Returns a network-layer error (connection refused, DNS failure, etc.)."
  @spec network(String.t()) :: t()
  def network(msg) do
    %__MODULE__{type: :network, message: msg}
  end

  @doc "Returns a server-side error with an HTTP status code."
  @spec server(String.t(), integer()) :: t()
  def server(msg, code) do
    %__MODULE__{type: :server, message: msg, code: code}
  end

  @doc "Returns a configuration error raised during client setup."
  @spec invalid_config(String.t()) :: t()
  def invalid_config(msg) do
    %__MODULE__{type: :invalid_config, message: msg}
  end
end
