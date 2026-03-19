defmodule DatagroutConduit.Warden do
  @moduledoc "Safety gates, intent verification, and multi-model consensus."

  @doc "Run a canary safety check (`data-grout/warden.canary`)."
  @spec canary(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def canary(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "warden.canary", opts)
  end

  @doc "Verify intent before executing an action (`data-grout/warden.intent`)."
  @spec verify_intent(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def verify_intent(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "warden.intent", opts)
  end

  @doc "Adjudicate a dispute or ambiguity (`data-grout/warden.adjudicate`)."
  @spec adjudicate(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def adjudicate(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "warden.adjudicate", opts)
  end

  @doc "Multi-model ensemble consensus check (`data-grout/warden.ensemble`)."
  @spec ensemble(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def ensemble(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "warden.ensemble", opts)
  end
end
