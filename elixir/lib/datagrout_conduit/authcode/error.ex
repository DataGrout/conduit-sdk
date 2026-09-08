defmodule DatagroutConduit.AuthCode.Error do
  @moduledoc """
  Errors from the authorization-code flow.

  The taxonomy is part of the cross-language contract: every conduit SDK
  distinguishes these same cases, so callers can branch identically. Here that
  means matching on `:kind`:

      case DatagroutConduit.AuthCode.exchange(flow, pending, code, state) do
        {:ok, grant} -> grant
        {:error, %DatagroutConduit.AuthCode.Error{kind: :state_mismatch}} -> :csrf
        {:error, %DatagroutConduit.AuthCode.Error{kind: :token_exchange, status: s}} -> s
      end
  """

  defexception [:kind, :message, :status, :body]

  @type kind ::
          :discovery
          | :no_registration_endpoint
          | :registration_rejected
          | :no_client_id
          | :pkce_unsupported
          | :state_mismatch
          | :token_exchange
          | :not_refreshable
          | :denied
          | :http

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          status: integer() | nil,
          body: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg

  @doc "Metadata discovery failed or returned something unusable."
  @spec discovery(String.t()) :: t()
  def discovery(detail),
    do: %__MODULE__{kind: :discovery, message: "OAuth discovery failed: #{detail}"}

  @doc "The authorization server does not advertise dynamic client registration."
  @spec no_registration_endpoint() :: t()
  def no_registration_endpoint do
    %__MODULE__{
      kind: :no_registration_endpoint,
      message:
        "authorization server has no registration endpoint — register a client " <>
          "manually and use DatagroutConduit.AuthCode.with_client_id/3"
    }
  end

  @doc "Dynamic client registration was rejected."
  @spec registration_rejected(integer(), String.t()) :: t()
  def registration_rejected(status, body) do
    %__MODULE__{
      kind: :registration_rejected,
      message: "client registration rejected (HTTP #{status}): #{body}",
      status: status,
      body: body
    }
  end

  @doc "`authorize_url/1` was called before a client id was known."
  @spec no_client_id() :: t()
  def no_client_id do
    %__MODULE__{
      kind: :no_client_id,
      message: "no client_id — call register/3 or with_client_id/3 first"
    }
  end

  @doc """
  The server does not support PKCE with S256.

  Downgrading to `plain`, or to no PKCE at all, would defeat the point of the
  flow for a public client, so this is refused rather than negotiated.
  """
  @spec pkce_unsupported() :: t()
  def pkce_unsupported do
    %__MODULE__{
      kind: :pkce_unsupported,
      message: "authorization server does not support PKCE S256; refusing to downgrade"
    }
  end

  @doc """
  The `state` returned by the redirect did not match the one sent.

  A CSRF signal: the response belongs to a different authorization request.
  Never proceed past this.
  """
  @spec state_mismatch() :: t()
  def state_mismatch do
    %__MODULE__{
      kind: :state_mismatch,
      message: "state mismatch — the authorization response does not match this request"
    }
  end

  @doc "The token endpoint rejected the exchange or refresh."
  @spec token_exchange(integer(), String.t()) :: t()
  def token_exchange(status, body) do
    %__MODULE__{
      kind: :token_exchange,
      message: "token exchange failed (HTTP #{status}): #{body}",
      status: status,
      body: body
    }
  end

  @doc "The grant has no refresh token, so it cannot be renewed."
  @spec not_refreshable() :: t()
  def not_refreshable do
    %__MODULE__{
      kind: :not_refreshable,
      message: "grant has expired and carries no refresh_token — re-authorize"
    }
  end

  @doc "The authorization server returned an error at the redirect."
  @spec denied(String.t(), String.t() | nil) :: t()
  def denied(error, description \\ nil) do
    suffix = if description, do: " — #{description}", else: ""
    %__MODULE__{kind: :denied, message: "authorization denied: #{error}#{suffix}"}
  end

  @doc "Transport failure talking to the authorization server."
  @spec http(String.t()) :: t()
  def http(detail), do: %__MODULE__{kind: :http, message: detail}
end
