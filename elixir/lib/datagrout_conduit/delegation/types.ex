defmodule DatagroutConduit.Delegation.TokenType do
  @moduledoc """
  An RFC 8693 §3 token type identifier.

  Modelled as an atom for the five types the RFC names, and `{:other, urn}` for
  anything else — a URN this SDK does not know round-trips rather than failing,
  which is what lets an authorization server add one without breaking clients.

  The URN is the wire form, and it is the same string in every conduit SDK; the
  atoms are a local convenience.

      iex> DatagroutConduit.Delegation.TokenType.to_urn(:jwt)
      "urn:ietf:params:oauth:token-type:jwt"

      iex> DatagroutConduit.Delegation.TokenType.from_urn("urn:example:custom")
      {:other, "urn:example:custom"}
  """

  @type t ::
          :access_token
          | :jwt
          | :id_token
          | :refresh_token
          | :saml2
          | {:other, String.t()}

  # Ordered as the contract fixture lists them, so a reader can compare the two.
  @urns %{
    access_token: "urn:ietf:params:oauth:token-type:access_token",
    jwt: "urn:ietf:params:oauth:token-type:jwt",
    id_token: "urn:ietf:params:oauth:token-type:id_token",
    refresh_token: "urn:ietf:params:oauth:token-type:refresh_token",
    saml2: "urn:ietf:params:oauth:token-type:saml2"
  }

  @by_urn Map.new(@urns, fn {name, urn} -> {urn, name} end)

  @doc "The five types this SDK names, and their URNs."
  @spec urns() :: %{atom() => String.t()}
  def urns, do: @urns

  @doc "The URN sent on the wire."
  @spec to_urn(t()) :: String.t()
  def to_urn({:other, urn}) when is_binary(urn), do: urn
  def to_urn(name) when is_map_key(@urns, name), do: Map.fetch!(@urns, name)

  @doc "Parse a URN. Unknown values become `{:other, urn}`."
  @spec from_urn(String.t()) :: t()
  def from_urn(urn) when is_binary(urn), do: Map.get(@by_urn, urn, {:other, urn})
end

defmodule DatagroutConduit.Delegation.Token do
  @moduledoc """
  A token issued by a delegated exchange.

  The serialized shape is part of the cross-language contract, and is what
  `testdata/contract.json` pins: `access_token`, `issued_token_type` (a URN
  string), `token_type`, `expires_at?`, `scope?`. As with
  `DatagroutConduit.AuthCode.Grant`, `expires_at` is **Unix seconds** — computed
  from the server's relative `expires_in` at receipt — never a monotonic
  reading, which is meaningless once written down.

  Inspecting a token shows everything but the bearer itself: a delegated token
  carries a user's identity and has no business in a log line or a crash report.
  """

  alias DatagroutConduit.Delegation
  alias DatagroutConduit.Delegation.TokenType

  @type t :: %__MODULE__{
          access_token: String.t(),
          issued_token_type: TokenType.t() | nil,
          token_type: String.t(),
          expires_at: integer() | nil,
          scope: String.t() | nil
        }

  @derive {Inspect, only: [:issued_token_type, :token_type, :expires_at, :scope]}
  defstruct [:access_token, :issued_token_type, :token_type, :expires_at, :scope]

  @doc """
  The cross-language wire shape.

  Absent optionals are omitted rather than written as nulls, so a token
  round-trips through any of the SDKs.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = token) do
    base = %{
      "access_token" => token.access_token,
      "issued_token_type" => TokenType.to_urn(token.issued_token_type),
      "token_type" => token.token_type
    }

    [expires_at: token.expires_at, scope: token.scope]
    |> Enum.reduce(base, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, Atom.to_string(key), value)
    end)
  end

  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      access_token: data["access_token"],
      issued_token_type:
        data["issued_token_type"] && TokenType.from_urn(data["issued_token_type"]),
      token_type: data["token_type"],
      expires_at: as_integer(data["expires_at"]),
      scope: data["scope"]
    }
  end

  @doc """
  True when the token is expired, or within the refresh skew of it.

  A token with no stated expiry is treated as live: the server chose not to say,
  and guessing would throw away working tokens.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: at}) do
    Delegation.now_secs() + Delegation.refresh_skew_secs() >= at
  end

  defp as_integer(nil), do: nil
  defp as_integer(value) when is_integer(value), do: value

  defp as_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp as_integer(_), do: nil
end

