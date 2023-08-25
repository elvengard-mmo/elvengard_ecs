defmodule ElvenGard.ECS.Query do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Read from Backend
  """

  alias ElvenGard.ECS.{Component, Config, Entity}

  ## Guards

  defguardp is_entity_id(id) when is_binary(id) or is_integer(id)

  ## General

  @spec select_entities(Keyword.t()) :: {:ok, [Entity.t()]}
  def select_entities(query) do
    Config.backend().select_entities(query)
  end

  ## Entities

  @doc """
  Fetches an `ElvenGard.ECS.Entity.t()` by its ID.
  """
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) when is_entity_id(id) do
    Config.backend().fetch_entity(id)
  end

  ## Relationships

  @doc """
  Returns the list of parent entities for the given entity.
  """
  @spec parent(Entity.t()) :: {:ok, nil | Entity.t()} | {:error, :not_found}
  def parent(%Entity{} = entity) do
    Config.backend().parent(entity)
  end

  @doc """
  Returns the list of child entities for the given entity.
  """
  @spec children(Entity.t()) :: {:ok, [Entity.t()]}
  def children(%Entity{} = entity) do
    Config.backend().children(entity)
  end

  @doc """
  Reurns `true` if a given entity is a parent of another entity.
  """
  @spec parent_of?(Entity.t(), Entity.t()) :: boolean()
  def parent_of?(%Entity{} = maybe_parent, %Entity{} = maybe_child) do
    Config.backend().parent_of?(maybe_parent, maybe_child)
  end

  @doc """
  Reurns `true` if a given entity is a child of another entity.
  """
  @spec child_of?(Entity.t(), Entity.t()) :: boolean()
  def child_of?(%Entity{} = maybe_child, %Entity{} = maybe_parent) do
    Config.backend().parent_of?(maybe_parent, maybe_child)
  end

  ## Components

  @doc """
  Lists all the components for a given entity.
  """
  @spec components(Entity.t()) :: {:ok, [Component.t()]}
  def components(%Entity{} = entity) do
    Config.backend().components(entity)
  end

  @doc """
  Fetches ALL components by there module for a given entity.
  """
  @spec fetch_components(Entity.t(), module()) :: {:ok, [Component.t()]}
  def fetch_components(%Entity{} = entity, component) when is_atom(component) do
    Config.backend().fetch_components(entity, component)
  end

  @doc """
  Fetches the component by its module for a given entity.
  """
  @spec fetch_component(Entity.t(), module()) :: {:ok, Component.t()} | {:error, :not_found}
  def fetch_component(%Entity{} = entity, component) when is_atom(component) do
    case Config.backend().fetch_components(entity, component) do
      {:ok, []} -> {:error, :not_found}
      {:ok, [component]} -> {:ok, component}
      _ -> raise "#{inspect(entity)} have more that 1 component of type #{inspect(component)}"
    end
  end
end
