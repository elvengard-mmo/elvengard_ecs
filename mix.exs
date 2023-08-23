defmodule ElvenGard.ECS.MixProject do
  use Mix.Project

  @app_name "ElvenGard.ECS"
  @version "0.1.0"
  @github_link "https://github.com/ImNotAVirus/elvengard_ecs"

  def project do
    [
      app: :elvengard_network,
      version: @version,
      elixir: "~> 1.13",
      name: @app_name,
      description: "Game server toolkit written in Elixir # ECS",
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
