defmodule ElvenGard.ECS.MnesiaBackend do
  @moduledoc """
  Default Mnesia storage backend for ElvenGard.ECS.

  The backend stores entity relationships and partitions in one table and
  component ownership and values in another. Tables are initialized
  synchronously when the application starts; no resident backend process is
  kept after initialization.

  Applications normally access this module through `ElvenGard.ECS.Command` and
  `ElvenGard.ECS.Query`. The lower-level functions remain public for custom
  integrations and are transaction-aware: they use the current Mnesia
  transaction when one exists and otherwise select the appropriate dirty or
  transactional operation.

  ## Tables

  Entity records contain the entity ID, optional parent ID, and partition.
  Component records contain `{owner_id, component_module}`, the owner ID, the
  component module, and the component struct. The component table is a bag, so
  one entity may own multiple distinct values of the same component module.

  Partition-scoped queries start from the entity partition index and fetch
  components only for those owners. Their component lookup cost therefore
  scales with the selected partition instead of the global component table.

  Parent changes and component read-modify-write operations use write locks to
  protect against lost updates. Parent cycles are rejected.

  """

  import ElvenGard.ECS.MnesiaBackend.Records
  import Record

  alias ElvenGard.ECS.{Component, Entity, Query}

  @timeout 5000

  ## Public API

  @doc false
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc false
  @spec start_link(Keyword.t()) :: :ignore
  def start_link(_opts) do
    :ok = init_mnesia()
    :ignore
  end

  ## Transactions

  @doc "Executes a function in a Mnesia transaction."
  @spec transaction((-> result)) :: {:error, any()} | {:ok, result} when result: any()
  def transaction(query) do
    case :mnesia.transaction(query) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Aborts the current Mnesia transaction with `reason`."
  @spec abort(any()) :: no_return()
  def abort(reason) do
    :mnesia.abort(reason)
  end

  ## General Queries

  @doc "Executes a query description and returns its matching values."
  @spec all(Query.t()) :: [Query.result()]
  def all(%Query{partition: partition} = query) when partition != :any do
    %Query{
      return_type: return_type,
      components: components,
      mandatories: mandatories,
      preload_all: preload_all,
      return_entity: return_entity
    } = query

    component_selectors = Enum.map(components, &compile_component_selector/1)

    Entity
    |> index_read(partition, :partition)
    |> Enum.map(&build_entity_struct(&1))
    |> Enum.map(&fetch_partition_components(&1, component_selectors))
    |> Enum.filter(&matches_partition_query?(&1, mandatories, return_entity))
    |> maybe_preload_all(preload_all)
    |> apply_return_type(return_type)
  end

  def all(%Query{return_entity: true, mandatories: [], partition: :any} = query) do
    %Query{
      return_type: return_type,
      components: components,
      preload_all: preload_all
    } = query

    Entity
    |> all_keys()
    # Transform to Entity struct
    |> Enum.map(&build_entity_struct(&1))
    # Fetch needed components
    |> Enum.map(&fetch_needed_components(&1, components, preload_all))
    # Return the requested type
    |> apply_return_type(return_type)
  end

  # return_type can be `Entity`, a Component module or a tuple here
  def all(%Query{return_type: return_type, partition: :any} = query) do
    %Query{
      components: components,
      mandatories: mandatories,
      preload_all: preload_all
    } = query

    components
    # Select needed components
    |> select_components_by_type()
    # Group by owner
    |> Enum.group_by(&component(&1, :owner_id), &component(&1, :component))
    # Keep only all required component matching
    |> Enum.filter(&has_all_components(&1, mandatories))
    # Transform to Entity struct
    |> Enum.map(fn {id, compons} -> {build_entity_struct(id), compons} end)
    # Maybe preload all
    |> maybe_preload_all(preload_all)
    # Return the requested type
    |> apply_return_type(return_type)
  end

  ### Entities

  @doc """
  Selects entities by one indexed relationship or component criterion.

  Supported criteria are `with_parent: entity`, `without_parent: entity`, and
  `with_component: module`.
  """
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
    guards = [{:"=/=", :"$2", escape_match_spec_constant(parent_id(parent))}]
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

  @doc """
  Creates an entity when its ID is unused and its parent does not create a
  cycle.
  """
  @spec create_entity(Entity.id(), Entity.t() | nil, Entity.partition()) ::
          {:ok, Entity.t()} | {:error, :already_exists | :cyclic_relationship}
  def create_entity(id, parent, partition) do
    entity = entity(id: id, parent_id: parent_id(parent), partition: partition)

    case insert_new(entity) do
      :ok -> {:ok, build_entity_struct(id)}
      {:error, :already_exists} = error -> error
      {:error, :cyclic_relationship} = error -> error
    end
  end

  @doc "Fetches an entity by ID."
  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
    case read({Entity, id}) do
      [entity] -> {:ok, record_to_struct(entity)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Fetches the direct parent of an entity."
  @spec parent(Entity.t()) :: {:ok, nil | Entity.t()} | {:error, :not_found}
  def parent(%Entity{id: id}) do
    case read({Entity, id}) do
      [] -> {:error, :not_found}
      [{Entity, ^id, nil, _partition}] -> {:ok, nil}
      [{Entity, ^id, parent_id, _partition}] -> {:ok, build_entity_struct(parent_id)}
    end
  end

  @doc "Sets or clears an entity's direct parent while preventing cycles."
  @spec set_parent(Entity.t(), Entity.t() | nil) ::
          :ok | {:error, :cyclic_relationship | :not_found}
  def set_parent(%Entity{id: id}, parent) do
    update_entity(id, :parent_id, parent)
  end

  @doc "Fetches an entity's partition."
  @spec partition(Entity.t()) :: {:ok, Entity.partition()} | {:error, :not_found}
  def partition(%Entity{id: id}) do
    case read({Entity, id}) do
      [{Entity, ^id, _parent_id, partition}] -> {:ok, partition}
      [] -> {:error, :not_found}
    end
  end

  @doc "Sets an entity's partition."
  @spec set_partition(Entity.t(), Entity.partition()) :: :ok | {:error, :not_found}
  def set_partition(%Entity{id: id}, partition) do
    update_entity(id, :partition, partition)
  end

  @doc "Returns the direct children of an entity."
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

  @doc "Returns whether the first entity is the direct parent of the second."
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

  @doc "Deletes an entity record without deleting its components."
  @spec delete_entity(Entity.t()) :: :ok
  def delete_entity(%Entity{id: id}) do
    delete({Entity, id})
  end

  ### Components

  @doc "Adds a component value to an entity."
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

  @doc "Replaces every component of the same module with one component value."
  @spec replace_component(Entity.t(), Component.t()) :: :ok
  def replace_component(%Entity{id: owner_id}, %component_mod{} = component) do
    record =
      component(
        composite_key: {owner_id, component_mod},
        owner_id: owner_id,
        type: component_mod,
        component: component
      )

    case :mnesia.is_transaction() do
      true -> do_replace_component(record)
      false -> replace_component_in_transaction(record)
    end
  end

  @doc """
  Deletes components by module or by exact value.

  Passing a module deletes every value of that module. Passing a struct deletes
  values equal to that struct.
  """
  @spec delete_component(Entity.t(), module() | Component.t()) :: :ok
  def delete_component(%Entity{id: id}, component) when is_atom(component) do
    delete({Component, {id, component}})
  end

  def delete_component(%Entity{id: owner_id}, %component_mod{} = component) do
    case :mnesia.is_transaction() do
      true -> do_delete_component(owner_id, component_mod, component)
      false -> delete_component_in_transaction(owner_id, component_mod, component)
    end
  end

  @doc """
  Updates one component selected by module or exact value.

  A module selector returns `:multiple_values` when more than one value exists.
  """
  @spec update_component(Entity.t(), module() | Component.t(), Keyword.t()) ::
          {:ok, Component.t()} | {:error, :not_found | :multiple_values}
  def update_component(%Entity{id: owner_id}, %component_mod{} = component, attrs) do
    update_component(owner_id, component_mod, component, attrs)
  end

  def update_component(%Entity{id: owner_id}, component_mod, attrs)
      when is_atom(component_mod) do
    update_component(owner_id, component_mod, :all, attrs)
  end

  @doc "Lists every component owned by an entity."
  @spec list_components(Entity.t()) :: {:ok, [Component.t()]}
  def list_components(%Entity{id: id}) do
    Component
    |> index_read(id, :owner_id)
    # Keep only the component
    |> Enum.map(&component(&1, :component))
    # Wrap into :ok tuple
    |> then(&{:ok, &1})
  end

  @doc "Fetches every component of one module owned by an entity."
  @spec fetch_components(Entity.t(), module()) :: {:ok, [Component.t()]}
  def fetch_components(%Entity{id: owner_id}, component) do
    {Component, {owner_id, component}}
    |> read()
    |> Enum.map(&component(&1, :component))
    |> then(&{:ok, &1})
  end

  @doc "Deletes and returns every component owned by an entity."
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
    :ok =
      create_table(
        Entity,
        type: :set,
        attributes: [:id, :parent_id, :partition],
        index: [:parent_id, :partition]
      )

    :ok =
      create_table(
        Component,
        type: :bag,
        attributes: [:composite_key, :owner_id, :type, :component],
        index: [:owner_id, :type]
      )

    :ok = :mnesia.wait_for_tables([Entity, Component], @timeout)
  end

  ## Private Helpers

  defp create_table(table, options) do
    case :mnesia.create_table(table, options) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table}} -> :ok
    end
  end

  defp unwrap({:ok, value}), do: value

  defp parent_id(nil), do: nil
  defp parent_id(%Entity{id: id}), do: id

  defp build_entity_struct(record) when is_record(record, Entity),
    do: %Entity{id: entity(record, :id)}

  defp build_entity_struct(id), do: %Entity{id: id}

  # Mnesia match-specs require tuple constants to be wrapped in another tuple.
  defp escape_match_spec_constant(value) do
    case is_tuple(value) do
      true -> {value}
      false -> value
    end
  end

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

  defp delete_component_in_transaction(owner_id, component_mod, component) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        do_delete_component(owner_id, component_mod, component)
      end)

    :ok
  end

  defp do_delete_component(owner_id, component_mod, selected_component) do
    {Component, {owner_id, component_mod}}
    |> :mnesia.wread()
    |> Enum.filter(&(component(&1, :component) == selected_component))
    |> Enum.each(&:mnesia.delete_object/1)
  end

  defp replace_component_in_transaction(record) do
    {:atomic, :ok} = :mnesia.transaction(fn -> do_replace_component(record) end)
    :ok
  end

  defp do_replace_component(record) do
    composite_key = component(record, :composite_key)
    :ok = :mnesia.delete({Component, composite_key})
    :mnesia.write(record)
  end

  defp update_component(owner_id, component_mod, selector, attrs) do
    case :mnesia.is_transaction() do
      true -> do_update_component(owner_id, component_mod, selector, attrs)
      false -> update_component_in_transaction(owner_id, component_mod, selector, attrs)
    end
  end

  defp update_component_in_transaction(owner_id, component_mod, selector, attrs) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        do_update_component(owner_id, component_mod, selector, attrs)
      end)

    result
  end

  defp do_update_component(owner_id, component_mod, selector, attrs) do
    {Component, {owner_id, component_mod}}
    |> :mnesia.wread()
    |> select_component_records(selector)
    |> replace_component_record(attrs)
  end

  defp select_component_records(records, selector) do
    case selector do
      :all -> records
      selected -> Enum.filter(records, &(component(&1, :component) == selected))
    end
  end

  defp replace_component_record(records, attrs) do
    case records do
      [] ->
        {:error, :not_found}

      [record] ->
        :ok = :mnesia.delete_object(record)
        updated_component = record |> component(:component) |> struct!(attrs)
        :ok = record |> component(component: updated_component) |> :mnesia.write()
        {:ok, updated_component}

      _ ->
        {:error, :multiple_values}
    end
  end

  defp update_entity(id, field, value) do
    case :mnesia.is_transaction() do
      true -> do_update_entity(id, field, value)
      false -> update_entity_in_transaction(id, field, value)
    end
  end

  defp update_entity_in_transaction(id, field, value) do
    {:atomic, result} = :mnesia.transaction(fn -> do_update_entity(id, field, value) end)
    result
  end

  defp do_update_entity(id, field, value) do
    case :mnesia.wread({Entity, id}) do
      [record] -> update_entity_record(record, id, field, value)
      [] -> {:error, :not_found}
    end
  end

  defp update_entity_record(record, id, field, value) do
    case field do
      :parent_id -> update_entity_parent(record, id, value)
      :partition -> record |> entity(partition: value) |> :mnesia.write()
    end
  end

  defp update_entity_parent(record, id, parent) do
    parent_id = parent_id(parent)

    case ensure_acyclic_parent(id, parent_id) do
      :ok -> record |> entity(parent_id: parent_id) |> :mnesia.write()
      {:error, :cyclic_relationship} = error -> error
    end
  end

  defp ensure_acyclic_parent(entity_id, parent_id) do
    case parent_id do
      nil ->
        :ok

      ^entity_id ->
        {:error, :cyclic_relationship}

      _other ->
        case :mnesia.read({Entity, parent_id}) do
          [{Entity, ^parent_id, next_parent_id, _partition}] ->
            ensure_acyclic_parent(entity_id, next_parent_id)

          [] ->
            :ok
        end
    end
  end

  defp insert_new(record) do
    case :mnesia.is_transaction() do
      true ->
        do_insert_new(record)

      false ->
        insert_new_in_transaction(record)
    end
  end

  defp insert_new_in_transaction(record) do
    case :mnesia.transaction(fn -> do_insert_new(record) end) do
      {:atomic, :ok} -> :ok
      {:aborted, :already_exists} -> {:error, :already_exists}
      {:aborted, :cyclic_relationship} -> {:error, :cyclic_relationship}
    end
  end

  defp do_insert_new(record) do
    id = entity(record, :id)

    case :mnesia.wread({Entity, id}) do
      [] -> insert_new_entity(record, id)
      _ -> :mnesia.abort(:already_exists)
    end
  end

  defp insert_new_entity(record, id) do
    case ensure_acyclic_parent(id, entity(record, :parent_id)) do
      :ok -> :mnesia.write(record)
      {:error, :cyclic_relationship} -> :mnesia.abort(:cyclic_relationship)
    end
  end

  defp select_components_by_type(components) do
    match = {Component, :_, :_, :"$3", :"$4"}

    guards =
      components
      |> Enum.reverse()
      |> Enum.map(&component_guard/1)
      |> Enum.reduce(&{:orelse, &1, &2})
      |> List.wrap()

    result = [:"$_"]
    query = [{match, guards, result}]

    select(Component, query)
  end

  defp component_guard(component_spec) do
    case component_spec do
      {component_mod, []} ->
        {:==, :"$3", component_mod}

      {component_mod, specs} ->
        specs
        |> Enum.map(&component_filter_guard(&1, :"$4"))
        |> Enum.reduce(&{:andalso, &1, &2})
        |> then(&{:andalso, {:==, :"$3", component_mod}, &1})

      component_mod ->
        {:==, :"$3", component_mod}
    end
  end

  defp has_all_components({_entity_id, components}, mandatories) do
    component_modules = Enum.map(components, & &1.__struct__)
    mandatories -- component_modules == []
  end

  defp matches_partition_query?({_entity, []}, [], false), do: false

  defp matches_partition_query?(entity_components, mandatories, _return_entity) do
    has_all_components(entity_components, mandatories)
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

  defp compile_component_selector(component_mod) when is_atom(component_mod),
    do: {component_mod, nil}

  defp compile_component_selector({component_mod, []}), do: {component_mod, nil}

  defp compile_component_selector({component_mod, filters}) do
    guards = Enum.map(filters, &component_value_guard/1)
    match_spec = :ets.match_spec_compile([{:"$1", guards, [:"$_"]}])
    {component_mod, match_spec}
  end

  defp fetch_partition_components(entity, component_selectors)
       when is_list(component_selectors) do
    components = Enum.flat_map(component_selectors, &fetch_partition_components(entity, &1))
    {entity, components}
  end

  defp fetch_partition_components(entity, {component_mod, match_spec}) do
    {:ok, components} = fetch_components(entity, component_mod)
    filter_component_values(components, match_spec)
  end

  defp filter_component_values(components, nil), do: components

  defp filter_component_values(components, match_spec) do
    :ets.match_spec_run(components, match_spec)
  end

  defp component_value_guard(filter) do
    component_filter_guard(filter, :"$1")
  end

  defp component_filter_guard({:in, field, values}, source) when is_list(values) do
    values
    |> Enum.map(fn value ->
      {:==, {:map_get, field, source}, escape_match_spec_constant(value)}
    end)
    |> Enum.reduce({:==, true, false}, &{:orelse, &1, &2})
  end

  defp component_filter_guard({op, field, value}, source) do
    {op, {:map_get, field, source}, escape_match_spec_constant(value)}
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
