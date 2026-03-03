defmodule DatagroutConduit.OAuth do
  @moduledoc """
  OAuth 2.1 token provider using client credentials flow.

  Manages token lifecycle: fetches tokens from the authorization server's
  token endpoint, caches them, and refreshes 60 seconds before expiry.

  ## Token Endpoint Discovery

  If not provided, the token endpoint is derived from the MCP URL:

      https://gateway.datagrout.ai/servers/{id}/mcp
      → https://gateway.datagrout.ai/servers/{id}/oauth/token

  ## Usage

      {:ok, provider} = DatagroutConduit.OAuth.start_link(
        client_id: "my-client-id",
        client_secret: "my-secret",
        token_endpoint: "https://auth.example.com/oauth/token"
      )

      {:ok, token} = DatagroutConduit.OAuth.get_token(provider)
  """

  use GenServer

  require Logger

  @refresh_buffer_secs 60

  defstruct [
    :client_id,
    :client_secret,
    :token_endpoint,
    :scope,
    :cached_token,
    :expires_at
  ]

  @type t :: %__MODULE__{}

  # --- Public API ---

  @doc """
  Starts the OAuth token provider.

  ## Options

    * `:client_id` - OAuth client ID (required)
    * `:client_secret` - OAuth client secret (required)
    * `:token_endpoint` - Full URL to the token endpoint (required)
    * `:scope` - OAuth scope (optional)
    * `:name` - GenServer registration name (optional)
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns a valid access token, fetching or refreshing as needed.
  """
  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_token(provider) do
    GenServer.call(provider, :get_token, 30_000)
  end

  @doc """
  Invalidates the cached token, forcing a fresh fetch on the next `get_token` call.
  """
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(provider) do
    GenServer.cast(provider, :invalidate)
  end

  @doc """
  Derives an OAuth token endpoint from an MCP URL.

  Replaces the trailing `/mcp` or `/jsonrpc` with `/oauth/token`.
  """
  @spec derive_token_endpoint(String.t()) :: String.t()
  def derive_token_endpoint(url) do
    url
    |> String.replace(~r{/(mcp|jsonrpc)/?$}, "/oauth/token")
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      token_endpoint: Keyword.fetch!(opts, :token_endpoint),
      scope: Keyword.get(opts, :scope)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    if token_valid?(state) do
      {:reply, {:ok, state.cached_token}, state}
    else
      case fetch_token(state) do
        {:ok, token, expires_in} ->
          expires_at = System.monotonic_time(:second) + expires_in - @refresh_buffer_secs
          new_state = %{state | cached_token: token, expires_at: expires_at}
          {:reply, {:ok, token}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_cast(:invalidate, state) do
    {:noreply, %{state | cached_token: nil, expires_at: nil}}
  end

  # --- Internal ---

  defp token_valid?(%{cached_token: nil}), do: false

  defp token_valid?(%{expires_at: expires_at}) do
    System.monotonic_time(:second) < expires_at
  end

  defp fetch_token(state) do
    body =
      %{
        "grant_type" => "client_credentials",
        "client_id" => state.client_id,
        "client_secret" => state.client_secret
      }
      |> maybe_add_scope(state.scope)

    case Req.post(state.token_endpoint, form: body) do
      {:ok, %Req.Response{status: 200, body: resp}} ->
        token = resp["access_token"]
        expires_in = resp["expires_in"] || 3600

        if token do
          {:ok, token, expires_in}
        else
          {:error, {:invalid_response, resp}}
        end

      {:ok, %Req.Response{status: status, body: resp}} ->
        Logger.error("OAuth token fetch failed: status=#{status} body=#{inspect(resp)}")
        {:error, {:token_error, status, resp}}

      {:error, reason} ->
        Logger.error("OAuth token fetch error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}
    end
  end

  defp maybe_add_scope(body, nil), do: body
  defp maybe_add_scope(body, scope), do: Map.put(body, "scope", scope)
end
