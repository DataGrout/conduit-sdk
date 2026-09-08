defmodule DatagroutConduit.AuthCode do
  @moduledoc """
  OAuth 2.1 **authorization code + PKCE** — browser-consent sign-in.

  The `client_credentials` grant in `DatagroutConduit.OAuth` authenticates a
  *machine*: it needs a client secret issued out of band. This module
  authenticates a *person*: the app opens a browser, the user consents at the
  gateway, and the app receives a grant bound to that user's account. It is what
  a desktop or CLI application needs, and the only way to use
  `https://gateway.datagrout.ai/connect`, where the server binding is chosen at
  consent time and lives in the token rather than the URL.

  ## Flow

    1. `discover/1` — fetch protected-resource metadata, then the authorization
       server's metadata.
    2. `register/3` — RFC 7591 dynamic client registration, as a **public
       client** (no secret; PKCE takes its place).
    3. `authorize_url/1` — build the consent URL and hold the PKCE verifier and
       CSRF state in a `DatagroutConduit.AuthCode.PendingAuthorization`.
    4. The caller opens that URL and captures the redirect.
       `DatagroutConduit.AuthCode.Loopback` does the capturing.
    5. `exchange/4` — trade the code for a `DatagroutConduit.AuthCode.Grant`.

      alias DatagroutConduit.AuthCode

      {:ok, listener} = AuthCode.Loopback.bind()
      {:ok, flow} = AuthCode.discover("https://gateway.datagrout.ai/connect")
      {:ok, registered, flow} =
        AuthCode.register(flow, "My App", AuthCode.Loopback.redirect_uri(listener))

      {:ok, url, pending} = AuthCode.authorize_url(flow)
      IO.puts("Open: \#{url}")

      {:ok, redirect} = AuthCode.Loopback.wait(listener, 300_000)
      {:ok, grant} = AuthCode.exchange(flow, pending, redirect.code, redirect.state)

  ## Persisting the grant

  This module owns the `Grant` shape and its refresh logic; it deliberately does
  **not** choose where a grant is stored. That is the application's decision — a
  keychain, a config file, a vault — and baking a filesystem opinion into an SDK
  makes it wrong for half its callers.

  `Grant.expires_at` is Unix seconds rather than a monotonic reading precisely so
  a grant survives serialization: it is written by one process and read by
  another, possibly in a different language.
  """

  alias DatagroutConduit.AuthCode.{
    Error,
    Grant,
    PendingAuthorization,
    RegisteredClient,
    ServerMetadata
  }

  @typedoc "A flow part-way through discovery, registration and consent."
  @type t :: %__MODULE__{
          metadata: ServerMetadata.t(),
          resource: String.t(),
          client_id: String.t() | nil,
          redirect_uri: String.t() | nil,
          scope: String.t()
        }

  defstruct [:metadata, :resource, :client_id, :redirect_uri, scope: nil]

  @doc """
  Scopes requested when the caller does not specify.

  Matches the authorization server's own registration default rather than
  inventing a finer-grained vocabulary: DataGrout splits the scope string on
  whitespace and stores what it is given, so a made-up scope is accepted
  silently and then means nothing.
  """
  @default_scope "mcp tools"
  def default_scope, do: @default_scope

  @doc "Refresh this many seconds before the token actually expires."
  @refresh_skew_secs 60
  def refresh_skew_secs, do: @refresh_skew_secs

  # In test env, inject the Req.Test plug so Req.Test.stub/2 can intercept HTTP
  # calls. A compile-time constant, so it costs nothing in production.
  @req_plug_opts if Mix.env() == :test, do: [plug: {Req.Test, __MODULE__}], else: []

  # --- Discovery ---

  @doc """
  Discover the authorization server protecting `resource_url`.

  `resource_url` is the MCP endpoint being connected to — for DataGrout,
  `https://gateway.datagrout.ai/connect` or a `.../servers/{uuid}/mcp` URL.

  Tries RFC 9728 protected-resource metadata first, then RFC 8414
  authorization-server metadata on whatever that names. Falls back to the
  resource's own origin, which is where DataGrout serves it.
  """
  @spec discover(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def discover(resource_url) do
    resource = String.replace_trailing(resource_url, "/", "")

    with {:ok, issuer} <- resolve_issuer(resource),
         {:ok, metadata} <- fetch_server_metadata(issuer) do
      if ServerMetadata.supports_s256?(metadata) do
        {:ok,
         %__MODULE__{
           metadata: metadata,
           resource: resource,
           scope: @default_scope
         }}
      else
        {:error, Error.pkce_unsupported()}
      end
    end
  end

  defp resolve_issuer(resource) do
    case fetch_resource_metadata(resource) do
      %{"authorization_servers" => [issuer | _]} when is_binary(issuer) ->
        {:ok, issuer}

      _ ->
        # No PRM, or it named no servers: DataGrout serves AS metadata at the
        # origin, so try there before giving up.
        case origin_of(resource) do
          nil -> {:error, Error.discovery("not a URL: #{resource}")}
          origin -> {:ok, origin}
        end
    end
  end

  # --- Configuring the flow ---

  @doc "Use a client id registered out of band, skipping dynamic registration."
  @spec with_client_id(t(), String.t(), String.t()) :: t()
  def with_client_id(%__MODULE__{} = flow, client_id, redirect_uri) do
    %{flow | client_id: client_id, redirect_uri: redirect_uri}
  end

  @doc """
  Reuse a client registered on a previous run.

  Prefer this over `with_client_id/3`: it carries the redirect URI with the id,
  which is not optional bookkeeping — an authorization server matches the
  redirect URI **exactly** against what was registered, so a client id reused
  with a different URI is rejected.
  """
  @spec with_registered_client(t(), RegisteredClient.t()) :: t()
  def with_registered_client(%__MODULE__{} = flow, %RegisteredClient{} = registered) do
    with_client_id(flow, registered.client_id, registered.redirect_uri)
  end

  @doc "Request scopes other than `default_scope/0`."
  @spec with_scope(t(), String.t()) :: t()
  def with_scope(%__MODULE__{} = flow, scope), do: %{flow | scope: scope}

  # --- Registration ---

  @doc """
  Register this application via RFC 7591 dynamic client registration.

  Registers a **public client** — `token_endpoint_auth_method: "none"`, no
  secret issued. A desktop or CLI application cannot keep a secret, and PKCE is
  what stands in for one.

  Returns the `RegisteredClient` — the id **and** the redirect URI it is bound
  to — alongside the updated flow. Persist the pair and restore it with
  `with_registered_client/2`; re-registering on every launch creates a new client
  record each time, and reusing an id against a different redirect URI is
  rejected.
  """
  @spec register(t(), String.t(), String.t()) ::
          {:ok, RegisteredClient.t(), t()} | {:error, Error.t()}
  def register(%__MODULE__{} = flow, client_name, redirect_uri) do
    case flow.metadata.registration_endpoint do
      nil ->
        {:error, Error.no_registration_endpoint()}

      endpoint ->
        body = %{
          "client_name" => client_name,
          "redirect_uris" => [redirect_uri],
          "grant_types" => ["authorization_code", "refresh_token"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "application_type" => "native"
        }

        case Req.post(endpoint, [json: body] ++ @req_plug_opts) do
          {:ok, %{status: status, body: %{"client_id" => client_id}}}
          when status in 200..299 and is_binary(client_id) ->
            registered = %RegisteredClient{client_id: client_id, redirect_uri: redirect_uri}
            {:ok, registered, with_client_id(flow, client_id, redirect_uri)}

          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:error, Error.http("bad registration response: #{inspect(body)}")}

          {:ok, %{status: status, body: body}} ->
            {:error, Error.registration_rejected(status, to_body(body))}

          {:error, reason} ->
            {:error, Error.http("HTTP error: #{inspect(reason)}")}
        end
    end
  end

  # --- Consent and exchange ---

  @doc """
  Build the consent URL, plus the `PendingAuthorization` needed to redeem the
  resulting code.

  The caller opens the URL however suits it — a browser, a printed instruction,
  a QR code. This library does not launch browsers.
  """
  @spec authorize_url(t()) :: {:ok, String.t(), PendingAuthorization.t()} | {:error, Error.t()}
  def authorize_url(%__MODULE__{client_id: nil}), do: {:error, Error.no_client_id()}
  def authorize_url(%__MODULE__{redirect_uri: nil}), do: {:error, Error.no_client_id()}

  def authorize_url(%__MODULE__{} = flow) do
    code_verifier = generate_verifier()
    state = generate_state()

    query =
      [
        {"response_type", "code"},
        {"client_id", flow.client_id},
        {"redirect_uri", flow.redirect_uri},
        {"scope", flow.scope},
        {"state", state},
        {"code_challenge", challenge_s256(code_verifier)},
        {"code_challenge_method", "S256"},
        # RFC 8707: bind the token to this resource so it cannot be replayed
        # against a different one.
        {"resource", flow.resource}
      ]
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{urlencode(v)}" end)

    separator = if String.contains?(flow.metadata.authorization_endpoint, "?"), do: "&", else: "?"
    url = flow.metadata.authorization_endpoint <> separator <> query

    pending = %PendingAuthorization{
      code_verifier: code_verifier,
      state: state,
      redirect_uri: flow.redirect_uri
    }

    {:ok, url, pending}
  end

  @doc """
  Redeem an authorization code for a `Grant`.

  `returned_state` is the `state` parameter from the redirect. It is checked
  against the pending request before anything is sent: a mismatch means the
  response belongs to a different authorization request, and the exchange is
  refused rather than attempted.
  """
  @spec exchange(t(), PendingAuthorization.t(), String.t(), String.t()) ::
          {:ok, Grant.t()} | {:error, Error.t()}
  def exchange(%__MODULE__{} = flow, %PendingAuthorization{} = pending, code, returned_state) do
    cond do
      not secure_compare(pending.state, returned_state) ->
        {:error, Error.state_mismatch()}

      is_nil(flow.client_id) ->
        {:error, Error.no_client_id()}

      true ->
        form = %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => pending.redirect_uri,
          "client_id" => flow.client_id,
          "code_verifier" => pending.code_verifier,
          "resource" => flow.resource
        }

        with {:ok, token} <- post_form(flow.metadata.token_endpoint, form) do
          {:ok,
           %Grant{
             access_token: token["access_token"],
             refresh_token: token["refresh_token"],
             expires_at: expires_at_from(token["expires_in"]),
             client_id: flow.client_id,
             token_endpoint: flow.metadata.token_endpoint,
             scope: token["scope"],
             resource: flow.resource
           }}
        end
    end
  end

  # --- PKCE and helpers ---

  @doc "Generate an RFC 7636 code verifier: 43 characters of base64url."
  @spec generate_verifier() :: String.t()
  def generate_verifier do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc "The S256 challenge for a verifier: `base64url(sha256(verifier))`."
  @spec challenge_s256(String.t()) :: String.t()
  def challenge_s256(verifier) do
    Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
  end

  @doc false
  def generate_state do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc false
  def now_secs, do: System.os_time(:second)

  @doc false
  def expires_at_from(nil), do: nil
  def expires_at_from(expires_in) when is_integer(expires_in), do: now_secs() + expires_in

  def expires_at_from(expires_in) when is_binary(expires_in) do
    case Integer.parse(expires_in) do
      {seconds, _} -> now_secs() + seconds
      :error -> nil
    end
  end

  def expires_at_from(_), do: nil

  @doc """
  Length-independent comparison, so a state check cannot be timed.
  """
  @spec secure_compare(String.t(), String.t()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  def secure_compare(_, _), do: false

  @doc """
  Percent-encode a query parameter value.

  Unreserved set per RFC 3986. Everything else is escaped — including `/` and
  `:`, which appear in redirect URIs and resource URLs and must not be taken as
  structure by the authorization server.
  """
  @spec urlencode(String.t()) :: String.t()
  def urlencode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  @doc "The scheme, host and port of a URL, with the path dropped."
  @spec origin_of(String.t()) :: String.t() | nil
  def origin_of(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        if uri.port && uri.port != URI.default_port(scheme) do
          "#{scheme}://#{host}:#{uri.port}"
        else
          "#{scheme}://#{host}"
        end

      _ ->
        nil
    end
  end

  # --- HTTP ---

  @doc false
  # RFC 9728 protected-resource metadata, or nil if unavailable.
  def fetch_resource_metadata(resource) do
    # Path-appended form first (what MCP servers with a path segment use), then
    # the origin-level one.
    candidates =
      [resource, origin_of(resource)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&"#{&1}/.well-known/oauth-protected-resource")

    Enum.find_value(candidates, fn url ->
      case Req.get(url, @req_plug_opts) do
        # A non-object body is not metadata; fall through to the next candidate
        # rather than handing the caller something unusable.
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) -> body
        _ -> nil
      end
    end)
  end

  @doc false
  def fetch_server_metadata(issuer) do
    base = String.replace_trailing(issuer, "/", "")

    candidates = [
      "#{base}/.well-known/oauth-authorization-server",
      "#{base}/.well-known/openid-configuration"
    ]

    Enum.reduce_while(candidates, {:error, Error.discovery("no metadata attempted")}, fn url,
                                                                                         _acc ->
      case Req.get(url, @req_plug_opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:halt, ServerMetadata.from_map(body)}

        {:ok, %{status: status}} when status in 200..299 ->
          {:cont, {:error, Error.discovery("bad metadata at #{url}: not a JSON object")}}

        {:ok, %{status: status}} ->
          {:cont,
           {:error, Error.discovery("no metadata found (last attempt: #{url} → HTTP #{status})")}}

        {:error, reason} ->
          {:cont,
           {:error,
            Error.discovery("no metadata found (last attempt: #{url} → #{inspect(reason)})")}}
      end
    end)
  end

  @doc false
  def post_form(endpoint, form) do
    case Req.post(endpoint, [form: form] ++ @req_plug_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:error, Error.http("bad token response: expected a JSON object, got #{inspect(body)}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.token_exchange(status, to_body(body))}

      {:error, reason} ->
        {:error, Error.http("HTTP error: #{inspect(reason)}")}
    end
  end

  defp to_body(body) when is_binary(body), do: body
  defp to_body(body), do: inspect(body)
end
