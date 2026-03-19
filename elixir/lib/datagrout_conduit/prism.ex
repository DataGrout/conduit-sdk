defmodule DatagroutConduit.Prism do
  @moduledoc "Data transformation, charting, rendering, export, and type bridging."

  @doc """
  AI-driven data transformation (`data-grout/prism.refract`).

  ## Params

    * `"goal"` - Natural language transformation goal (required)
    * `"payload"` - Data to transform (required)
    * `"verbose"` - Include detailed trace
    * `"chart"` - Include a chart in output
  """
  @spec refract(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def refract(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "prism.refract", opts)
  end

  @doc """
  AI-driven charting (`data-grout/prism.chart`).

  ## Params

    * `"goal"` - Chart description (required)
    * `"payload"` - Data to chart (required)
    * `"format"` - Output format
    * `"chart_type"` - Chart type (bar, line, pie, etc.)
    * `"title"`, `"x_label"`, `"y_label"`, `"width"`, `"height"`
  """
  @spec chart(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def chart(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "prism.chart", opts)
  end

  @doc """
  Generate a document toward a natural-language goal (`data-grout/prism.render`).

  ## Params

    * `"goal"` - Natural language content description (required)
    * `"payload"` - Input data (optional)
    * `"format"` - Output format: markdown, html, pdf, json (default: markdown)
    * `"sections"` - Optional list of section specs
  """
  @spec render(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def render(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "prism.render", opts)
  end

  @doc """
  Convert content to another format without LLM (`data-grout/prism.export`).

  ## Params

    * `"content"` - Data or string to export (required)
    * `"format"` - Target format (required)
    * `"style"` - Optional styling options
    * `"metadata"` - Optional document metadata
  """
  @spec export(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def export(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "prism.export", opts)
  end

  @doc """
  Semantic type transformation (`data-grout/prism.focus`).

  ## Params

    * `"data"` - Data to transform (required)
    * `"source_type"` - Source type annotation (required)
    * `"target_type"` - Target type annotation (required)
    * `"source_annotations"` - Optional source schema hints
    * `"target_annotations"` - Optional target schema hints
    * `"context"` - Optional context string
  """
  @spec focus(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def focus(client, opts \\ %{}) do
    DatagroutConduit.Client.dg(client, "prism.focus", opts)
  end
end
