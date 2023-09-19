defmodule ElvenGard.ECS.MnesiaBackend do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.MnesiaBackend

  TODO: Write a module for Entities and Components serialization instead of having raw tuples

  Entity Table:

    | entity_id | parent_id or nil |

  Component Table

    | component_type | owner_id | component |

  """

  use Task

  import ElvenGard.ECS.MnesiaBackend.Records

  alias ElvenGard.ECS.Entity
  alias ElvenGard.ECS.Query
  alias ElvenGard.ECS.{Component, Entity}

  @timeout 5000

  ## Public API

  @spec start_link(Keyword.t()) :: Task.on_start()
  def start_link(_opts) do
    Task.start_link(__MODULE__, :init_mnesia, [])
  end

  ## Transactions

  @spec transaction((() -> result)) :: {:error, result} | {:ok, any()} when result: any()
  def transaction(query) do
    case :mnesia.transaction(query) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @spec abort(any()) :: no_return()
  def abort(reason) do
    :mnesia.abort(reason)
  end

  ## General Queries

  def all(query) do
    %Query{return_type: return_type, with_components: with_components, preload: preload} = query

    with_components
    |> Enum.flat_map(&query_components/1)
    |> Enum.group_by(&component(&1, :owner_id), &component(&1, :component))
    |> Enum.filter(&has_all_components(&1, with_components))
    |> Enum.map(fn {owner_id, components} ->
      entity = build_entity_struct(owner_id)
      {entity, components ++ do_preload(entity, preload)}
    end)
    |> Enum.flat_map(&select_return_type(&1, return_type))
  end

  # TODO: Rewrite this fuction to me more generic and support operators like
  # "and", "or" and "multiple queries"
  @spec select_entities(Keyword.t()) :: {:ok, [Entity.t()]}
  def select_entities(with_parent: parent) do
    Entity
    |> index_read(parent_id(parent), :parent_id)
    |> Enum.map(&record_to_struct/1)
    |> then(&{:ok, &1})
  end

  def select_entities(without_parent: parent) do
    match = {Entity, :"$1", :"$2"}
    guards = [{:"=/=", :"$2", escape_id(parent_id(parent))}]
    return = [:"$1"]
    query = [{match, guards, return}]

    Entity
    |> select(query)
    |> Enum.map(&build_entity_struct/1)
    |> then(&{:ok, &1})
  end

  def select_entities(with_component: component) when is_atom(component) do
    {Component, component}
    |> read()
    |> Enum.map(&component(&1, :owner_id))
    |> Enum.uniq()
    |> Enum.map(&build_entity_struct/1)
    |> then(&{:ok, &1})
  end

  ### Entities

  @spec create_entity(Entity.id(), Entity.t()) :: {:ok, Entity.t()} | {:error, :already_exists}
  def create_entity(id, parent) do
    entity = entity(id: id, parent_id: parent_id(parent))

    case insert_new(entity) do
      :ok -> {:ok, build_entity_struct(id)}
      {:error, :already_exists} = error -> error
    end
  end

  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
    case read({Entity, id}) do
      [entity] -> {:ok, record_to_struct(entity)}
      [] -> {:error, :not_found}
    end
  end

  @spec parent(Entity.t()) :: {:ok, nil | Entity.t()} | {:error, :not_found}
  def parent(%Entity{id: id}) do
    case read({Entity, id}) do
      [] -> {:error, :not_found}
      [{Entity, ^id, nil}] -> {:ok, nil}
      [{Entity, ^id, parent_id}] -> {:ok, build_entity_struct(parent_id)}
    end
  end

  @spec set_parent(Entity.t(), Entity.t()) :: :ok
  def set_parent(%Entity{id: id}, parent) do
    entity(id: id, parent_id: parent_id(parent))
    |> insert()
  end

  @spec children(Entity.t()) :: {:ok, [Entity.t()]}
  def children(%Entity{id: id}) do
    Entity
    |> index_read(id, :parent_id)
    # Keep only the id
    |> Enum.map(&entity(&1, :id))
    # Transform the id into an Entity struct
    |> Enum.map(&build_entity_struct/1)
    # Wrap into :ok tuple
    |> then(&{:ok, &1})
  end

  @spec parent_of?(Entity.t(), Entity.t()) :: boolean()
  def parent_of?(%Entity{id: parent_id}, %Entity{id: child_id}) do
    case read({Entity, child_id}) do
      [child_record] ->
        child_record
        # Get the parent_id
        |> entity(:parent_id)
        # Check if child.parent_id == parent_id
        |> Kernel.==(parent_id)

      [] ->
        false
    end
  end

  @spec delete_entity(Entity.t()) :: :ok
  def delete_entity(%Entity{id: id}) do
    delete({Entity, id})
  end

  ### Components

  @spec add_component(Entity.t(), Component.spec()) :: Component.t()
  def add_component(%Entity{id: id}, component_spec) do
    component = Component.spec_to_struct(component_spec)

    component
    |> then(&component(type: &1.__struct__, owner_id: id, component: &1))
    |> insert()

    component
  end

  @spec list_components(Entity.t()) :: {:ok, [Component.t()]}
  def list_components(%Entity{id: id}) do
    Component
    |> index_read(id, :owner_id)
    # Keep only the component
    |> Enum.map(&component(&1, :component))
    # Wrap into :ok tuple
    |> then(&{:ok, &1})
  end

  @spec fetch_components(Entity.t(), module()) :: {:ok, [Component.t()]}
  def fetch_components(%Entity{id: owner_id}, component) do
    # TODO: Generate the select query
    match = {Component, :"$1", :"$2", :"$3"}
    guards = [{:==, :"$1", component}, {:==, :"$2", escape_id(owner_id)}]
    result = [:"$3"]
    query = [{match, guards, result}]

    {:ok, select(Component, query)}
  end

  @spec delete_components_for(Entity.t()) :: {:ok, [Component.t()]}
  def delete_components_for(%Entity{id: owner_id}) do
    components = index_read(Component, owner_id, :owner_id)
    Enum.each(components, &delete_object(&1))
    {:ok, Enum.map(components, &component(&1, :component))}
  end

  ## Internal API

  @doc false
  @spec init_mnesia() :: :ok
  def init_mnesia() do
    # Create tables
    {:atomic, :ok} =
      :mnesia.create_table(
        Entity,
        type: :set,
        attributes: [:id, :parent_id],
        index: [:parent_id]
      )

    {:atomic, :ok} =
      :mnesia.create_table(
        Component,
        type: :bag,
        attributes: [:type, :owner_id, :component],
        index: [:owner_id]
      )

    :ok = :mnesia.wait_for_tables([Entity, Component], @timeout)
  end

  ## Private Helpers

  defp parent_id(nil), do: nil
  defp parent_id(%Entity{id: id}), do: id

  defp build_entity_struct(id), do: %Entity{id: id}

  # I don't know why but you need to wrap tuples inside another tuple in select/dirty_select
  defp escape_id(id) when is_tuple(id), do: {id}
  defp escape_id(id), do: id

  defp record_to_struct(entity_record) do
    entity_record
    |> entity(:id)
    |> build_entity_struct()
  end

  defp delete(tuple) do
    case :mnesia.is_transaction() do
      true -> :mnesia.delete(tuple)
      false -> :mnesia.dirty_delete(tuple)
    end
  end

  defp delete_object(object) do
    case :mnesia.is_transaction() do
      true -> :mnesia.delete_object(object)
      false -> :mnesia.dirty_delete_object(object)
    end
  end

  defp read(tuple) do
    case :mnesia.is_transaction() do
      true -> :mnesia.read(tuple)
      false -> :mnesia.dirty_read(tuple)
    end
  end

  defp index_read(tab, key, attr) do
    case :mnesia.is_transaction() do
      true -> :mnesia.index_read(tab, key, attr)
      false -> :mnesia.dirty_index_read(tab, key, attr)
    end
  end

  defp select(tab, query) do
    case :mnesia.is_transaction() do
      true -> :mnesia.select(tab, query)
      false -> :mnesia.dirty_select(tab, query)
    end
  end

  defp insert(record) do
    case :mnesia.is_transaction() do
      true -> :mnesia.write(record)
      false -> :mnesia.dirty_write(record)
    end
  end

  defp insert_new(record) do
    do_insert_new(
      elem(record, 0),
      elem(record, 1),
      record,
      :mnesia.is_transaction()
    )
  end

  defp do_insert_new(type, key, record, false) do
    case :mnesia.dirty_read({type, key}) do
      [] -> :mnesia.dirty_write(record)
      _ -> {:error, :already_exists}
    end
  end

  defp do_insert_new(type, key, record, true) do
    case :mnesia.wread({type, key}) do
      [] -> :mnesia.write(record)
      _ -> :mnesia.abort(:already_exists)
    end
  end

  defp query_components(type) when is_atom(type) do
    read({Component, type})
  end

  defp query_components({type, specs}) do
    # TODO: Generate the select query
    match = {Component, :"$1", :_, :"$3"}
    guards = Enum.map(specs, fn {op, field, value} -> {op, {:map_get, field, :"$3"}, value} end)
    guards = [{:==, :"$1", type} | guards]
    result = [:"$_"]
    query = [{match, guards, result}]

    select(Component, query)
  end

  defp has_all_components({_entity_id, components}, required_list) do
    required_modules =
      required_list
      |> Enum.map(fn
        {module, _attrs} -> module
        module -> module
      end)
      |> Enum.uniq()

    component_modules = components |> Enum.map(& &1.__struct__) |> Enum.uniq()

    required_modules -- component_modules == []
  end

  defp do_preload(entity, preload) do
    Enum.flat_map(preload, fn mod ->
      {:ok, components} = fetch_components(entity, mod)
      components
    end)
  end

  defp select_return_type(tuple, Entity), do: [tuple]

  defp select_return_type({_entity, components}, component_name) do
    Enum.filter(components, &(&1.__struct__ == component_name))
  end
end
