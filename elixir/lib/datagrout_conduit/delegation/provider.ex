defmodule DatagroutConduit.Delegation.Provider do
  @moduledoc """
  Keeps a delegated token fresh, re-exchanging when it nears expiry.

  The third token provider in this SDK, shaped like the other two —
  `DatagroutConduit.OAuth` and `DatagroutConduit.AuthCode.Provider` — so every
  transport reaches it through the same path: `get_token/1` on the way out,
  `invalidate/1` on a 401. Each exchange pulls a *fresh* subject and actor token
  from its `DatagroutConduit.Delegation.TokenSource`s, so an expiring upstream
  credential is handled by the provider that owns it.

      alias DatagroutConduit.Delegation
      alias DatagroutConduit.Delegation.{Provider, TokenSource}

      {:ok, provider} =
        Provider.start_link(
          request:
            Delegation.new("https://gateway.datagrout.ai/oauth/token", "agent_client_id")
            |> Delegation.client_secret("agent_client_secret"),
          subject: TokenSource.static_token(user_token, :access_token),
          actor: TokenSource.client_credentials(agent_oauth)
        )

      {:ok, bearer} = Provider.get_token(provider)

  ## Concurrency

  The exchange runs inside the process, so concurrent callers queue behind one
  another rather than stampeding the token endpoint; each waiter re-checks the
  cache on entry, so a leader that succeeded spares the rest the request
  entirely. Unlike `DatagroutConduit.AuthCode.Provider` there is no rotated
  refresh token to hand back, so nothing else needs to be asked of this process
  while an exchange is in flight.

  ## Secrets

  Nothing here logs or inspects a token or the client secret: the request
  template, the token and both sources redact themselves, and the debug line on
  a successful exchange names only the client id and the issued token type.
  """

  use GenServer

  require Logger

  alias DatagroutConduit.Delegation
  alias DatagroutConduit.Delegation.{Error, Token, TokenSource, TokenType}

  @derive {Inspect, only: [:request, :subject, :actor]}
  defstruct [:request, :subject, :actor, :cached]

  # --- Public API ---

  @doc """
  Start a provider around a request template and the sources of its two tokens.

  ## Options

    * `:request` — the `DatagroutConduit.Delegation` request template (required).
      Any `subject_token` or `actor_token` already on it is ignored; the sources
      supply them.
    * `:subject` — a `DatagroutConduit.Delegation.TokenSource` for the user's
      token (required)
    * `:actor` — a `TokenSource` for the agent's own token. Omit it only with a
      request that called `DatagroutConduit.Delegation.impersonation/1` —
      otherwise every `get_token/1` fails with `:missing_actor`, which is the
      intended loud failure rather than a silent downgrade.
    * `:name` — GenServer registration name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The current delegated bearer, exchanging first if there is none or it is at or
  near expiry.
  """
  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, Error.t() | term()}
  def get_token(provider), do: GenServer.call(provider, :get_token, 30_000)

  @doc "A snapshot of the cached token, if any — for inspection."
  @spec token(GenServer.server()) :: Token.t() | nil
  def token(provider), do: GenServer.call(provider, :token)

  @doc "The request template, without tokens."
  @spec request(GenServer.server()) :: Delegation.t()
  def request(provider), do: GenServer.call(provider, :request)

  @doc """
  Force the next `get_token/1` to exchange again. Call on a 401.

  Only the delegated token is dropped. The subject and actor sources are left
  alone: a provider-backed source tracks its own expiry, and a 401 from the
  resource server says nothing about them.
  """
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(provider), do: GenServer.cast(provider, :invalidate)

  @doc """
  Start a provider from whatever a `:delegation` auth option carried, or return
  `:none` when it carried nothing.

  Accepts a running provider (a pid or registered name), which is the usual
  case, or the keyword options `start_link/1` takes.
  """
  @spec from_auth(term()) :: {:ok, GenServer.server()} | :none | {:error, term()}
  def from_auth(nil), do: :none
  def from_auth(pid) when is_pid(pid), do: {:ok, pid}
  def from_auth(name) when is_atom(name), do: {:ok, name}

  def from_auth(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :request) do
      start_link(opts)
    else
      unusable(opts)
    end
  end

  def from_auth(other), do: unusable(other)

  defp unusable(value) do
    {:error,
     "delegation must be a running DatagroutConduit.Delegation.Provider, or the " <>
       "options to start one (got #{inspect(value)})"}
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       request: Keyword.fetch!(opts, :request),
       subject: Keyword.fetch!(opts, :subject),
       actor: Keyword.get(opts, :actor)
     }}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    case live_token(state) do
      {:ok, bearer} ->
        {:reply, {:ok, bearer}, state}

      :none ->
        case do_exchange(state) do
          {:ok, %Token{} = token} ->
            Logger.debug(
              "conduit: exchanged for a delegated token (client_id=#{state.request.client_id} " <>
                "issued=#{TokenType.to_urn(token.issued_token_type)})"
            )

            {:reply, {:ok, token.access_token}, %{state | cached: token}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:token, _from, state), do: {:reply, state.cached, state}

  def handle_call(:request, _from, state), do: {:reply, state.request, state}

  @impl true
  def handle_cast(:invalidate, state), do: {:noreply, %{state | cached: nil}}

  # --- Internal ---

  defp live_token(%__MODULE__{cached: %Token{} = token}) do
    if Token.expired?(token), do: :none, else: {:ok, token.access_token}
  end

  defp live_token(%__MODULE__{}), do: :none

  # Refuse before resolving anything: a missing actor is a configuration
  # mistake, and fetching a subject token first would only hide it.
  defp do_exchange(%__MODULE__{actor: nil, request: %Delegation{impersonation: false}}) do
    {:error, Error.missing_actor()}
  end

  defp do_exchange(%__MODULE__{} = state) do
    with {:ok, subject} <- TokenSource.resolve(state.subject),
         request =
           Delegation.subject_token(
             state.request,
             subject,
             TokenSource.token_type(state.subject)
           ),
         {:ok, request} <- put_actor(request, state.actor) do
      Delegation.exchange(request)
    end
  end

  defp put_actor(request, nil), do: {:ok, request}

  defp put_actor(request, %TokenSource{} = actor) do
    with {:ok, token} <- TokenSource.resolve(actor) do
      {:ok, Delegation.actor_token(request, token, TokenSource.token_type(actor))}
    end
  end
end