defmodule DatagroutConduit.Delegation.TokenSource do
  @moduledoc """
  Where a `DatagroutConduit.Delegation.Provider` gets a subject or actor token
  from, and what `DatagroutConduit.Delegation.TokenType` to declare it as.

  A source is consulted on **every** exchange, so a provider-backed source hands
  over a *fresh* token each time — the whole point of wrapping a provider rather
  than copying its current token out. An expiring upstream credential is then
  handled by the provider that owns it.

    * `static_token/2` — a fixed token, e.g. one handed to the agent for this run
    * `client_credentials/1` — a `DatagroutConduit.OAuth` server: the usual **actor**
    * `authorization_code/1` — a `DatagroutConduit.AuthCode.Provider`: the usual
      **subject** in an app that signed the user in itself
    * `dynamic/2` — any zero-arity function: a vault lookup, an inbound request's
      header, another SDK's provider

  Inspecting a source names its kind and token type and never the token.
  """

  alias DatagroutConduit.AuthCode
  alias DatagroutConduit.Delegation.TokenType

  @type kind ::
          {:static, String.t()}
          | {:client_credentials, GenServer.server()}
          | {:authorization_code, GenServer.server()}
          | {:dynamic, (-> {:ok, String.t()} | {:error, term()} | String.t())}

  @type t :: %__MODULE__{kind: kind(), token_type: TokenType.t()}

  defstruct [:kind, :token_type]

  @doc "A fixed token."
  @spec static_token(String.t(), TokenType.t()) :: t()
  def static_token(token, token_type) when is_binary(token) do
    %__MODULE__{kind: {:static, token}, token_type: token_type}
  end

  @doc """
  The agent's own `client_credentials` provider — the usual **actor**.

  Declared as `:access_token`; override with `with_token_type/2` if the server
  wants `:jwt`.
  """
  @spec client_credentials(GenServer.server()) :: t()
  def client_credentials(provider) do
    %__MODULE__{kind: {:client_credentials, provider}, token_type: :access_token}
  end

  @doc """
  A user's authorization-code provider — the usual **subject**.

  Refreshes its grant as needed, so the exchange always sees a live subject
  token.
  """
  @spec authorization_code(GenServer.server()) :: t()
  def authorization_code(provider) do
    %__MODULE__{kind: {:authorization_code, provider}, token_type: :access_token}
  end

  @doc "Any zero-arity function that yields a token."
  @spec dynamic((-> {:ok, String.t()} | {:error, term()} | String.t()), TokenType.t()) :: t()
  def dynamic(fun, token_type) when is_function(fun, 0) do
    %__MODULE__{kind: {:dynamic, fun}, token_type: token_type}
  end

  @doc "Declare a different token type for this source."
  @spec with_token_type(t(), TokenType.t()) :: t()
  def with_token_type(%__MODULE__{} = source, token_type), do: %{source | token_type: token_type}

  @doc "The declared token type."
  @spec token_type(t()) :: TokenType.t()
  def token_type(%__MODULE__{token_type: token_type}), do: token_type

  @doc """
  Ask this source for a token.

  A failure carries the *source's* own reason rather than a
  `DatagroutConduit.Delegation.Error`: the exchange never happened, and
  relabelling an upstream refresh failure as a delegation error would hide where
  it came from.
  """
  @spec resolve(t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%__MODULE__{kind: {:static, token}}), do: {:ok, token}

  def resolve(%__MODULE__{kind: {:client_credentials, provider}}) do
    normalize(DatagroutConduit.OAuth.get_token(provider))
  end

  def resolve(%__MODULE__{kind: {:authorization_code, provider}}) do
    normalize(AuthCode.Provider.get_token(provider))
  end

  def resolve(%__MODULE__{kind: {:dynamic, fun}}), do: normalize(fun.())

  defp normalize({:ok, token}) when is_binary(token), do: {:ok, token}
  defp normalize(token) when is_binary(token), do: {:ok, token}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:invalid_token_source_result, other}}

  @doc false
  def kind_label(%__MODULE__{kind: {label, _}}), do: Atom.to_string(label)
end

defimpl Inspect, for: DatagroutConduit.Delegation.TokenSource do
  import Inspect.Algebra

  alias DatagroutConduit.Delegation.{TokenSource, TokenType}

  # Never print the token, and never print a provider's pid-held secrets.
  def inspect(%TokenSource{} = source, _opts) do
    concat([
      "#DatagroutConduit.Delegation.TokenSource<",
      TokenSource.kind_label(source),
      " ",
      TokenType.to_urn(source.token_type),
      ">"
    ])
  end
end
