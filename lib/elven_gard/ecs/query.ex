defmodule ElvenGard.ECS.Query do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query
  """

  alias ElvenGard.ECS.{Config, Entity}

  ## Guards

  defguardp is_entity_id(id) when is_binary(id) or is_integer(id)

  ## Entities

  @doc """
  TODO: Documentation
  """
  @spec spawn_entity(Entity.entity_spec()) :: {:ok, Entity.t()} | {:error, :already_spawned}
  def spawn_entity(specs) when is_map(specs) do
    Config.backend().spawn_entity(specs)
  end

  @doc """
  TODO: Documentation
  """
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) when is_entity_id(id) do
    Config.backend().fetch_entity(id)
  end

  # Relationships

  @doc """
  TODO: Documentation
  """
  @spec parent(Entity.t()) :: {:ok, nil | Entity.t()} | {:error, :not_found}
  def parent(%Entity{} = entity) do
    Config.backend().parent(entity)
  end

  @doc """
  TODO: Documentation
  """
  @spec children(Entity.t()) :: {:ok, [Entity.t()]}
  def children(%Entity{} = entity) do
    Config.backend().children(entity)
  end
end
