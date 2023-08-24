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

  @spec spawn_entity(Entity.entity_spec()) :: {:ok, Entity.t()} | {:error, :already_spawned}
  def spawn_entity(specs) do
    transaction(fn ->
      case :mnesia.wread({Entity, specs.id}) do
        [] ->
          # Create our component
          entity_record = mnesia_entity_from_spec(specs)
          :ok = :mnesia.write(entity_record)

          # Set all children's parent
          entity = record_to_struct(entity_record)
          Enum.each(specs.children, &do_set_parent(&1, entity))

          # Write all components
          specs.components
          |> Enum.map(&Component.spec_to_struct/1)
          |> Enum.each(&do_add_component(entity, &1))

          # Return our Entity structure
          entity

        [_] ->
          :mnesia.abort(:already_spawned)
      end
    end)
  end

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

  @spec fetch_component(Entity.t(), module()) :: {:ok, Component.t()} | {:error, :not_found}
  def fetch_component(%Entity{id: owner_id} = entity, component) do
    # TODO: Generate the select query
    match = {Component, :"$1", :"$2", :"$3"}
    guards = [{:==, :"$1", component}, {:==, :"$2", owner_id}]
    result = [:"$3"]
    query = [{match, guards, result}]

    case :mnesia.dirty_select(Component, query) do
      [] -> {:error, :not_found}
      [component] -> {:ok, component}
      _ -> raise "#{inspect(entity)} have more that 1 component of type #{inspect(component)}"
    end
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

  defp build_entity_struct(id), do: %Entity{id: id}

  defp record_to_struct(entity_record) do
    entity_record
    |> entity(:id)
    |> build_entity_struct()
  end

  defp mnesia_entity_from_spec(%{id: id, parent: parent}) do
    case parent do
      nil -> entity(id: id)
      %Entity{id: parent_id} -> entity(id: id, parent_id: parent_id)
    end
  end

  defp transaction(query) do
    case :mnesia.transaction(query) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp do_set_parent(%Entity{id: id}, parent) do
    entity(id: id, parent_id: parent.id) |> :mnesia.write()
  end

  defp do_add_component(%Entity{id: owner_id}, %component_mod{} = component) do
    component(type: component_mod, owner_id: owner_id, component: component)
    |> :mnesia.write()
  end
end
