defmodule ElvenGard.ECS.ETSBackend do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.ETSBackend

  TODO: Write a module for Entities and Components serialization instead of having raw tuples

  Entity Table:

    | entity_id | parent_id or nil |

  """

  use Agent

  alias ElvenGard.ECS.Entity

  @agent_name ElvenGard.ECS.Backend

  ## Public API

  @spec start_link(Keyword.t()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(__MODULE__, :init, [], name: @agent_name)
  end

  @spec spawn_entity(Entity.entity_spec()) :: {:ok, Entity.t()} | {:error, :already_spawned}
  def spawn_entity(specs) when is_map(specs) do
    if length(specs.components) > 0, do: raise("unimplemented")
    if length(specs.children) > 0, do: raise("unimplemented")
    if not is_nil(specs.parent), do: raise("unimplemented")

    entity = ets_entity_from_spec(specs)

    case :ets.insert_new(entity_table(), entity) do
      true -> {:ok, ets_entity_to_struct(entity)}
      false -> {:error, :already_spawned}
    end
  end

  @spec fetch_entity(Entity.id()) :: {:ok, Entity.t()} | {:error, :not_found}
  def fetch_entity(id) do
    case :ets.lookup(entity_table(), id) do
      [entity] -> {:ok, ets_entity_to_struct(entity)}
      [] -> {:error, :not_found}
    end
  end

  ## Internal API

  @doc false
  @spec init :: %{entity_table: atom | :ets.tid()}
  def init() do
    entity_table =
      :ets.new(:eg_ecs_entities, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])

    %{entity_table: entity_table}
  end

  ## Private Helpers

  def entity_table(), do: Agent.get(@agent_name, & &1.entity_table)

  def ets_entity_from_spec(%{id: id, parent: parent}) do
    {id, parent[:id]}
  end

  def ets_entity_to_struct({id, _parent}) do
    %Entity{id: id}
  end
end
