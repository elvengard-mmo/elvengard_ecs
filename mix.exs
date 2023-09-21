defmodule ElvenGard.ECS.MixProject do
  use Mix.Project

  @app_name "ElvenGard.ECS"
  @version "0.1.0"
  # @github_link "https://github.com/ImNotAVirus/elvengard_ecs"

  def project do
    [
      app: :elvengard_ecs,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      name: @app_name,
      description: "Game server toolkit written in Elixir # ECS",
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :mnesia],
      mod: {ElvenGard.ECS.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end
end
