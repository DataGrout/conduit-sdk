defmodule DatagroutConduit.GuidedSession do
  @moduledoc """
  Wraps a guided execution session, providing `choose/2` and `complete/1`.

  A guided session is started via the `guide` extension on the client and
  walks the user through a multi-step tool selection workflow.

  ## Usage

      {:ok, session} = DatagroutConduit.GuidedSession.start(client, goal: "send an email")
      session = DatagroutConduit.GuidedSession.choose(session, 0)
      {:ok, result} = DatagroutConduit.GuidedSession.complete(session)
  """

  alias DatagroutConduit.{Client, Types}

  @type t :: %__MODULE__{
          client: GenServer.server(),
          session_id: String.t() | nil,
          state: Types.GuideState.t()
        }

  defstruct [:client, :session_id, :state]

  @doc """
  Start a guided session for the given goal.

  ## Options

    * `:goal` - Natural language description of the goal (required)
  """
  @spec start(GenServer.server(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(client, opts) do
    case Client.guide(client, opts) do
      {:ok, %Types.GuideState{} = guide_state} ->
        {:ok,
         %__MODULE__{
           client: client,
           session_id: guide_state.session_id,
           state: guide_state
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Make a choice by option index and advance the session.

  Returns `{:ok, updated_session}` or `{:error, reason}`.
  """
  @spec choose(t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def choose(%__MODULE__{} = session, option_index) when is_integer(option_index) do
    option =
      case Enum.at(session.state.options, option_index) do
        nil -> nil
        opt -> opt
      end

    if option == nil do
      {:error, {:invalid_option, option_index, length(session.state.options)}}
    else
      case Client.guide(session.client,
             goal: option.tool_name || option.description || "continue",
             session_id: session.session_id,
             choice: option.tool_name
           ) do
        {:ok, %Types.GuideState{} = new_state} ->
          {:ok,
           %{session |
             session_id: new_state.session_id || session.session_id,
             state: new_state
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Complete the session and return the final result.

  Returns `{:ok, result}` if the session status is `"completed"`,
  or `{:error, reason}` if the workflow is not yet done.
  """
  @spec complete(t()) :: {:ok, map() | nil} | {:error, term()}
  def complete(%__MODULE__{state: %{status: "completed", result: result}}) do
    {:ok, result}
  end

  def complete(%__MODULE__{state: %{status: status}}) do
    {:error, {:not_completed, status}}
  end

  @doc "Returns the current options list."
  @spec options(t()) :: [Types.GuideOption.t()]
  def options(%__MODULE__{state: state}), do: state.options

  @doc "Returns the current session status."
  @spec status(t()) :: String.t() | nil
  def status(%__MODULE__{state: state}), do: state.status
end
