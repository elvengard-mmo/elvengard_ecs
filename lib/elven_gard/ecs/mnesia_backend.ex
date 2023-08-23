defmodule ElvenGard.ECS.MnesiaBackend do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.MnesiaBackend

  TODO: Write a module for Entities and Components serialization instead of having raw tuples

  Entity Table:

    | entity_id | parent_id or nil |

  """

  use Task

  alias ElvenGard.ECS.Entity

  @timeout 5000

  ## Public API

  @spec start_link(Keyword.t()) :: Task.on_start()
  def start_link(_opts) do
    Task.start_link(__MODULE__, :init, [])
  end

  @spec spawn_entity(Entity.entity_spec()) :: {:ok, Entity.t()} | {:error, :already_spawned}
  def spawn_entity(specs) do
    if length(specs.components) > 0, do: raise("unimplemented")

    transaction(fn ->
      case :mnesia.wread({Entity, specs.id}) do
        [] ->
          # Create our component
          entity_record = mnesia_entity_from_spec(specs)
          :ok = :mnesia.write(entity_record)

          # Set all children's parent
          entity = record_to_struct(entity_record)
          Enum.each(specs.children, &do_set_parent(&1, entity))

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
      [{Entity, ^id, parent_id}] -> {:ok, build_entity(parent_id)}
    end
  end

  @spec children(Entity.t()) :: {:ok, [Entity.t()]}
  def children(%Entity{id: id}) do
    Entity
    |> :mnesia.dirty_index_read(id, :parent_id)
    # Keep only the id
    |> Enum.map(&elem(&1, 1))
    # Fetch the entity if exists
    |> Enum.map(&build_entity/1)
    # Wrap into :ok tuple
    |> then(&{:ok, &1})
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
        attributes: [:id, :parent_id],
        index: [:parent_id]
      )

    :ok = :mnesia.wait_for_tables([Entity], @timeout)
  end

  ## Private Helpers

  defp build_entity(id), do: %Entity{id: id}

  defp record_to_struct({Entity, id, _parent}), do: build_entity(id)

  defp mnesia_entity_from_spec(%{id: id, parent: parent}) do
    case parent do
      nil -> {Entity, id, parent[:id]}
      %Entity{id: parent_id} -> {Entity, id, parent_id}
    end
  end

  defp transaction(query) do
    case :mnesia.transaction(query) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp do_set_parent(%Entity{id: id}, parent) do
    case :mnesia.wread({Entity, id}) do
      [{Entity, ^id, _parent_id}] -> :mnesia.write({Entity, id, parent.id})
      [] -> :mnesia.abort(:not_found)
    end
  end
end
