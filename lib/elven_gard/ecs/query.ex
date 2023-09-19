defmodule ElvenGard.ECS.Query do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Read from Backend
  """

  alias __MODULE__
  alias ElvenGard.ECS.{Component, Config, Entity}

  ## Struct

  defstruct [:return_type, :with_components, :preload]

  @typep component_module :: module()
  @type t :: %Query{
          return_type: Entity | component_module(),
          with_components: [component_module() | {component_module(), [tuple()]}],
          preload: [component_module()]
        }

  ## General

  @spec select(Entity | module(), Keyword.t()) :: t()
  def select(type, query \\ []) do
    with_components = Keyword.get(query, :with, [])
    preload = Keyword.get(query, :preload, [])

    # If the return type is not part of with_components, add it to with_components
    extended_with_components =
      case type do
        Entity ->
          with_components

        module ->
          component_mods = Enum.map(with_components, &components_modules/1)
          if module in component_mods, do: with_components, else: [module | with_components]
      end

    # Get all required components modules
    extended_component_mods = Enum.map(extended_with_components, &components_modules/1)

    # Remove required components from preloads
    cleaned_preload = preload -- extended_component_mods

    %Query{
      return_type: type,
      with_components: extended_with_components,
      preload: cleaned_preload
    }
  end

  @spec all(Query.t()) :: list()
  def all(%Query{} = query) do
    Config.backend().all(query)
  end

  @spec select_entities(Keyword.t()) :: {:ok, [Entity.t()]}
  def select_entities(query) do
    Config.backend().select_entities(query)
  end

  ## Entities

  @doc """
  Fetches an `ElvenGard.ECS.Entity.t()` by its ID.
  """
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
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
  @spec list_components(Entity.t()) :: {:ok, [Component.t()]}
  def list_components(%Entity{} = entity) do
    Config.backend().list_components(entity)
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

  ## Helpers

  defp components_modules({module, _attrs}) when is_atom(module), do: module
  defp components_modules(module) when is_atom(module), do: module
end
