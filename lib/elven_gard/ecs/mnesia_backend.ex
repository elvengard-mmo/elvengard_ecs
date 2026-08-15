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

  Changed-component queries use separate, opt-in revision tables. They retain
  one current revision per partition and one current membership/revision row
  per entity and component module, never component history. Membership-only
  caches track just their selected component modules without incrementing a
  partition revision for unrelated writes. Partitions that use neither feature
  keep the original component write path.

  Partition-scoped queries start from the entity partition index and fetch
  components only for those owners. Their component lookup cost therefore
  scales with the selected partition instead of the global component table.

  Parent changes and component read-modify-write operations use write locks to
  protect against lost updates. Parent cycles are rejected.

  """

  import ElvenGard.ECS.MnesiaBackend.Records
  import Record

  alias ElvenGard.ECS.{Component, Entity, Query}
  alias ElvenGard.ECS.MnesiaBackend.{ComponentRevision, Revision}

  @timeout 5000
  @entity_tracking_context {__MODULE__, :entity_tracking_context}
  @tracking_table ElvenGard.ECS.MnesiaBackend.RevisionTracking
  @component_attributes [:composite_key, :owner_id, :type, :component]

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
    case :mnesia.is_transaction() do
      true ->
        {:ok, query.()}

      false ->
        execute_transaction(query)
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
  def all(%Query{candidate_ids: candidate_ids} = query) when is_list(candidate_ids) do
    %Query{
      return_type: return_type,
      components: components,
      mandatories: mandatories,
      preload_all: preload_all,
      return_entity: return_entity
    } = query

    component_selectors = Enum.map(components, &compile_component_selector/1)

    candidate_ids
    |> Enum.map(&build_entity_struct(&1))
    |> Enum.map(&fetch_partition_components(&1, component_selectors))
    |> Enum.filter(&matches_partition_query?(&1, mandatories, return_entity))
    |> maybe_preload_all(preload_all)
    |> apply_return_type(return_type)
  end

  def all(
        %Query{
          partition: partition,
          mandatories: [first_mandatory | _rest],
          cache_membership: true
        } = query
      )
      when partition != :any do
    candidate_ids =
      ComponentRevision
      |> index_read({partition, first_mandatory}, :scope)
      |> Enum.map(&component_revision(&1, :owner_id))
      |> Enum.uniq()

    all(%{query | candidate_ids: candidate_ids})
  end

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

  @doc "Returns the current bounded component revision for one partition."
  @spec current_revision(Entity.partition()) :: non_neg_integer()
  def current_revision(partition) do
    key = {:revision, partition}

    case :ets.lookup(@tracking_table, key) do
      [{^key, :ready}] -> read_current_revision(partition)
      [{^key, {:activating, _owner}}] -> await_revision_tracking(key, partition)
      [] -> start_revision_tracking(key, partition)
    end
  end

  @doc "Seeds and maintains one bounded component membership for a partition."
  @spec cache_component_membership(Entity.partition(), module()) :: :ok
  def cache_component_membership(partition, component_module) when is_atom(component_module) do
    key = {:membership, partition, component_module}
    revision_key = {:revision, partition}

    case {:ets.lookup(@tracking_table, revision_key), :ets.lookup(@tracking_table, key)} do
      {[{^revision_key, :ready}], _membership_state} ->
        :ok

      {[{^revision_key, {:activating, _owner}}], _membership_state} ->
        _revision = await_revision_tracking(revision_key, partition)
        :ok

      {[], [{^key, :ready}]} ->
        :ok

      {[], [{^key, {:activating, _owner}}]} ->
        await_membership_tracking(key, partition, component_module)

      {[], []} ->
        start_membership_tracking(partition, component_module)
    end
  end

  @doc "Returns entity IDs whose selected components changed after `since_revision`."
  @spec changed_entity_ids(Entity.partition(), [module()], non_neg_integer()) :: [Entity.id()]
  def changed_entity_ids(partition, component_modules, since_revision) do
    component_modules
    |> Enum.flat_map(fn component_module ->
      ComponentRevision
      |> index_read({partition, component_module}, :scope)
      |> Enum.filter(&(component_revision(&1, :revision) > since_revision))
      |> Enum.map(&component_revision(&1, :owner_id))
    end)
    |> Enum.uniq()
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
      :ok ->
        track_entity_partition(id, partition)
        {:ok, build_entity_struct(id)}

      {:error, :already_exists} = error ->
        error

      {:error, :cyclic_relationship} = error ->
        error
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
    :ok = delete({Entity, id})
    delete_entity_tracking(id)
    :ok
  end

  ### Components

  @doc "Adds a component value to an entity."
  @spec add_component(Entity.t(), Component.spec() | Component.t()) :: {:ok, Component.t()}
  def add_component(%Entity{id: id}, %component_mod{} = component) do
    case {tracked_entity_partition(id), :mnesia.is_transaction()} do
      {partition, false} when not is_nil(partition) ->
        transaction(fn -> do_add_component(id, partition, component_mod, component) end)
        |> unwrap()

      {partition, true} when not is_nil(partition) ->
        do_add_component(id, partition, component_mod, component)

      {nil, _transaction?} ->
        insert_component(id, component_mod, component)
    end
  end

  def add_component(entity, component_spec) do
    add_component(entity, Component.spec_to_struct(component_spec))
  end

  defp do_add_component(id, partition, component_mod, component_value) do
    composite_key = {id, component_mod}

    duplicate? =
      {Component, composite_key}
      |> read()
      |> Enum.any?(&(component(&1, :component) == component_value))

    unless duplicate? do
      insert_component(id, component_mod, component_value)
      track_component_change(partition, id, component_mod)
    end

    {:ok, component_value}
  end

  @doc "Replaces every component of the same module with one component value."
  @spec replace_component(Entity.t(), Component.t()) :: :ok
  def replace_component(%Entity{id: owner_id}, %component_mod{} = component) do
    partition = tracked_entity_partition(owner_id)

    case :mnesia.is_transaction() do
      true -> do_replace_component(owner_id, partition, component_mod, component)
      false -> replace_component_in_transaction(owner_id, partition, component_mod, component)
    end
  end

  @doc """
  Deletes components by module or by exact value.

  Passing a module deletes every value of that module. Passing a struct deletes
  values equal to that struct.
  """
  @spec delete_component(Entity.t(), module() | Component.t()) :: :ok
  def delete_component(%Entity{id: owner_id}, component_mod) when is_atom(component_mod) do
    partition = tracked_entity_partition(owner_id)

    case {partition, :mnesia.is_transaction()} do
      {partition, false} when not is_nil(partition) ->
        {:ok, :ok} =
          transaction(fn -> do_delete_component_type(partition, owner_id, component_mod) end)

        :ok

      {partition, true} when not is_nil(partition) ->
        do_delete_component_type(partition, owner_id, component_mod)

      {nil, _transaction?} ->
        delete({Component, {owner_id, component_mod}})
    end
  end

  def delete_component(%Entity{id: owner_id}, %component_mod{} = component) do
    partition = tracked_entity_partition(owner_id)

    case :mnesia.is_transaction() do
      true -> do_delete_component(owner_id, partition, component_mod, component)
      false -> delete_component_in_transaction(owner_id, partition, component_mod, component)
    end
  end

  @doc """
  Updates one component selected by module or exact value.

  A module selector returns `:multiple_values` when more than one value exists.
  """
  @spec update_component(Entity.t(), module() | Component.t(), Keyword.t()) ::
          {:ok, Component.t()} | {:error, :not_found | :multiple_values}
  def update_component(%Entity{id: owner_id}, %component_mod{} = component, attrs) do
    update_component(
      owner_id,
      tracked_entity_partition(owner_id),
      component_mod,
      component,
      attrs
    )
  end

  def update_component(%Entity{id: owner_id}, component_mod, attrs)
      when is_atom(component_mod) do
    update_component(owner_id, tracked_entity_partition(owner_id), component_mod, :all, attrs)
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
    partition = tracked_entity_partition(owner_id)

    unless is_nil(partition) do
      components
      |> Enum.map(&component(&1, :type))
      |> Enum.uniq()
      |> Enum.each(&delete_component_revision(partition, owner_id, &1))
    end

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
        attributes: @component_attributes,
        index: [:owner_id, :type]
      )

    :ok =
      create_table(
        Revision,
        type: :set,
        attributes: [:partition, :revision]
      )

    :ok =
      create_table(
        ComponentRevision,
        type: :set,
        attributes: [:composite_key, :scope, :owner_id, :revision],
        index: [:scope, :owner_id]
      )

    :ok = :mnesia.wait_for_tables([Entity, Component, Revision, ComponentRevision], @timeout)
    :ok = migrate_component_table()
    :ok = initialize_tracking_table()
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

  defp insert_component(owner_id, component_mod, component_value) do
    component(
      composite_key: {owner_id, component_mod},
      owner_id: owner_id,
      type: component_mod,
      component: component_value
    )
    |> insert()

    {:ok, component_value}
  end

  defp delete_component_in_transaction(owner_id, partition, component_mod, component) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        do_delete_component(owner_id, partition, component_mod, component)
      end)

    :ok
  end

  defp do_delete_component(owner_id, partition, component_mod, selected_component) do
    records = :mnesia.wread({Component, {owner_id, component_mod}})

    records
    |> Enum.filter(&(component(&1, :component) == selected_component))
    |> Enum.each(&:mnesia.delete_object/1)

    unless is_nil(partition) do
      case Enum.reject(records, &(component(&1, :component) == selected_component)) do
        [] -> delete_component_revision(partition, owner_id, component_mod)
        _remaining -> track_component_change(partition, owner_id, component_mod)
      end
    end

    :ok
  end

  defp do_delete_component_type(partition, owner_id, component_mod) do
    :ok = delete({Component, {owner_id, component_mod}})
    delete_component_revision(partition, owner_id, component_mod)
  end

  defp replace_component_in_transaction(owner_id, partition, component_mod, component_value) do
    {:ok, :ok} =
      transaction(fn ->
        do_replace_component(owner_id, partition, component_mod, component_value)
      end)

    :ok
  end

  defp do_replace_component(owner_id, partition, component_mod, component_value) do
    composite_key = {owner_id, component_mod}

    record =
      component(
        composite_key: composite_key,
        owner_id: owner_id,
        type: component_mod,
        component: component_value
      )

    :ok = :mnesia.delete({Component, composite_key})
    :ok = :mnesia.write(record)

    unless is_nil(partition) do
      track_component_change(partition, owner_id, component_mod)
    end

    :ok
  end

  defp update_component(owner_id, partition, component_mod, selector, attrs) do
    case :mnesia.is_transaction() do
      true ->
        do_update_component(owner_id, partition, component_mod, selector, attrs)

      false ->
        update_component_in_transaction(owner_id, partition, component_mod, selector, attrs)
    end
  end

  defp update_component_in_transaction(owner_id, partition, component_mod, selector, attrs) do
    {:ok, result} =
      transaction(fn ->
        do_update_component(owner_id, partition, component_mod, selector, attrs)
      end)

    result
  end

  defp do_update_component(owner_id, partition, component_mod, selector, attrs) do
    {Component, {owner_id, component_mod}}
    |> :mnesia.wread()
    |> select_component_records(selector)
    |> replace_component_record(partition, attrs)
  end

  defp select_component_records(records, selector) do
    case selector do
      :all -> records
      selected -> Enum.filter(records, &(component(&1, :component) == selected))
    end
  end

  defp replace_component_record(records, partition, attrs) do
    case records do
      [] ->
        {:error, :not_found}

      [record] ->
        :ok = :mnesia.delete_object(record)
        updated_component = record |> component(:component) |> struct!(attrs)
        :ok = record |> component(component: updated_component) |> :mnesia.write()

        unless is_nil(partition) do
          owner_id = component(record, :owner_id)
          component_mod = component(record, :type)
          track_component_change(partition, owner_id, component_mod)
        end

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
    {:ok, result} = transaction(fn -> do_update_entity(id, field, value) end)
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
      :partition -> update_entity_partition(record, id, value)
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

  defp update_entity_partition(record, entity_id, partition) do
    previous_partition = entity(record, :partition)

    if previous_partition == partition do
      :mnesia.write(record)
    else
      component_modules =
        Component
        |> :mnesia.index_read(entity_id, :owner_id)
        |> Enum.map(&component(&1, :type))
        |> Enum.uniq()

      if partition_tracking?(previous_partition) do
        Enum.each(
          component_modules,
          &delete_component_revision(previous_partition, entity_id, &1)
        )
      end

      :ok = record |> entity(partition: partition) |> :mnesia.write()
      move_entity_tracking(entity_id, partition)

      Enum.each(component_modules, &track_component_change(partition, entity_id, &1))

      :ok
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

  defp tracked_entity_partition(owner_id) do
    if tracking_enabled?() do
      case pending_entity_partition(owner_id) do
        {:ok, partition} -> partition
        :error -> persisted_tracked_entity_partition(owner_id)
      end
    end
  end

  defp persisted_tracked_entity_partition(owner_id) do
    case :ets.lookup(@tracking_table, {:entity, owner_id}) do
      [{{:entity, ^owner_id}, partition}] ->
        partition

      [] ->
        case :ets.member(@tracking_table, {:untracked_entity, owner_id}) do
          true -> nil
          false -> maybe_load_tracked_entity_partition(owner_id)
        end
    end
  end

  defp pending_entity_partition(owner_id) do
    case Process.get(@entity_tracking_context) do
      partitions when is_map(partitions) ->
        case Map.fetch(partitions, owner_id) do
          {:ok, {:partition, partition}} -> {:ok, partition}
          {:ok, :deleted} -> {:ok, nil}
          :error -> :error
        end

      nil ->
        :error
    end
  end

  defp maybe_load_tracked_entity_partition(owner_id) do
    case read({Entity, owner_id}) do
      [{Entity, ^owner_id, _parent_id, partition}] ->
        track_entity_partition(owner_id, partition)

      [] ->
        nil
    end
  end

  defp track_entity_partition(owner_id, partition) do
    if tracking_enabled?() do
      tracked_partition = if partition_tracking?(partition), do: partition
      put_entity_tracking(owner_id, tracked_partition)
      tracked_partition
    end
  end

  defp move_entity_tracking(owner_id, partition) do
    if tracking_enabled?() do
      tracked_partition = if partition_tracking?(partition), do: partition
      put_entity_tracking(owner_id, tracked_partition)
    end
  end

  defp delete_entity_tracking(owner_id) do
    if tracking_enabled?() do
      put_entity_tracking_status(owner_id, :deleted)
    end
  end

  defp put_entity_tracking(owner_id, partition) do
    put_entity_tracking_status(owner_id, {:partition, partition})
  end

  defp put_entity_tracking_status(owner_id, status) do
    case :mnesia.is_transaction() do
      true ->
        partitions = Process.get(@entity_tracking_context, %{})
        Process.put(@entity_tracking_context, Map.put(partitions, owner_id, status))

      false ->
        persist_entity_tracking_status(owner_id, status)
    end
  end

  defp persist_entity_tracking_status(owner_id, {:partition, nil}) do
    :ets.delete(@tracking_table, {:entity, owner_id})
    true = :ets.insert(@tracking_table, {{:untracked_entity, owner_id}})
    :ok
  end

  defp persist_entity_tracking_status(owner_id, {:partition, partition}) do
    :ets.delete(@tracking_table, {:untracked_entity, owner_id})
    true = :ets.insert(@tracking_table, {{:entity, owner_id}, partition})
    :ok
  end

  defp persist_entity_tracking_status(owner_id, :deleted) do
    :ets.delete(@tracking_table, {:entity, owner_id})
    :ets.delete(@tracking_table, {:untracked_entity, owner_id})
    :ok
  end

  defp next_revision(partition) do
    case :mnesia.is_transaction() do
      true -> locked_next_revision(partition)
      false -> next_revision_in_transaction(partition)
    end
  end

  defp locked_next_revision(partition) do
    case :mnesia.wread({Revision, partition}) do
      [record] ->
        value = revision(record, :revision) + 1
        :ok = record |> revision(revision: value) |> :mnesia.write()
        value

      [] ->
        raise "revision tracking is enabled without a partition revision"
    end
  end

  defp next_revision_in_transaction(partition) do
    {:atomic, value} = :mnesia.transaction(fn -> locked_next_revision(partition) end)
    value
  end

  defp enable_revision_tracking(partition) do
    case :mnesia.wread({Revision, partition}) do
      [] ->
        :ok = :mnesia.write(revision(partition: partition, revision: 0))
        0

      [record] ->
        revision(record, :revision)
    end
  end

  defp revision_tracking?(partition) do
    :ets.member(@tracking_table, {:partition, partition})
  end

  defp membership_tracking?(partition, component_module) do
    :ets.member(@tracking_table, {:membership, partition, component_module})
  end

  defp partition_tracking?(partition) do
    revision_tracking?(partition) or
      :ets.member(@tracking_table, {:membership_partition, partition})
  end

  defp tracking_enabled?() do
    :ets.member(@tracking_table, :tracking_enabled)
  end

  defp read_current_revision(partition) do
    [record] = read({Revision, partition})
    revision(record, :revision)
  end

  defp start_revision_tracking(key, partition) do
    if :mnesia.is_transaction() do
      raise ArgumentError,
            "revision tracking must be enabled before entering a backend transaction"
    end

    case :ets.insert_new(@tracking_table, {key, {:activating, self()}}) do
      true -> activate_revision_tracking(key, partition)
      false -> await_revision_tracking(key, partition)
    end
  end

  defp activate_revision_tracking(key, partition) do
    {:ok, _initial_revision} = transaction(fn -> enable_revision_tracking(partition) end)

    true =
      :ets.insert(@tracking_table, [
        {:tracking_enabled},
        {{:partition, partition}}
      ])

    {:ok, value} =
      transaction(fn ->
        value = next_revision(partition)
        seed_component_revisions(partition, value)
        value
      end)

    track_partition_entities(partition)
    true = :ets.insert(@tracking_table, {key, :ready})
    value
  catch
    kind, payload ->
      :ets.delete(@tracking_table, key)
      :ets.delete(@tracking_table, {:partition, partition})
      :erlang.raise(kind, payload, __STACKTRACE__)
  end

  defp await_revision_tracking(key, partition) do
    case :ets.lookup(@tracking_table, key) do
      [{^key, :ready}] ->
        read_current_revision(partition)

      [{^key, {:activating, owner}}] ->
        monitor = Process.monitor(owner)

        receive do
          {:DOWN, ^monitor, :process, ^owner, _reason} ->
            :ets.delete_object(@tracking_table, {key, {:activating, owner}})
            start_revision_tracking(key, partition)
        after
          1 ->
            Process.demonitor(monitor, [:flush])
            await_revision_tracking(key, partition)
        end

      [] ->
        start_revision_tracking(key, partition)
    end
  end

  defp start_membership_tracking(partition, component_module) do
    if :mnesia.is_transaction() do
      raise ArgumentError,
            "membership caching must be enabled before entering a backend transaction"
    end

    key = {:membership, partition, component_module}
    true = :ets.insert(@tracking_table, {:tracking_enabled})

    case :ets.insert_new(@tracking_table, {key, {:activating, self()}}) do
      true -> activate_membership_tracking(key, partition, component_module)
      false -> await_membership_tracking(key, partition, component_module)
    end
  end

  defp activate_membership_tracking(key, partition, component_module) do
    true = :ets.insert(@tracking_table, {{:membership_partition, partition}})

    {:ok, :ok} = transaction(fn -> seed_component_membership(partition, component_module) end)
    track_partition_entities(partition)
    true = :ets.insert(@tracking_table, {key, :ready})
    :ok
  catch
    kind, payload ->
      :ets.delete(@tracking_table, key)
      cleanup_membership_partition(partition)
      :erlang.raise(kind, payload, __STACKTRACE__)
  end

  defp await_membership_tracking(key, partition, component_module) do
    case :ets.lookup(@tracking_table, key) do
      [{^key, :ready}] ->
        :ok

      [{^key, {:activating, owner}}] ->
        monitor = Process.monitor(owner)

        receive do
          {:DOWN, ^monitor, :process, ^owner, _reason} ->
            :ets.delete_object(@tracking_table, {key, {:activating, owner}})
            start_membership_tracking(partition, component_module)
        after
          1 ->
            Process.demonitor(monitor, [:flush])
            await_membership_tracking(key, partition, component_module)
        end

      [] ->
        start_membership_tracking(partition, component_module)
    end
  end

  defp cleanup_membership_partition(partition) do
    watchers = :ets.match_object(@tracking_table, {{:membership, partition, :_}, :_})

    if watchers == [] and not revision_tracking?(partition) do
      :ets.delete(@tracking_table, {:membership_partition, partition})
    end

    :ok
  end

  defp with_transaction_context(function) do
    previous_entities = Process.get(@entity_tracking_context)

    try do
      function.()
    after
      restore_context(@entity_tracking_context, previous_entities)
    end
  end

  defp restore_context(key, nil), do: Process.delete(key)
  defp restore_context(key, previous), do: Process.put(key, previous)

  defp execute_transaction(query) do
    case tracking_enabled?() do
      true -> with_transaction_context(fn -> query |> transact() |> commit_entity_tracking() end)
      false -> transact(query)
    end
  end

  defp commit_entity_tracking({:ok, _result} = transaction_result) do
    @entity_tracking_context
    |> Process.get(%{})
    |> Enum.each(fn {owner_id, status} -> persist_entity_tracking_status(owner_id, status) end)

    transaction_result
  end

  defp commit_entity_tracking({:error, _reason} = transaction_result), do: transaction_result

  defp transact(query) do
    case :mnesia.transaction(query) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp migrate_component_table() do
    case :mnesia.table_info(Component, :attributes) do
      @component_attributes ->
        :ok

      [:composite_key, :owner_id, :type, :component, :scope, :revision] ->
        _result = :mnesia.del_table_index(Component, :scope)

        transform = fn {Component, composite_key, owner_id, type, component_value, _scope,
                        _revision} ->
          {Component, composite_key, owner_id, type, component_value}
        end

        case :mnesia.transform_table(Component, transform, @component_attributes) do
          {:atomic, :ok} -> :ok
          {:aborted, reason} -> raise "component table migration failed: #{inspect(reason)}"
        end

      attributes ->
        raise "unsupported component table attributes: #{inspect(attributes)}"
    end
  end

  defp initialize_tracking_table() do
    case :ets.whereis(@tracking_table) do
      :undefined ->
        _table = :ets.new(@tracking_table, [:named_table, :public, read_concurrency: true])

      _reference ->
        :ets.delete_all_objects(@tracking_table)
    end

    Revision
    |> :mnesia.dirty_all_keys()
    |> Enum.each(fn partition ->
      true =
        :ets.insert(@tracking_table, [
          {:tracking_enabled},
          {{:partition, partition}},
          {{:revision, partition}, :ready}
        ])

      track_partition_entities(partition)
    end)

    :ok
  end

  defp seed_component_revisions(partition, revision_value) do
    Entity
    |> :mnesia.index_read(partition, :partition)
    |> Enum.each(fn entity_record ->
      owner_id = entity(entity_record, :id)

      Component
      |> :mnesia.index_read(owner_id, :owner_id)
      |> Enum.map(&component(&1, :type))
      |> Enum.uniq()
      |> Enum.each(&write_component_revision(partition, owner_id, &1, revision_value))
    end)

    :ok
  end

  defp seed_component_membership(partition, component_module) do
    ComponentRevision
    |> :mnesia.index_read({partition, component_module}, :scope)
    |> Enum.each(&:mnesia.delete_object/1)

    Entity
    |> :mnesia.index_read(partition, :partition)
    |> Enum.each(fn entity_record ->
      owner_id = entity(entity_record, :id)

      case :mnesia.read({Component, {owner_id, component_module}}) do
        [] -> :ok
        _components -> write_component_revision(partition, owner_id, component_module, 0)
      end
    end)

    :ok
  end

  defp track_partition_entities(partition) do
    partition
    |> then(&:mnesia.dirty_index_read(Entity, &1, :partition))
    |> Enum.each(fn entity_record ->
      owner_id = entity(entity_record, :id)
      :ets.delete(@tracking_table, {:untracked_entity, owner_id})
      true = :ets.insert(@tracking_table, {{:entity, owner_id}, partition})
    end)

    :ok
  end

  defp track_component_change(partition, owner_id, component_mod) do
    cond do
      revision_tracking?(partition) ->
        write_component_revision(partition, owner_id, component_mod, next_revision(partition))

      membership_tracking?(partition, component_mod) ->
        write_component_revision(partition, owner_id, component_mod, 0)

      true ->
        :ok
    end

    :ok
  end

  defp write_component_revision(partition, owner_id, component_mod, revision_value) do
    :mnesia.write(
      component_revision(
        composite_key: {partition, component_mod, owner_id},
        scope: {partition, component_mod},
        owner_id: owner_id,
        revision: revision_value
      )
    )
  end

  defp delete_component_revision(partition, owner_id, component_mod) do
    delete({ComponentRevision, {partition, component_mod, owner_id}})
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
