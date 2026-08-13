defmodule ElvenGard.ECS.MixProject do
  use Mix.Project

  @app_name "ElvenGard.ECS"
  @version "0.1.0"
  @github_link "https://github.com/ImNotAVirus/elvengard_ecs"

  def project() do
    [
      app: :elvengard_ecs,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      name: @app_name,
      description: "Game server toolkit written in Elixir # ECS",
      docs: docs(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      aliases: aliases()
    ]
  end

  def cli() do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application() do
    [
      extra_applications: [:logger, :crypto, :mnesia],
      mod: {ElvenGard.ECS.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps() do
    [
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases() do
    [
      precommit: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --cover"
      ]
    ]
  end

  defp docs() do
    [
      main: @app_name,
      source_ref: "v#{@version}",
      source_url: @github_link,
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras() do
    Enum.concat(
      ["README.md": [title: "Overview"]],
      [
        "CHANGELOG.md",
        "guides/introduction/getting_started.md",
        "guides/introduction/entities_and_components.md",
        "guides/introduction/queries.md",
        "guides/introduction/transactions_and_relationships.md",
        "guides/introduction/events_and_systems.md"
      ]
    )
  end

  defp groups_for_extras() do
    [
      Introduction: ~r/(README.md|guides\/introduction\/.?)/
    ]
  end

  defp groups_for_modules() do
    [
      Core: [
        ElvenGard.ECS,
        ElvenGard.ECS.Entity,
        ElvenGard.ECS.Component,
        ElvenGard.ECS.Bundle,
        ElvenGard.ECS.ChangeSet,
        ElvenGard.ECS.Command,
        ElvenGard.ECS.Multi,
        ElvenGard.ECS.Query,
        ElvenGard.ECS.Query.Source
      ],
      Topology: [
        ElvenGard.ECS.Event,
        ElvenGard.ECS.System,
        ElvenGard.ECS.Topology,
        ElvenGard.ECS.Topology.EventSource,
        ElvenGard.ECS.Topology.Partition
      ],
      Storage: [ElvenGard.ECS.MnesiaBackend]
    ]
  end
end
