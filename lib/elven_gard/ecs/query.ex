defmodule ElvenGard.ECS.Query do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query
  """

  alias ElvenGard.ECS.{Config, Entity}

  ## Entities

  @doc """
  TODO: Documentation
  """
  @spec spawn_entity(Entity.entity_spec()) :: {:ok, Entity.t()} | {:error, :already_spawned}
  def spawn_entity(specs) do
    Config.backend().spawn_entity(specs)
  end

  @doc """
  TODO: Documentation
  """
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
    Config.backend().fetch_entity(id)
  end
end
