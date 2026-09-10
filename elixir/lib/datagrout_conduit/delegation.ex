defmodule DatagroutConduit.Delegation do
  @moduledoc """
  RFC 8693 **delegation** — an agent acting *for* a user.

  The two grants this SDK already speaks each answer one question.
  `DatagroutConduit.OAuth` (`client_credentials`) says *which machine* is
  calling; `DatagroutConduit.AuthCode` says *which person* consented. Neither
  says both, and an agent working on a user's behalf needs to: the resource
  server has to know whose data it is (`sub`) and who is actually holding the
  connection (`act`). RFC 8693 produces exactly that token, from two the caller
  already has.

  ## Delegation, not impersonation

  RFC 8693 distinguishes the two. In **delegation** the issued token names the
  user as `sub` and the agent in an `act` claim, so the resource server can see
  — and audit, and rate-limit, and revoke — the agent separately from the user.
  In **impersonation** the agent simply *becomes* the user, and the resource
  server cannot tell the difference. DataGrout's authorization server issues
  delegation tokens and requires an `actor_token`; this module therefore
  **requires an actor by default** and refuses to build a request without one.
  Impersonation is an explicit opt-in via `impersonation/1`, for RFC 8693
  servers that support it.

  ## Wire contract

  `POST {token_endpoint}`, form-encoded, in this order:

  | field | value |
  |---|---|
  | `grant_type` | `urn:ietf:params:oauth:grant-type:token-exchange` |
  | `subject_token`, `subject_token_type` | the user's token and its `DatagroutConduit.Delegation.TokenType` URN |
  | `actor_token`, `actor_token_type` | the agent's token and URN — omitted only under `impersonation/1` |
  | `client_id`, `client_secret?` | client authentication, in the body by default (see `client_auth/2`) |
  | `audience?`, `resource?`, `scope?`, `requested_token_type?` | as set |

  `resource` is RFC 8707 and, when set, is always sent — the same invariant
  `DatagroutConduit.AuthCode` keeps, so a delegated token cannot be replayed
  against a different resource.

  **The client must be the actor.** The `client_id` authenticating the request
  and the principal behind `actor_token` are expected to be the same agent. This
  SDK does not verify that — it cannot, without decoding the actor token — and
  the server enforces it (`unauthorized_client` when they differ).

  The response is `{access_token, issued_token_type, token_type, expires_in?,
  scope?}`; errors are RFC 6749 bodies `{error, error_description?}`, with the
  codes listed in `server_error_codes/0`.

  ## Usage

      alias DatagroutConduit.Delegation
      alias DatagroutConduit.Delegation.{Provider, TokenSource}

      # The agent's own credential — the actor.
      {:ok, agent} =
        DatagroutConduit.OAuth.start_link(
          client_id: "agent_client_id",
          client_secret: "agent_client_secret",
          token_endpoint: "https://gateway.datagrout.ai/oauth/token"
        )

      request =
        Delegation.new("https://gateway.datagrout.ai/oauth/token", "agent_client_id")
        |> Delegation.client_secret("agent_client_secret")
        |> Delegation.resource("https://gateway.datagrout.ai/connect")

      {:ok, provider} =
        Provider.start_link(
          request: request,
          # The user's token — the subject. A long-lived app would use
          # `TokenSource.authorization_code/1` instead.
          subject: TokenSource.static_token(user_token, :access_token),
          actor: TokenSource.client_credentials(agent)
        )

      {:ok, client} =
        DatagroutConduit.Client.start_link(
          url: "https://gateway.datagrout.ai/connect",
          auth: {:delegation, provider}
        )

  ## Naming

  Elsewhere in this SDK "token exchange" already means redeeming a
  `client_credentials` grant, and `%DatagroutConduit.AuthCode.Error{kind:
  :token_exchange}` means redeeming an authorization code. This module says
  *delegation* and *exchange* — `exchange/1`,
  `DatagroutConduit.Delegation.Token` — and never reuses that label, so a log
  line cannot be read two ways.
  """

  alias DatagroutConduit.Delegation.{Error, Token, TokenType}

  @typedoc "How the client authenticates to the token endpoint."
  @type client_auth :: :body | :basic

  @typedoc "A request, built up and then `exchange/1`d."
  @type t :: %__MODULE__{
          token_endpoint: String.t(),
          client_id: String.t(),
          client_secret: String.t() | nil,
          client_auth: client_auth(),
          subject: {String.t(), TokenType.t()} | nil,
          actor: {String.t(), TokenType.t()} | nil,
          audience: String.t() | nil,
          resource: String.t() | nil,
          scope: String.t() | nil,
          requested_token_type: TokenType.t() | nil,
          impersonation: boolean()
        }

  # Only the fields that are safe in a log line or a crash report. The rest are
  # the user's token, the agent's token and the client secret.
  @derive {Inspect, only: [:token_endpoint, :client_id, :client_auth, :impersonation]}
  defstruct [
    :token_endpoint,
    :client_id,
    :client_secret,
    :subject,
    :actor,
    :audience,
    :resource,
    :scope,
    :requested_token_type,
    client_auth: :body,
    impersonation: false
  ]

  @doc "The RFC 8693 grant type."
  @grant_type "urn:ietf:params:oauth:grant-type:token-exchange"
  @spec grant_type() :: String.t()
  def grant_type, do: @grant_type

  @doc """
  RFC 6749 error codes a token-exchange endpoint returns, as
  `%DatagroutConduit.Delegation.Error{kind: :server, error: code}`.

  Listed so callers and ports compare against this rather than a string they
  typed. `invalid_target` is the one specific to RFC 8693: the `audience` or
  `resource` is not one this server issues tokens for.
  """
  @server_error_codes [
    "invalid_request",
    "invalid_client",
    "invalid_grant",
    "unauthorized_client",
    "invalid_target",
    "invalid_scope",
    "unsupported_grant_type"
  ]
  @spec server_error_codes() :: [String.t()]
  def server_error_codes, do: @server_error_codes

  @doc """
  Re-exchange this many seconds before the delegated token actually expires.

  The same buffer `DatagroutConduit.OAuth` and `DatagroutConduit.AuthCode` use,
  so all three providers behave alike under a clock skew.
  """
  @refresh_skew_secs 60
  @spec refresh_skew_secs() :: pos_integer()
  def refresh_skew_secs, do: @refresh_skew_secs

  # In test env, inject the Req.Test plug so Req.Test.stub/2 can intercept HTTP
  # calls. A compile-time constant, so it costs nothing in production.
  @req_plug_opts if Mix.env() == :test, do: [plug: {Req.Test, __MODULE__}], else: []

  # --- Building a request ---

  @doc """
  Start a request against `token_endpoint`, authenticating as `client_id`.

  The client should be the actor — see the module docs.
  """
  @spec new(String.t(), String.t()) :: t()
  def new(token_endpoint, client_id) do
    %__MODULE__{token_endpoint: token_endpoint, client_id: client_id}
  end

  @doc "The client secret, for confidential clients."
  @spec client_secret(t(), String.t()) :: t()
  def client_secret(%__MODULE__{} = request, secret), do: %{request | client_secret: secret}

  @doc """
  Where the client secret travels.

    * `:body` — `client_id` and `client_secret` as form fields (RFC 6749 §2.3.1
      `client_secret_post`). The default, and what DataGrout expects.
    * `:basic` — `Authorization: Basic base64(client_id:client_secret)`
      (`client_secret_basic`). `client_id` is still sent in the body, as RFC 6749
      permits and some servers require.
  """
  @spec client_auth(t(), client_auth()) :: t()
  def client_auth(%__MODULE__{} = request, mode) when mode in [:body, :basic] do
    %{request | client_auth: mode}
  end

  @doc """
  The token being exchanged: the **user's**, whose identity the issued token
  will carry as `sub`.
  """
  @spec subject_token(t(), String.t(), TokenType.t()) :: t()
  def subject_token(%__MODULE__{} = request, token, token_type) do
    %{request | subject: {token, token_type}}
  end

  @doc "The **agent's** own token, which the issued token will name in `act`."
  @spec actor_token(t(), String.t(), TokenType.t()) :: t()
  def actor_token(%__MODULE__{} = request, token, token_type) do
    %{request | actor: {token, token_type}}
  end

  @doc "Logical name of the service the token is for (RFC 8693 `audience`)."
  @spec audience(t(), String.t()) :: t()
  def audience(%__MODULE__{} = request, audience), do: %{request | audience: audience}

  @doc """
  URI of the resource the token is for (RFC 8707 `resource`). Always sent when
  set, so the token cannot be replayed elsewhere.
  """
  @spec resource(t(), String.t()) :: t()
  def resource(%__MODULE__{} = request, resource), do: %{request | resource: resource}

  @doc "Scopes to request, space-separated."
  @spec scope(t(), String.t()) :: t()
  def scope(%__MODULE__{} = request, scope), do: %{request | scope: scope}

  @doc "The kind of token wanted back. Servers default to an access token."
  @spec requested_token_type(t(), TokenType.t()) :: t()
  def requested_token_type(%__MODULE__{} = request, token_type) do
    %{request | requested_token_type: token_type}
  end

  @doc """
  Opt out of delegation: send no `actor_token`, so the issued token has no `act`
  claim and the agent is indistinguishable from the user.

  DataGrout does not issue these. This exists for other RFC 8693 servers, and it
  is an explicit call rather than a default precisely so that forgetting to set
  an actor is an error instead of a silent downgrade.
  """
  @spec impersonation(t()) :: t()
  def impersonation(%__MODULE__{} = request), do: %{request | impersonation: true}

  @doc "Whether `impersonation/1` was called."
  @spec impersonation?(t()) :: boolean()
  def impersonation?(%__MODULE__{impersonation: value}), do: value

  # --- The wire ---

  @doc """
  The form body this request will post, in wire order.

  Fails **before any network activity** when the request is incomplete:
  `:missing_subject`, or `:missing_actor` unless `impersonation/1` was called.
  Public so a caller — or another SDK's test suite — can check the body against
  the contract fixture without a server.
  """
  @spec form_params(t()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  def form_params(%__MODULE__{subject: nil}), do: {:error, Error.missing_subject()}

  def form_params(%__MODULE__{actor: nil, impersonation: false}),
    do: {:error, Error.missing_actor()}

  def form_params(%__MODULE__{} = request) do
    {subject, subject_type} = request.subject

    form =
      [
        {"grant_type", @grant_type},
        {"subject_token", subject},
        {"subject_token_type", TokenType.to_urn(subject_type)}
      ] ++
        actor_params(request.actor) ++
        [{"client_id", request.client_id}] ++
        secret_params(request) ++
        optional_params(request)

    {:ok, form}
  end

  defp actor_params(nil), do: []

  defp actor_params({actor, actor_type}) do
    [{"actor_token", actor}, {"actor_token_type", TokenType.to_urn(actor_type)}]
  end

  defp secret_params(%__MODULE__{client_secret: secret, client_auth: :body})
       when is_binary(secret),
       do: [{"client_secret", secret}]

  defp secret_params(_request), do: []

  defp optional_params(%__MODULE__{} = request) do
    [
      {"audience", request.audience},
      {"resource", request.resource},
      {"scope", request.scope},
      {"requested_token_type",
       request.requested_token_type && TokenType.to_urn(request.requested_token_type)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Perform the exchange.

  Returns the issued `DatagroutConduit.Delegation.Token`, or one of the five
  `DatagroutConduit.Delegation.Error` kinds. Prefer
  `DatagroutConduit.Delegation.Provider` for anything long-lived: it caches the
  result and pulls fresh subject and actor tokens on each re-exchange.
  """
  @spec exchange(t()) :: {:ok, Token.t()} | {:error, Error.t()}
  def exchange(%__MODULE__{} = request) do
    with {:ok, form} <- form_params(request) do
      opts = [form: form, headers: basic_auth_headers(request)] ++ @req_plug_opts

      case Req.post(request.token_endpoint, opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          parse_token(status, body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, parse_error_body(status, body)}

        {:error, reason} ->
          {:error, Error.http("HTTP error: #{inspect(reason)}")}
      end
    end
  end

  defp basic_auth_headers(%__MODULE__{client_secret: secret, client_auth: :basic} = request)
       when is_binary(secret) do
    [{"authorization", "Basic " <> Base.encode64("#{request.client_id}:#{secret}")}]
  end

  defp basic_auth_headers(_request), do: []

  # RFC 8693 §2.2.1 makes `issued_token_type` and `token_type` REQUIRED; a
  # server that drops either is out of contract, and guessing would hide that.
  defp parse_token(status, body) do
    case as_map(body) do
      {:ok, map} ->
        token_from_map(status, map)

      :error ->
        {:error, Error.invalid_response("HTTP #{status}: body is not a JSON object")}
    end
  end

  defp token_from_map(
         _status,
         %{"access_token" => at, "issued_token_type" => issued, "token_type" => type} = map
       )
       when is_binary(at) and is_binary(issued) and is_binary(type) do
    {:ok,
     %Token{
       access_token: at,
       issued_token_type: TokenType.from_urn(issued),
       token_type: type,
       expires_at: expires_at_from(map["expires_in"]),
       scope: map["scope"]
     }}
  end

  defp token_from_map(status, map) do
    # Name the missing fields rather than echoing the body: it may carry a
    # token, and this message ends up in logs.
    missing =
      ["access_token", "issued_token_type", "token_type"]
      |> Enum.reject(&is_binary(map[&1]))
      |> Enum.join(", ")

    {:error, Error.invalid_response("HTTP #{status}: token response is missing #{missing}")}
  end

  # A non-2xx body is an RFC 6749 error when it carries `error`; anything else —
  # a proxy's HTML, an empty body — is an invalid response with the status, since
  # it did not come from the token endpoint's contract.
  defp parse_error_body(status, body) do
    case as_map(body) do
      {:ok, %{"error" => error} = map} when is_binary(error) ->
        Error.server(status, error, map["error_description"])

      _ ->
        Error.invalid_response(
          "HTTP #{status} with a non-OAuth body: #{body |> to_snippet() |> String.slice(0, 200)}"
        )
    end
  end

  defp as_map(body) when is_map(body), do: {:ok, body}

  defp as_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp as_map(_body), do: :error

  defp to_snippet(body) when is_binary(body), do: body
  defp to_snippet(body), do: inspect(body)

  # --- Time ---

  @doc false
  def now_secs, do: System.os_time(:second)

  @doc false
  # `expires_at` is Unix seconds, never a monotonic reading: the token means the
  # same thing once written down or read by another SDK.
  def expires_at_from(nil), do: nil
  def expires_at_from(expires_in) when is_integer(expires_in), do: now_secs() + expires_in

  def expires_at_from(expires_in) when is_binary(expires_in) do
    case Integer.parse(expires_in) do
      {seconds, _} -> now_secs() + seconds
      :error -> nil
    end
  end

  def expires_at_from(_), do: nil
end
