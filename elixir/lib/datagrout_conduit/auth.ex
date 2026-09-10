defmodule DatagroutConduit.Auth do
  @moduledoc """
  One place where an `:auth` option becomes a request header.

  Every transport resolves auth on the way out and, for the provider-backed
  grants, invalidates it on a 401 so the next attempt refreshes. Keeping that in
  one module is what lets `client_credentials`, the authorization-code grant and
  a delegated token travel the same path: they differ only in which provider
  answers `get_token`.

  ## Shapes

    * `{:bearer, token}` — a static token
    * `{:api_key, key}`
    * `{:basic, user, pass}`
    * `{:oauth, provider}` — a `DatagroutConduit.OAuth` server
    * `{:authorization_code, provider}` — a `DatagroutConduit.AuthCode.Provider`
    * `{:delegation, provider}` — a `DatagroutConduit.Delegation.Provider`, whose
      RFC 8693 exchange names the user as `sub` and the agent in `act`
  """

  alias DatagroutConduit.{AuthCode, Delegation}

  @typedoc "Auth as the caller configured it, before any token is fetched."
  @type t ::
          nil
          | {:bearer, String.t()}
          | {:api_key, String.t()}
          | {:basic, String.t(), String.t()}
          | {:oauth, GenServer.server()}
          | {:authorization_code, GenServer.server()}
          | {:delegation, GenServer.server()}

  @typedoc """
  Auth with any token already fetched. No provider variants: by this point a
  token has been obtained or the attempt has failed.
  """
  @type resolved ::
          nil
          | {:bearer, String.t()}
          | {:api_key, String.t()}
          | {:basic, String.t(), String.t()}

  @doc """
  Normalize the `:auth` option, starting a provider for an
  authorization-code grant given as a `Grant` or a plain map, or for a
  delegation given as `DatagroutConduit.Delegation.Provider` options.

  A caller who passes a running provider keeps it, which is what they want when
  a rotated refresh token has to be written back.

  Raises `ArgumentError` on a value that cannot become a provider. That is a
  configuration mistake, not a transient failure, and the alternative — carrying
  on unauthenticated — turns a typo into a puzzling 401 much later. Mirrors what
  the Ruby SDK does with the same input.
  """
  @spec normalize(term()) :: t()
  def normalize({:authorization_code, value}) do
    case AuthCode.Provider.from_auth(value) do
      {:ok, provider} -> {:authorization_code, provider}
      :none -> nil
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end

  def normalize({:delegation, value}) do
    case Delegation.Provider.from_auth(value) do
      {:ok, provider} -> {:delegation, provider}
      :none -> nil
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end

  def normalize(other), do: other

  @doc """
  Fetch a token where one is needed, returning auth ready to become a header.

  Returns `{:error, reason}` when a provider cannot produce one, carrying the
  provider's own reason — an `%AuthCode.Error{}`, or whatever
  `DatagroutConduit.OAuth` reported. Callers must not fall back to sending the
  request unauthenticated: the server's 401 says far less than the reason the
  token could not be fetched, and it arrives one round trip later.
  """
  @spec resolve(t()) :: {:ok, resolved()} | {:error, term()}
  def resolve({:oauth, provider}) do
    to_bearer(DatagroutConduit.OAuth.get_token(provider))
  end

  def resolve({:authorization_code, provider}) do
    to_bearer(AuthCode.Provider.get_token(provider))
  end

  def resolve({:delegation, provider}) do
    to_bearer(Delegation.Provider.get_token(provider))
  end

  def resolve(other), do: {:ok, other}

  defp to_bearer({:ok, token}), do: {:ok, {:bearer, token}}
  defp to_bearer({:error, reason}), do: {:error, reason}

  @doc "Force the next `resolve/1` to fetch a new token. Call on a 401."
  @spec invalidate(t()) :: :ok
  def invalidate({:oauth, provider}), do: DatagroutConduit.OAuth.invalidate(provider)
  def invalidate({:authorization_code, provider}), do: AuthCode.Provider.invalidate(provider)
  def invalidate({:delegation, provider}), do: Delegation.Provider.invalidate(provider)
  def invalidate(_), do: :ok

  @doc """
  Whether this auth can recover from a 401 by refreshing.

  A static bearer cannot, so a 401 against one is final and must not be retried.
  """
  @spec provider_backed?(t()) :: boolean()
  def provider_backed?({:oauth, _}), do: true
  def provider_backed?({:authorization_code, _}), do: true
  def provider_backed?({:delegation, _}), do: true
  def provider_backed?(_), do: false

  @doc "Headers for already-resolved auth."
  @spec headers(resolved()) :: [{String.t(), String.t()}]
  def headers({:bearer, token}), do: [{"authorization", "Bearer #{token}"}]
  def headers({:api_key, key}), do: [{"x-api-key", key}]

  def headers({:basic, user, pass}),
    do: [{"authorization", "Basic #{Base.encode64("#{user}:#{pass}")}"}]

  def headers(_), do: []

  @doc """
  Headers for auth that may still need a token fetched.

  Propagates a fetch failure rather than returning empty headers, so a caller
  cannot mistake "could not authenticate" for "no auth configured".
  """
  @spec resolved_headers(t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def resolved_headers(auth) do
    with {:ok, resolved} <- resolve(auth), do: {:ok, headers(resolved)}
  end
end
