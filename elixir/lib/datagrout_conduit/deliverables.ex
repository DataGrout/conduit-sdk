defmodule DatagroutConduit.Deliverables do
  @moduledoc "Work product registration, listing, and retrieval."

  @doc "Register a work product (`data-grout/deliverables.register`)."
  @spec register(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def register(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "deliverables.register", opts)
  end

  @doc "List deliverables with optional semantic search (`data-grout/deliverables.list`)."
  @spec list(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def list(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "deliverables.list", opts)
  end

  @doc "Get a specific deliverable by reference (`data-grout/deliverables.get`)."
  @spec get(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(client, ref_id) do
    DatagroutConduit.Client.dg(client, "deliverables.get", %{"ref" => ref_id})
  end
end
