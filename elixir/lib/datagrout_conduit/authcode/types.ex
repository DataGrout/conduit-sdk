defmodule DatagroutConduit.AuthCode.ServerMetadata do
  @moduledoc """
  RFC 8414 authorization server metadata (the fields this flow uses).
  """

  alias DatagroutConduit.AuthCode.Error

  @type t :: %__MODULE__{
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          registration_endpoint: String.t() | nil,
          code_challenge_methods_supported: [String.t()],
          grant_types_supported: [String.t()],
          scopes_supported: [String.t()]
        }

  defstruct issuer: "",
            authorization_endpoint: nil,
            token_endpoint: nil,
            registration_endpoint: nil,
            code_challenge_methods_supported: [],
            grant_types_supported: [],
            scopes_supported: []

  @doc "Parse a metadata document, refusing one without the endpoints this flow needs."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{"authorization_endpoint" => authorize, "token_endpoint" => token} = data)
      when is_binary(authorize) and is_binary(token) do
    {:ok,
     %__MODULE__{
       issuer: to_string(data["issuer"] || ""),
       authorization_endpoint: authorize,
       token_endpoint: token,
       registration_endpoint: data["registration_endpoint"],
       code_challenge_methods_supported: list(data["code_challenge_methods_supported"]),
       grant_types_supported: list(data["grant_types_supported"]),
       scopes_supported: list(data["scopes_supported"])
     }}
  end

  def from_map(_data) do
    {:error, Error.discovery("metadata is missing authorization_endpoint or token_endpoint")}
  end

  @doc """
  Whether the server can do PKCE with S256.

  An empty list means the server did not advertise. RFC 8414 makes the field
  optional and DataGrout omits it on some paths, so absence is treated as
  "assume S256" rather than as a refusal — a server that truly cannot do S256
  will reject the authorize request anyway.
  """
  @spec supports_s256?(t()) :: boolean()
  def supports_s256?(%__MODULE__{code_challenge_methods_supported: []}), do: true

  def supports_s256?(%__MODULE__{code_challenge_methods_supported: methods}) do
    Enum.any?(methods, &(String.downcase(to_string(&1)) == "s256"))
  end

  defp list(value) when is_list(value), do: value
  defp list(_), do: []
end

defmodule DatagroutConduit.AuthCode.RegisteredClient do
  @moduledoc """
  A dynamically-registered client: the id **and** the redirect URI it is bound
  to.

  These travel together because an authorization server matches the redirect URI
  *exactly* against the value registered — there is no loopback-port exemption
  to rely on. Persisting the id alone means a later re-authorization on a
  freshly-chosen port is rejected as `invalid_redirect_uri`, and the failure only
  shows up once the first grant can no longer be refreshed.

  Persist this next to the `DatagroutConduit.AuthCode.Grant` and restore it with
  `DatagroutConduit.AuthCode.with_registered_client/2`.
  """

  @type t :: %__MODULE__{client_id: String.t(), redirect_uri: String.t()}

  defstruct [:client_id, :redirect_uri]

  @doc "The cross-language wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = client) do
    %{"client_id" => client.client_id, "redirect_uri" => client.redirect_uri}
  end

  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{client_id: data["client_id"], redirect_uri: data["redirect_uri"]}
  end
end

defmodule DatagroutConduit.AuthCode.PendingAuthorization do
  @moduledoc """
  The secrets held between building the consent URL and redeeming the code.
  """

  @type t :: %__MODULE__{
          code_verifier: String.t(),
          state: String.t(),
          redirect_uri: String.t()
        }

  defstruct [:code_verifier, :state, :redirect_uri]
end

defmodule DatagroutConduit.AuthCode.Grant do
  @moduledoc """
  A user's authorization, ready to persist.

  The serialized shape is part of the cross-language contract: a grant written by
  one conduit SDK must be readable by another. Field names and types are
  therefore fixed, and `expires_at` is Unix seconds — never a monotonic reading,
  which is meaningless once written to disk.
  """

  alias DatagroutConduit.AuthCode
  alias DatagroutConduit.AuthCode.Error

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: integer() | nil,
          client_id: String.t(),
          token_endpoint: String.t(),
          scope: String.t() | nil,
          resource: String.t() | nil
        }

  defstruct [
    :access_token,
    :refresh_token,
    :expires_at,
    :client_id,
    :token_endpoint,
    :scope,
    :resource
  ]

  @doc """
  The cross-language wire shape.

  Absent optionals are omitted rather than written as nulls, so a grant
  round-trips through any of the SDKs.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = grant) do
    base = %{
      "access_token" => grant.access_token,
      "client_id" => grant.client_id,
      "token_endpoint" => grant.token_endpoint
    }

    [
      refresh_token: grant.refresh_token,
      expires_at: grant.expires_at,
      scope: grant.scope,
      resource: grant.resource
    ]
    |> Enum.reduce(base, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, Atom.to_string(key), value)
    end)
  end

  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      access_token: data["access_token"],
      refresh_token: data["refresh_token"],
      expires_at: as_integer(data["expires_at"]),
      client_id: data["client_id"],
      token_endpoint: data["token_endpoint"],
      scope: data["scope"],
      resource: data["resource"]
    }
  end

  @doc """
  True when the access token is expired, or within the refresh skew of it.

  A grant with no stated expiry is treated as live: the server chose not to say,
  and guessing an expiry would throw away working tokens.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: at}) do
    AuthCode.now_secs() + AuthCode.refresh_skew_secs() >= at
  end

  @doc "Whether this grant can renew itself without user interaction."
  @spec refreshable?(t()) :: boolean()
  def refreshable?(%__MODULE__{refresh_token: nil}), do: false
  def refreshable?(%__MODULE__{}), do: true

  @doc """
  Exchange the refresh token for a fresh grant.

  Returns a new grant; the old one should be discarded. DataGrout rotates
  refresh tokens, so keeping the previous grant around and using it again can
  invalidate the whole family.
  """
  @spec refresh(t()) :: {:ok, t()} | {:error, Error.t()}
  def refresh(%__MODULE__{refresh_token: nil}), do: {:error, Error.not_refreshable()}

  def refresh(%__MODULE__{} = grant) do
    form =
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => grant.refresh_token,
        "client_id" => grant.client_id
      }
      |> maybe_put("resource", grant.resource)

    with {:ok, token} <- AuthCode.post_form(grant.token_endpoint, form) do
      {:ok,
       %__MODULE__{
         access_token: token["access_token"],
         # A server that does not rotate returns no new refresh token; keep the
         # existing one rather than silently making the grant unrefreshable
         # from here on.
         refresh_token: token["refresh_token"] || grant.refresh_token,
         expires_at: AuthCode.expires_at_from(token["expires_in"]),
         client_id: grant.client_id,
         token_endpoint: grant.token_endpoint,
         scope: token["scope"] || grant.scope,
         resource: grant.resource
       }}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
