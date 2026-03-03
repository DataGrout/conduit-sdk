defmodule DatagroutConduit.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DataGrout/conduit-sdk"

  def project do
    [
      app: :datagrout_conduit,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "DataGrout Conduit",
      description: "Production-ready MCP client with mTLS, OAuth 2.1, and semantic discovery",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :public_key]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:castore, "~> 1.0"},
      {:mox, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "datagrout_conduit",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "DataGrout Library" => "https://library.datagrout.ai"
      },
      maintainers: ["DataGrout <hello@datagrout.ai>"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
