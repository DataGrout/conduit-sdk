defmodule DatagroutConduit.Ephemerals do
  @moduledoc "Cache management: list and inspect cached results."

  @doc "List cached results (`data-grout/ephemerals.list`)."
  @spec list(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def list(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "ephemerals.list", opts)
  end

  @doc "Inspect a specific cache entry (`data-grout/ephemerals.inspect`)."
  @spec inspect(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def inspect(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "ephemerals.inspect", opts)
  end
end
