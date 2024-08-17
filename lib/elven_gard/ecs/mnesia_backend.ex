defmodule ElvenGard.ECS.MnesiaBackend do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.MnesiaBackend

  TODO: Write a module for Entities and Components serialization instead of having raw tuples

  Entity Table:

    | entity_id | parent_id or nil | partition or default |

  Component Table

    | {owner_id, component_type} | owner_id | component_type | component |

  """

  use Task

  import ElvenGard.ECS.MnesiaBackend.Records
  import Record

  alias ElvenGard.ECS.Entity
  alias ElvenGard.ECS.Query
  alias ElvenGard.ECS.{Component, Entity}

  @timeout 5000

  ## Public API

  @spec start_link(Keyword.t()) :: {:ok, pid()}
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

  @spec all(Query.t()) :: list()
  def all(%Query{return_entity: true, mandatories: []} = query) do
    %Query{
      return_type: return_type,
      components: components,
      preload_all: preload_all,
      partition: partition
    } = query

    entities =
      case partition do
        # If no required component, we must get all Entities
        :any -> all_keys(Entity)
        # If a partition is specified, get by partition
        _ -> index_read(Entity, partition, :partition)
      end

    entities
    # Transform to Entity struct
    |> Enum.map(&build_entity_struct(&1))
    # Fetch needed components
    |> Enum.map(&fetch_needed_components(&1, components, preload_all))
    # Return the requested type
    |> apply_return_type(return_type)
  end

  # return_type can be `Entity`, a Component module or a tuple here
  def all(%Query{return_type: return_type} = query) do
    %Query{
      components: components,
      mandatories: mandatories,
      preload_all: preload_all,
      partition: partition
    } = query

    components
    # Select needed components
    |> select_components_by_type()
    # Group by owner
    |> Enum.group_by(&component(&1, :owner_id), &component(&1, :component))
    # Keep only all required component matching
    |> Enum.filter(&has_all_components(&1, mandatories))
    # Filter by partition
    |> maybe_filter_by_partition(partition)
    # Transform to Entity struct
    |> Enum.map(fn {id, compons} -> {build_entity_struct(id), compons} end)
    # Maybe preload all
    |> maybe_preload_all(preload_all)
    # Return the requested type
    |> apply_return_type(return_type)
  end

  ### Entities

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
    # entity_id, parent_id, partition
    match = {Entity, :"$1", :"$2", :"$3"}
    guards = [{:"=/=", :"$2", escape_id(parent_id(parent))}]
    return = [:"$1"]
    query = [{match, guards, return}]

    Entity
    |> select(query)
    |> Enum.map(&build_entity_struct/1)
    |> then(&{:ok, &1})
  end

  def select_entities(with_component: component) when is_atom(component) do
    Component
    |> index_read(component, :type)
    |> Enum.map(&component(&1, :owner_id))
    |> Enum.uniq()
    |> Enum.map(&build_entity_struct/1)
    |> then(&{:ok, &1})
  end

  @spec create_entity(Entity.id(), Entity.t(), Entity.partition()) ::
          {:ok, Entity.t()} | {:error, :already_exists}
  def create_entity(id, parent, partition) do
    entity = entity(id: id, parent_id: parent_id(parent), partition: partition)

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
      [{Entity, ^id, nil, _partition}] -> {:ok, nil}
      [{Entity, ^id, parent_id, _partition}] -> {:ok, build_entity_struct(parent_id)}
    end
  end

  @spec set_parent(Entity.t(), Entity.t()) :: :ok | {:error, :not_found}
  def set_parent(%Entity{id: id}, parent) do
    case read({Entity, id}) do
      [record] ->
        record
        |> entity(parent_id: parent_id(parent))
        |> insert()

      [] ->
        {:error, :not_found}
    end
  end

  @spec partition(Entity.t()) :: {:ok, Entity.partition()} | {:error, :not_found}
  def partition(%Entity{id: id}) do
    case read({Entity, id}) do
      [{Entity, ^id, _parent_id, partition}] -> {:ok, partition}
      [] -> {:error, :not_found}
    end
  end

  @spec set_partition(Entity.t(), Entity.partition()) :: :ok | {:error, :not_found}
  def set_partition(%Entity{id: id}, partition) do
    case read({Entity, id}) do
      [record] ->
        record
        |> entity(partition: partition)
        |> insert()

      [] ->
        {:error, :not_found}
    end
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

  @spec add_component(Entity.t(), Component.spec() | Component.t()) :: {:ok, Component.t()}
  def add_component(%Entity{id: id}, %component_mod{} = component) do
    component(
      composite_key: {id, component_mod},
      owner_id: id,
      type: component_mod,
      component: component
    )
    |> insert()

    {:ok, component}
  end

  def add_component(entity, component_spec) do
    add_component(entity, Component.spec_to_struct(component_spec))
  end

  @spec delete_component(Entity.t(), module() | Component.t()) :: :ok
  def delete_component(%Entity{id: id}, component) when is_atom(component) do
    delete({Component, {id, component}})
  end

  def delete_component(%Entity{id: id}, %component_mod{} = component) do
    read({Component, {id, component_mod}})
    |> Enum.filter(&(component(&1, :component) == component))
    |> Enum.each(&delete_object/1)
  end

  @spec update_component(Entity.t(), module() | Component.t(), Keyword.t()) ::
          {:ok, Component.t()} | {:error, :not_found | :multiple_values}
  def update_component(%Entity{id: owner_id} = entity, %component_mod{} = component, attrs) do
    components =
      {Component, {owner_id, component_mod}}
      |> read()
      |> Enum.filter(&(component(&1, :component) == component))

    case components do
      [] ->
        {:error, :not_found}

      [record] ->
        :ok = delete_object(record)
        component = record |> component(:component) |> struct!(attrs)
        add_component(entity, component)

      _ ->
        # Normally this case shouldn't be possible because Mnesia doesn't support duplicate bag
        {:error, :multiple_values}
    end
  end

  def update_component(%Entity{id: owner_id} = entity, component_mod, attrs)
      when is_atom(component_mod) do
    components = read({Component, {owner_id, component_mod}})

    case components do
      [] ->
        {:error, :not_found}

      [record] ->
        :ok = delete_object(record)
        component = record |> component(:component) |> struct!(attrs)
        add_component(entity, component)

      _ ->
        {:error, :multiple_values}
    end
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
    {Component, {owner_id, component}}
    |> read()
    |> Enum.map(&component(&1, :component))
    |> then(&{:ok, &1})
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
        attributes: [:id, :parent_id, :partition],
        index: [:parent_id, :partition]
      )

    {:atomic, :ok} =
      :mnesia.create_table(
        Component,
        type: :bag,
        attributes: [:composite_key, :owner_id, :type, :component],
        index: [:owner_id, :type]
      )

    :ok = :mnesia.wait_for_tables([Entity, Component], @timeout)
  end

  ## Private Helpers

  defp unwrap({:ok, value}), do: value

  defp parent_id(nil), do: nil
  defp parent_id(%Entity{id: id}), do: id

  defp build_entity_struct(record) when is_record(record, Entity),
    do: %Entity{id: entity(record, :id)}

  defp build_entity_struct(id), do: %Entity{id: id}

  # I don't know why but you need to wrap tuples inside another tuple in select/dirty_select
  defp escape_id(id) when is_tuple(id), do: {id}
  defp escape_id(id), do: id

  defp record_to_struct(entity_record) do
    entity_record
    |> entity(:id)
    |> build_entity_struct()
  end

  defp all_keys(tab) do
    case :mnesia.is_transaction() do
      true -> :mnesia.all_keys(tab)
      false -> :mnesia.dirty_all_keys(tab)
    end
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

  defp select_components_by_type(components) do
    # TODO: Generate the select query
    match = {Component, :_, :_, :"$3", :"$4"}

    guards =
      components
      |> Enum.reverse()
      |> Enum.map(fn
        {component_mod, specs} ->
          specs
          |> Enum.map(fn {op, field, value} -> {op, {:map_get, field, :"$4"}, value} end)
          |> Enum.reduce(&{:andalso, &1, &2})
          |> then(&{:andalso, {:==, :"$3", component_mod}, &1})

        component_mod ->
          {:==, :"$3", component_mod}
      end)
      |> Enum.reduce(&{:orelse, &1, &2})
      |> List.wrap()

    result = [:"$_"]
    query = [{match, guards, result}]

    select(Component, query)
  end

  defp has_all_components({_entity_id, components}, mandatories) do
    component_modules = Enum.map(components, & &1.__struct__)
    mandatories -- component_modules == []
  end

  defp maybe_filter_by_partition(entities, :any), do: entities

  defp maybe_filter_by_partition(entities, partition) do
    Enum.filter(entities, fn {entity_id, _components} ->
      case read({Entity, entity_id}) do
        [record] ->
          record
          # Get the partition
          |> entity(:partition)
          # Check if child.partition == partition
          |> Kernel.==(partition)

        [] ->
          false
      end
    end)
  end

  defp maybe_preload_all(entities, true) do
    Enum.map(entities, &{elem(&1, 0), &1 |> elem(0) |> list_components() |> unwrap()})
  end

  defp maybe_preload_all(entities, _preload_all), do: entities

  defp fetch_needed_components(entity, _components, true) do
    {entity, entity |> list_components() |> unwrap()}
  end

  defp fetch_needed_components(entity, components, _preload_all) do
    entity_components = Enum.flat_map(components, &(entity |> fetch_components(&1) |> unwrap()))
    {entity, entity_components}
  end

  defp apply_return_type(tuples, Entity) do
    tuples
  end

  defp apply_return_type(tuples, return) when is_tuple(return) do
    return_list = Tuple.to_list(return)

    Enum.map(tuples, fn {entity, components} ->
      return_list
      |> Enum.map(fn
        Entity -> entity
        component_mod -> Enum.find(components, &(&1.__struct__ == component_mod))
      end)
      |> List.to_tuple()
    end)
  end

  defp apply_return_type(tuples, component_mod) do
    Enum.flat_map(tuples, fn {_entity, components} ->
      Enum.filter(components, &(&1.__struct__ == component_mod))
    end)
  end
end
