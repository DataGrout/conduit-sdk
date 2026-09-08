defmodule DatagroutConduit.AuthCode.Provider do
  @moduledoc """
  Holds a `DatagroutConduit.AuthCode.Grant` and keeps its access token fresh.

  Mirrors `DatagroutConduit.OAuth` — a GenServer with `get_token/1` and
  `invalidate/1` — so both grant types reach the transports through the same
  path: `get_token` on the way out, `invalidate` on a 401.

  DataGrout rotates refresh tokens, so a refresh produces a grant the
  application needs to write back. `take_if_dirty/1` is how it finds out:

      {:ok, provider} = Provider.start_link(grant: grant)
      # ...later, periodically or once on shutdown:
      case Provider.take_if_dirty(provider) do
        {:ok, rotated} -> save(rotated)
        :clean -> :ok
      end
  """

  use GenServer

  require Logger

  alias DatagroutConduit.AuthCode.{Error, Grant}

  defstruct [:grant, dirty: false, refresh: nil, waiters: []]

  # --- Public API ---

  @doc """
  Start a provider around a grant.

  ## Options

    * `:grant` - the `Grant` to hold (required)
    * `:name` - GenServer registration name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The current access token, refreshing first if it is at or near expiry."
  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_token(provider), do: GenServer.call(provider, :get_token, 30_000)

  @doc "A snapshot of the current grant, for persisting."
  @spec grant(GenServer.server()) :: Grant.t()
  def grant(provider), do: GenServer.call(provider, :grant)

  @doc "Whether the grant changed since the last `take_if_dirty/1`."
  @spec dirty?(GenServer.server()) :: boolean()
  def dirty?(provider), do: GenServer.call(provider, :dirty?)

  @doc """
  Return the grant if it has changed since the last call, clearing the flag.

  The intended use is a persistence loop: call periodically and write whatever
  comes back, so a rotated refresh token is never lost.
  """
  @spec take_if_dirty(GenServer.server()) :: {:ok, Grant.t()} | :clean
  def take_if_dirty(provider), do: GenServer.call(provider, :take_if_dirty)

  @doc "Force the next `get_token/1` to refresh. Call on a 401."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(provider), do: GenServer.cast(provider, :invalidate)

  @doc """
  Start a provider from whatever an `:authorization_code` auth option carried,
  or return `:none` when it carried nothing.

  Accepts a running provider (a pid or registered name) the caller keeps, so a
  rotated refresh token can be written back; a `Grant`; or a grant map straight
  from JSON.
  """
  @spec from_auth(term()) :: {:ok, GenServer.server()} | :none | {:error, term()}
  def from_auth(nil), do: :none
  def from_auth(pid) when is_pid(pid), do: {:ok, pid}
  def from_auth(name) when is_atom(name), do: {:ok, name}
  def from_auth(%Grant{} = grant), do: start_link(grant: grant)

  def from_auth(map) when is_map(map) do
    map
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
    |> Grant.from_map()
    |> then(&start_link(grant: &1))
  end

  def from_auth(other) do
    {:error,
     "authorization_code must be a Grant, a grant map, or a running " <>
       "AuthCode.Provider (got #{inspect(other)})"}
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{grant: Keyword.fetch!(opts, :grant)}}
  end

  @impl true
  def handle_call(:get_token, from, state) do
    if Grant.expired?(state.grant) do
      # The refresh runs in its own process and the caller is parked until it
      # lands. Doing it inline would block this GenServer for the whole round
      # trip: `grant`, `dirty?` and `take_if_dirty` would stop answering, a
      # persistence loop would stall behind a slow token endpoint, and a hung
      # one would time every caller out while leaving the server wedged.
      {:noreply, join_refresh(state, from)}
    else
      {:reply, {:ok, state.grant.access_token}, state}
    end
  end

  def handle_call(:grant, _from, state), do: {:reply, state.grant, state}

  def handle_call(:dirty?, _from, state), do: {:reply, state.dirty, state}

  def handle_call(:take_if_dirty, _from, state) do
    if state.dirty do
      {:reply, {:ok, state.grant}, %{state | dirty: false}}
    else
      {:reply, :clean, state}
    end
  end

  @impl true
  def handle_cast(:invalidate, state) do
    # Expire in the past rather than clearing the token: the refresh token is
    # what matters, and dropping the grant would make recovery impossible.
    {:noreply, %{state | grant: %{state.grant | expires_at: 0}}}
  end

  # The refresh finished and reported an outcome.
  @impl true
  def handle_info({:refreshed, pid, result}, %{refresh: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(state, result)}
  end

  # The refresh process died without reporting — a raise rather than an error
  # tuple. Waiters get an answer either way; a silent hang would be worse.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{refresh: {pid, ref}} = state) do
    {:noreply, settle(state, {:error, Error.http("token refresh crashed: #{inspect(reason)}")})}
  end

  # A straggler from a refresh we already settled.
  def handle_info(_message, state), do: {:noreply, state}

  # --- Internal ---

  # Park this caller on the in-flight refresh, starting one if none is running.
  # Concurrent callers therefore cost one request and share one outcome, rather
  # than each launching their own against an endpoint that may be struggling.
  defp join_refresh(state, from) do
    state = %{state | waiters: [from | state.waiters]}

    if state.refresh do
      state
    else
      %{state | refresh: spawn_refresh(state.grant)}
    end
  end

  defp spawn_refresh(grant) do
    parent = self()

    # `$callers` is how Task propagates process ownership; spawn_monitor does
    # not set it, and without it the refresh would escape the test HTTP stub
    # that the calling process registered. Monitored rather than linked so a
    # crash in the refresh cannot take the provider down with it.
    callers = [parent | Process.get(:"$callers", [])]

    spawn_monitor(fn ->
      Process.put(:"$callers", callers)
      send(parent, {:refreshed, self(), Grant.refresh(grant)})
    end)
  end

  # Answer everyone waiting, then clear the in-flight slot so a later expiry
  # starts a fresh attempt.
  defp settle(state, result) do
    reply =
      case result do
        {:ok, refreshed} -> {:ok, refreshed.access_token}
        {:error, _} = err -> err
      end

    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    state = %{state | refresh: nil, waiters: []}

    case result do
      {:ok, refreshed} ->
        Logger.debug("conduit: refreshed authorization-code grant")
        %{state | grant: refreshed, dirty: true}

      {:error, _} ->
        state
    end
  end
end
