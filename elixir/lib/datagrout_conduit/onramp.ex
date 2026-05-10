defmodule DatagroutConduit.Onramp do
  @moduledoc """
  Autonomous agent self-registration (onramp) for DataGrout.

  The onramp flow lets a machine intelligence register itself with DG
  without a human in the loop, using only plain HTTP JSON — no MCP client
  required.

  ## Flow

  1. POST to `/onramp` with agent identity metadata (no auth).
  2. DG returns a short-lived `session_token` (5 minutes).
  3. POST to `/onramp/complete` with `Authorization: Bearer <session_token>`.
  4. DG issues provisional `client_id` + `client_secret` (restricted scopes).

  The two-step handshake stops fire-and-forget scripts from bulk-registering
  without completing the flow.

  ## Example

      alias DatagroutConduit.{Client, Onramp}

      opts = %Onramp.OnrampOptions{
        gateway: "https://app.datagrout.ai",
        agent_name: "my-research-agent",
        agent_type: "claude-sonnet-4-6",
        intended_use: "Summarise documents and extract entities."
      }

      # One-shot: autonomous registration + mTLS bootstrap.
      {:ok, client} = Client.bootstrap_onramp(opts: opts)
  """

  defmodule OnrampOptions do
    @moduledoc "Options for the autonomous agent onramp flow."

    @type t :: %__MODULE__{
            gateway: String.t(),
            agent_name: String.t(),
            agent_type: String.t() | nil,
            intended_use: String.t() | nil,
            access_code: String.t() | nil
          }

    defstruct [
      :gateway,
      :agent_name,
      :agent_type,
      :intended_use,
      :access_code
    ]
  end

  defmodule OnrampCredentials do
    @moduledoc """
    Provisional credentials returned by the DG onramp complete endpoint.

    Store `client_id` and `client_secret` securely — the secret is shown
    exactly once and cannot be recovered after this point.

    `mcp_url` and `rpc_url` are provisioned as part of the identity
    registration step and may be absent from the initial onramp response.
    Use `DatagroutConduit.Client.bootstrap_onramp/1` for the all-in-one flow
    that handles this transparently.
    """

    @type t :: %__MODULE__{
            client_id: String.t(),
            client_secret: String.t(),
            token_url: String.t(),
            scopes: [String.t()],
            expires_in: non_neg_integer(),
            rpc_url: String.t() | nil,
            mcp_url: String.t() | nil
          }

    defstruct [
      :client_id,
      :client_secret,
      :token_url,
      scopes: [],
      expires_in: 0,
      rpc_url: nil,
      mcp_url: nil
    ]
  end

  @doc """
  Perform the onramp handshake and return provisional OAuth credentials.

  Low-level entry point. Most callers should use
  `DatagroutConduit.Client.bootstrap_onramp/1` instead, which chains
  onramp → token exchange → mTLS identity bootstrap in a single call.
  """
  @spec register_only(OnrampOptions.t()) :: {:ok, OnrampCredentials.t()} | {:error, term()}
  def register_only(%OnrampOptions{} = opts) do
    do_register(opts)
  end

  @doc """
  Perform the full onramp handshake and OAuth token exchange.

  Returns the provisional credentials alongside a short-lived access token
  ready for use with `DatagroutConduit.Client.bootstrap_identity/1`.
  """
  @spec register_and_exchange(OnrampOptions.t()) ::
          {:ok, {OnrampCredentials.t(), String.t()}} | {:error, term()}
  def register_and_exchange(%OnrampOptions{} = opts) do
    with {:ok, creds} <- do_register(opts),
         {:ok, token} <- exchange_token(creds) do
      {:ok, {creds, token}}
    end
  end

  @doc false
  @spec exchange_token(OnrampCredentials.t()) :: {:ok, String.t()} | {:error, term()}
  def exchange_token(%OnrampCredentials{} = creds) do
    case Req.post(creds.token_url,
           form: %{
             "grant_type" => "client_credentials",
             "client_id" => creds.client_id,
             "client_secret" => creds.client_secret
           }
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body["access_token"]}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  # --- Private ---

  defp do_register(%OnrampOptions{} = opts) do
    base = String.trim_trailing(opts.gateway, "/")

    body =
      %{"agent_name" => opts.agent_name}
      |> maybe_put("agent_type", opts.agent_type)
      |> maybe_put("intended_use", opts.intended_use)
      |> maybe_put("access_code", opts.access_code)

    case Req.post("#{base}/onramp", json: body) do
      {:ok, %Req.Response{status: status, body: b}} when status in 200..299 ->
        do_complete(base, b["session_token"])

      {:ok, %Req.Response{status: status, body: b}} ->
        {:error, {:onramp_init_rejected, status, b}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp do_complete(base, session_token) do
    case Req.post("#{base}/onramp/complete",
           headers: [{"authorization", "Bearer #{session_token}"}]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok,
         %OnrampCredentials{
           client_id: body["client_id"],
           client_secret: body["client_secret"],
           token_url: body["token_url"],
           scopes: body["scopes"] || [],
           expires_in: body["expires_in"] || 0,
           rpc_url: body["rpc_url"],
           mcp_url: body["mcp_url"]
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:onramp_complete_rejected, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
