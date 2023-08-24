defmodule ElvenGard.ECS.Command do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Write in Backend
  """

  alias ElvenGard.ECS.{Config, Entity}

  ## Entities

  @doc """
  TODO: Documentation
  """
  @spec spawn_entity(Entity.entity_spec()) :: {:ok, Entity.t()} | {:error, :already_spawned}
  def spawn_entity(specs) when is_map(specs) do
    Config.backend().spawn_entity(specs)
  end

  ## Components
end
