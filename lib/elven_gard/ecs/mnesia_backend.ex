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

  alias ElvenGard.ECS.{Component, Entity}

  @timeout 5000

  ## Public API

  @spec start_link(Keyword.t()) :: Task.on_start()
  def start_link(_opts) do
    Task.start_link(__MODULE__, :init, [])
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

  ### Entities

  @spec create_entity(Entity.id(), Entity.t()) :: {:ok, Entity.t()} | {:error, :already_exists}
  def create_entity(id, parent) do
    parent_id = if not is_nil(parent), do: parent.id
    entity = entity(id: id, parent_id: parent_id)

    case insert_new(entity) do
      :ok -> {:ok, build_entity_struct(id)}
      {:error, :already_exists} = error -> error
    end
  end

  @spec set_parent(Entity.t(), Entity.t()) :: :ok | {:error, :not_found}
  def set_parent(%Entity{id: id}, parent) do
    parent_id = if not is_nil(parent), do: parent.id

    entity(id: id, parent_id: parent_id)
    |> update()
  end

  @spec add_component(Entity.t(), Component.spec()) :: :ok
  def add_component(%Entity{id: id}, component_spec) do
    component_spec
    |> Component.spec_to_struct()
    |> then(&component(type: &1.__struct__, owner_id: id, component: &1))
    |> insert()
  end

  ### Dirty operations

  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
    case :mnesia.dirty_read({Entity, id}) do
      [entity] -> {:ok, record_to_struct(entity)}
      [] -> {:error, :not_found}
    end
  end

  @spec parent(Entity.t()) :: {:ok, nil | Entity.t()} | {:error, :not_found}
  def parent(%Entity{id: id}) do
    case :mnesia.dirty_read({Entity, id}) do
      [] -> {:error, :not_found}
      [{Entity, ^id, nil}] -> {:ok, nil}
      [{Entity, ^id, parent_id}] -> {:ok, build_entity_struct(parent_id)}
    end
  end

  @spec children(Entity.t()) :: {:ok, [Entity.t()]}
  def children(%Entity{id: id}) do
    Entity
    |> :mnesia.dirty_index_read(id, :parent_id)
    # Keep only the id
    |> Enum.map(&entity(&1, :id))
    # Transform the id into an Entity struct
    |> Enum.map(&build_entity_struct/1)
    # Wrap into :ok tuple
    |> then(&{:ok, &1})
  end

  @spec parent_of?(Entity.t(), Entity.t()) :: boolean()
  def parent_of?(%Entity{id: parent_id}, %Entity{id: child_id}) do
    case :mnesia.dirty_read({Entity, child_id}) do
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

  @spec components(Entity.t()) :: {:ok, [Component.t()]}
  def components(%Entity{id: id}) do
    Component
    |> :mnesia.dirty_index_read(id, :owner_id)
    # Keep only the component
    |> Enum.map(&component(&1, :component))
    # Wrap into :ok tuple
    |> then(&{:ok, &1})
  end

  @spec fetch_components(Entity.t(), module()) :: {:ok, [Component.t()]}
  def fetch_components(%Entity{id: owner_id}, component) do
    # TODO: Generate the select query
    match = {Component, :"$1", :"$2", :"$3"}
    guards = [{:==, :"$1", component}, {:==, :"$2", owner_id}]
    result = [:"$3"]
    query = [{match, guards, result}]

    {:ok, :mnesia.dirty_select(Component, query)}
  end

  ## Internal API

  @doc false
  @spec init() :: :ok
  def init() do
    # Start Mnesia
    :ok = :mnesia.start()

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

  defp update(record) do
    do_update(
      elem(record, 0),
      elem(record, 1),
      record,
      :mnesia.is_transaction()
    )
  end

  defp do_update(type, key, record, false) do
    case :mnesia.dirty_read({type, key}) do
      [] -> {:error, :not_found}
      _ -> :mnesia.dirty_write(record)
    end
  end

  defp do_update(type, key, record, true) do
    case :mnesia.read({type, key}) do
      [] -> :mnesia.abort(:not_found)
      _ -> :mnesia.write(record)
    end
  end

  defp build_entity_struct(id), do: %Entity{id: id}

  defp record_to_struct(entity_record) do
    entity_record
    |> entity(:id)
    |> build_entity_struct()
  end
end
