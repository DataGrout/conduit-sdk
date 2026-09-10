defmodule DatagroutConduit.Delegation.Error do
  @moduledoc """
  Errors from a delegated-token exchange.

  The taxonomy is part of the cross-language contract: every conduit SDK
  distinguishes these same five cases under the same names, so callers branch
  identically. Here that means matching on `:kind`:

      case DatagroutConduit.Delegation.exchange(request) do
        {:ok, token} -> token
        {:error, %DatagroutConduit.Delegation.Error{kind: :missing_actor}} -> :misconfigured
        {:error, %DatagroutConduit.Delegation.Error{kind: :server, error: code}} -> code
      end

  A failure from an upstream `DatagroutConduit.Delegation.TokenSource` — the
  provider that owns the subject or actor token — is **not** one of these. It is
  propagated as that provider's own reason (an `%DatagroutConduit.AuthCode.Error{}`,
  or whatever `DatagroutConduit.OAuth` reported), because it did not come from
  the exchange.
  """

  defexception [:kind, :message, :status, :error, :error_description]

  @type kind :: :missing_subject | :missing_actor | :http | :server | :invalid_response

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          status: integer() | nil,
          error: String.t() | nil,
          error_description: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg

  @doc "No subject token was set — there is nobody to act for."
  @spec missing_subject() :: t()
  def missing_subject do
    %__MODULE__{
      kind: :missing_subject,
      message: "no subject_token — call DatagroutConduit.Delegation.subject_token/3 first"
    }
  end

  @doc """
  No actor token was set and the request is not an impersonation.

  Delegation is the default because it is what DataGrout requires and what
  leaves an audit trail. If the server really is meant to issue a token with no
  `act` claim, say so with `DatagroutConduit.Delegation.impersonation/1`.
  """
  @spec missing_actor() :: t()
  def missing_actor do
    %__MODULE__{
      kind: :missing_actor,
      message:
        "no actor_token — delegation requires one; call impersonation/1 to opt out explicitly"
    }
  end

  @doc "Transport failure talking to the token endpoint."
  @spec http(String.t()) :: t()
  def http(detail), do: %__MODULE__{kind: :http, message: detail}

  @doc """
  The token endpoint refused, with an RFC 6749 error body.

  `error` is one of `DatagroutConduit.Delegation.server_error_codes/0`.
  """
  @spec server(integer(), String.t(), String.t() | nil) :: t()
  def server(status, error, description \\ nil) do
    suffix = if description, do: " — #{description}", else: ""

    %__MODULE__{
      kind: :server,
      message: "delegated exchange refused (HTTP #{status}): #{error}#{suffix}",
      status: status,
      error: error,
      error_description: description
    }
  end

  @doc """
  The endpoint answered with something that is not an RFC 8693 response.

  A success body missing a required field, or a failure whose body is not an
  RFC 6749 error — a proxy's HTML, an empty body.
  """
  @spec invalid_response(String.t()) :: t()
  def invalid_response(detail) do
    %__MODULE__{
      kind: :invalid_response,
      message: "invalid delegated exchange response: #{detail}"
    }
  end
end
