defmodule ElvenGard.ECS.Query do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Read from Backend
  """

  alias ElvenGard.ECS.{Component, Config, Entity}

  ## Guards

  defguardp is_entity_id(id) when is_binary(id) or is_integer(id)

  ## Entities

  @doc """
  TODO: Documentation
  """
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) when is_entity_id(id) do
    Config.backend().fetch_entity(id)
  end

  ## Relationships

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

  ## Components

  @spec components(Entity.t()) :: {:ok, [Component.t()]}
  def components(%Entity{} = entity) do
    Config.backend().components(entity)
  end
end
