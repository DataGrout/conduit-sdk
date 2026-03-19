defmodule DatagroutConduit.Flow do
  @moduledoc "Workflow execution, routing, human-in-the-loop, and execution history."

  @doc """
  Execute a multi-step workflow plan (`data-grout/flow.into`).

  ## Params

    * `"plan"` - Ordered list of tool call step descriptors (required)
    * `"validate_ctc"` - Validate each call against its CTC schema (default: `true`)
    * `"save_as_skill"` - Persist the flow as a reusable skill (default: `false`)
    * `"input_data"` - Runtime input data for the flow
  """
  @spec run(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def run(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "flow.into", opts)
  end

  @doc "Conditional dispatch with predicate-based branching (`data-grout/flow.route`)."
  @spec route(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def route(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "flow.route", opts)
  end

  @doc """
  Pause workflow for human approval (`data-grout/flow.request-approval`).

  Use for destructive or policy-gated actions.

  ## Params

    * `"action"` - Name of the action (required)
    * `"details"` - Action-specific payload
    * `"reason"` - Why approval is requested
    * `"context"` - Workflow context
  """
  @spec request_approval(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def request_approval(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "flow.request-approval", opts)
  end

  @doc """
  Request user clarification for missing fields (`data-grout/flow.request-feedback`).

  Pauses until user provides values.

  ## Params

    * `"missing_fields"` - List of field names (required)
    * `"reason"` - Why this information is needed (required)
    * `"current_data"` - Data already collected
    * `"suggestions"` - Suggestions per field
    * `"context"` - Workflow context
  """
  @spec request_feedback(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def request_feedback(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "flow.request-feedback", opts)
  end

  @doc """
  List recent tool executions (`data-grout/inspect.execution-history`).

  ## Params

    * `"limit"` - Max results (default: 50)
    * `"offset"` - Pagination offset
    * `"status"` - Filter by success, error, timeout
    * `"refractions_only"` - Only refraction executions
  """
  @spec history(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def history(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "inspect.execution-history", opts)
  end

  @doc """
  Get details and transcript for a specific execution (`data-grout/inspect.execution-details`).

  ## Params

    * `"execution_id"` - Unique execution ID (required)
  """
  @spec details(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def details(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "inspect.execution-details", opts)
  end
end
