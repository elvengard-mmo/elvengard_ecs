defmodule ElvenGard.ECS.Query do
  @moduledoc """
  Read API for entities, components, and relationships.

  Queries are immutable descriptions built by `select/2` and executed by
  `all/1`, `all/2`, `one/1`, or `one/2`. Convenience functions provide direct
  lookups for an entity and its components.

  Reads are delegated to the backend configured under `:elvengard_ecs`.
  """

  alias __MODULE__
  alias ElvenGard.ECS.{Bundle, Component, Config, Entity}

  ## Struct

  defstruct [:return_type, :components, :mandatories, :preload_all, :return_entity, :partition]

  @typep component_module :: module()

  @typedoc "A backend match operator, component field, and expected value."
  @type component_filter :: {atom(), atom(), term()}

  @typedoc "A component module, optionally constrained by field filters."
  @type query_component :: component_module() | {component_module(), [component_filter()]}

  @typedoc "Entity, component, or tuple shape returned by a query."
  @type return_type :: Entity | component_module() | tuple()

  @typedoc "A value returned by `all/1` or `one/1`."
  @type result :: {Entity.t(), [Component.t()]} | Component.t() | tuple()

  @typedoc "A query tuple materialized into an application bundle."
  @type bundle_result :: Bundle.t()

  @typedoc "An executable query description."
  @type t :: %Query{
          return_type: return_type(),
          components: [query_component()],
          mandatories: [component_module()],
          preload_all: boolean(),
          return_entity: boolean(),
          partition: :any | Entity.partition()
        }

  ## General

  @doc """
  Builds a query for entities, components, or a tuple of both.

  The return type controls each result:

    * `ElvenGard.ECS.Entity` returns `{entity, components}`
    * a component module returns matching component structs
    * a tuple such as `{ElvenGard.ECS.Entity, Position}` returns tuples with
      the requested values; optional missing components are returned as `nil`

  Supported options are:

    * `:with` - component modules that every result must contain. A component
      can be constrained with `{module, [{operator, field, value}]}`. Pass
      `:selected` to require every component module in the return type.
    * `:preload` - component modules included with entity results, or `:all`.
    * `:partition` - restricts results to one partition; defaults to `:any`.

  Component modules named in a tuple return type are loaded automatically.
  """
  @spec select(return_type(), Keyword.t()) :: t()
  def select(type, query \\ []) do
    with_components = normalize_with_components(type, Keyword.get(query, :with, []))
    preload = Keyword.get(query, :preload, [])
    partition = Keyword.get(query, :partition, :any)

    preload_list =
      case preload do
        :all -> []
        value -> value
      end

    preload_list =
      case type do
        tuple when is_tuple(tuple) ->
          tuple
          |> Tuple.to_list()
          |> Enum.reject(&(&1 == Entity))
          |> then(&[&1 | preload_list])

        _ ->
          preload_list
      end

    components =
      [with_components | preload_list]
      |> List.flatten()
      |> Enum.uniq_by(&component_module/1)

    component_mods = Enum.map(components, &component_module/1)
    mandatories = Enum.map(with_components, &component_module/1)

    {components, mandatories} =
      add_return_type(type, components, mandatories, component_mods)

    return_entity =
      case type do
        Entity -> true
        value when is_tuple(value) -> Entity in Tuple.to_list(type)
        _ -> false
      end

    %Query{
      return_type: type,
      components: components,
      mandatories: mandatories,
      preload_all: preload == :all,
      return_entity: return_entity,
      partition: partition
    }
  end

  @doc "Executes a query and returns all matching results."
  @spec all(Query.t()) :: [result()]
  def all(%Query{} = query) do
    Config.backend().all(query)
  end

  @doc "Executes a tuple query and materializes every result into `bundle_module`."
  @spec all(Query.t(), into: module()) :: [bundle_result()]
  def all(%Query{} = query, into: bundle_module) when is_atom(bundle_module) do
    results = Config.backend().all(query)
    Bundle.load_many(bundle_module, query.return_type, results)
  end

  @doc """
  Executes a query expected to match at most one result.

  Returns `nil` when there is no match and raises when more than one result is
  returned.
  """
  @spec one(Query.t()) :: result() | nil
  def one(%Query{} = query) do
    query |> all() |> one_result()
  end

  @doc "Executes a tuple query and materializes its single result into `bundle_module`."
  @spec one(Query.t(), into: module()) :: bundle_result() | nil
  def one(%Query{} = query, into: bundle_module) when is_atom(bundle_module) do
    query
    |> all(into: bundle_module)
    |> one_result()
  end

  @doc """
  Selects entities using one direct backend criterion.

  The default backend supports `with_parent: entity`,
  `without_parent: entity`, and `with_component: module`.
  """
  @spec select_entities(Keyword.t()) :: {:ok, [Entity.t()]}
  def select_entities(query) do
    Config.backend().select_entities(query)
  end

  ## Entities

  @doc """
  Fetches an entity by its ID.
  """
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
    Config.backend().fetch_entity(id)
  end

  @doc """
  Returns the partition for the given entity.
  """
  @spec partition(Entity.t()) :: {:ok, Entity.partition()} | {:error, :not_found}
  def partition(%Entity{} = entity) do
    Config.backend().partition(entity)
  end

  ## Relationships

  @doc """
  Returns the direct parent of an entity, or `nil` for a root entity.
  """
  @spec parent(Entity.t()) :: {:ok, nil | Entity.t()} | {:error, :not_found}
  def parent(%Entity{} = entity) do
    Config.backend().parent(entity)
  end

  @doc """
  Returns the direct children of an entity.
  """
  @spec children(Entity.t()) :: {:ok, [Entity.t()]}
  def children(%Entity{} = entity) do
    Config.backend().children(entity)
  end

  @doc """
  Returns whether the first entity is the direct parent of the second entity.
  """
  @spec parent_of?(Entity.t(), Entity.t()) :: boolean()
  def parent_of?(%Entity{} = maybe_parent, %Entity{} = maybe_child) do
    Config.backend().parent_of?(maybe_parent, maybe_child)
  end

  @doc """
  Returns whether the first entity is a direct child of the second entity.
  """
  @spec child_of?(Entity.t(), Entity.t()) :: boolean()
  def child_of?(%Entity{} = maybe_child, %Entity{} = maybe_parent) do
    Config.backend().parent_of?(maybe_parent, maybe_child)
  end

  ## Components

  @doc """
  Lists all components owned by an entity.

  This lookup does not separately verify that the entity exists, so an unknown
  entity and an entity without components both return `{:ok, []}`.
  """
  @spec list_components(Entity.t()) :: {:ok, [Component.t()]}
  def list_components(%Entity{} = entity) do
    Config.backend().list_components(entity)
  end

  @doc """
  Fetches every component of one module owned by an entity.

  Multiple components of the same module are supported. This lookup does not
  separately verify that the entity exists.
  """
  @spec fetch_components(Entity.t(), module()) :: {:ok, [Component.t()]}
  def fetch_components(%Entity{} = entity, component) when is_atom(component) do
    Config.backend().fetch_components(entity, component)
  end

  @doc """
  Fetches the single component of one module owned by an entity.

  Returns `{:error, :not_found}` when there is no match and raises when the
  entity owns multiple components of that module. Use `fetch_components/2`
  when multiple values are valid.
  """
  @spec fetch_component(Entity.t(), module()) :: {:ok, Component.t()} | {:error, :not_found}
  def fetch_component(%Entity{} = entity, component) when is_atom(component) do
    case Config.backend().fetch_components(entity, component) do
      {:ok, []} -> {:error, :not_found}
      {:ok, [component]} -> {:ok, component}
      _ -> raise "#{inspect(entity)} have more that 1 component of type #{inspect(component)}"
    end
  end

  ## Private function

  defp one_result(results) do
    case results do
      [] -> nil
      [result] -> result
      values -> raise "Expected to return one result, got: `#{inspect(values)}`"
    end
  end

  defp normalize_with_components(type, :selected), do: selected_components(type)
  defp normalize_with_components(_type, components) when is_list(components), do: components

  defp selected_components(type) when is_tuple(type) do
    type
    |> Tuple.to_list()
    |> Enum.reject(&(&1 == Entity))
  end

  defp selected_components(Entity), do: []
  defp selected_components(component), do: [component]

  defp add_return_type(type, components, mandatories, component_mods) do
    case type do
      Entity ->
        {components, mandatories}

      value when is_tuple(value) ->
        {components, mandatories}

      _ ->
        if type in component_mods,
          do: {components, mandatories},
          else: {[type | components], [type | mandatories]}
    end
  end

  defp component_module({module, _attrs}) when is_atom(module), do: module
  defp component_module(module) when is_atom(module), do: module
end
