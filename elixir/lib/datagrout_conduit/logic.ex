defmodule DatagroutConduit.Logic do
  @moduledoc "Persistent agent memory backed by a Prolog logic cell."

  @doc """
  Assert facts into the logic cell (`data-grout/logic.remember`).

  ## Params

    * `"statement"` - Natural language statement (mutually exclusive with `"facts"`)
    * `"facts"` - Pre-structured fact list (mutually exclusive with `"statement"`)
    * `"tag"` - Tag/namespace for grouping facts (default: `"default"`)
  """
  @spec remember(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def remember(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.remember", opts)
  end

  @doc """
  Query the logic cell (`data-grout/logic.query`).

  ## Params

    * `"question"` - Natural language question (mutually exclusive with `"patterns"`)
    * `"patterns"` - Pre-built pattern list (mutually exclusive with `"question"`)
    * `"limit"` - Maximum results (default: 50)
  """
  @spec query(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def query(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.query", opts)
  end

  @doc """
  Retract facts from the logic cell (`data-grout/logic.forget`).

  ## Params

    * `"handles"` - Specific fact handles to retract
    * `"pattern"` - Pattern to match and retract facts
  """
  @spec forget(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def forget(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.forget", opts)
  end

  @doc """
  Reflect on the logic cell (`data-grout/logic.reflect`).

  ## Params

    * `"entity"` - Optional entity name to scope reflection
    * `"summary_only"` - Return only counts (default: false)
  """
  @spec reflect(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def reflect(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.reflect", opts)
  end

  @doc """
  Add a constraint rule (`data-grout/logic.constrain`).

  ## Params

    * `"rule"` - Natural language rule (required)
    * `"tag"` - Tag/namespace (default: `"constraint"`)
  """
  @spec constrain(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def constrain(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.constrain", opts)
  end

  @doc "Hydrate the logic cell from external data (`data-grout/logic.hydrate`)."
  @spec hydrate(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def hydrate(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.hydrate", opts)
  end

  @doc "Export the logic cell contents (`data-grout/logic.export`)."
  @spec export_cell(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def export_cell(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.export", opts)
  end

  @doc "Import facts into the logic cell (`data-grout/logic.import`)."
  @spec import_cell(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def import_cell(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.import", opts)
  end

  @doc "Tabulate logic cell contents (`data-grout/logic.tabulate`)."
  @spec tabulate(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def tabulate(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.tabulate", opts)
  end

  @doc "Manage hypothetical worlds (`data-grout/logic.worlds`)."
  @spec worlds(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def worlds(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "logic.worlds", opts)
  end
end
