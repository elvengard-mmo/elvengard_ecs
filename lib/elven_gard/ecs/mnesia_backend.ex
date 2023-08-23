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
    if length(specs.children) > 0, do: raise("unimplemented")

    transaction(fn ->
      case :mnesia.wread({Entity, specs.id}) do
        [_] ->
          :mnesia.abort(:already_spawned)

        [] ->
          entity = entity_from_spec(specs)
          :mnesia.write(entity)
          record_to_struct(entity)
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
      [{Entity, ^id, nil}] -> {:ok, nil}
      [{Entity, ^id, parent_id}] -> fetch_entity(parent_id)
      [] -> {:error, :not_found}
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
        attributes: [:id, :parent_id],
        index: [:parent_id]
      )

    :ok = :mnesia.wait_for_tables([Entity], @timeout)
  end

  ## Private Helpers

  defp entity_from_spec(%{id: id, parent: parent}) do
    case parent do
      nil -> {Entity, id, parent[:id]}
      %Entity{id: parent_id} -> {Entity, id, parent_id}
    end
  end

  defp record_to_struct({Entity, id, _parent}) do
    %Entity{id: id}
  end

  defp transaction(query) do
    case :mnesia.transaction(query) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end
end
