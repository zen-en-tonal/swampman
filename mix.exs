defmodule Swampman.MixProject do
  use Mix.Project

  @version "0.0.1"

  def project do
    [
      app: :swampman,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A library for pooling and managing resources",
      package: package(),
      source_url: "https://github.com/zen-en-tonal/swampman",
      homepage_url: "https://github.com/zen-en-tonal/swampman",
      docs: [
        main: "Swampman",
        extras: ["README.md", "LICENSE"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Takeru KODAMA"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/zen-en-tonal/swampman",
        "Docs" => "https://hexdocs.pm/swampman"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
