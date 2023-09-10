defmodule ElvenGard.ECS.Command do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Write in Backend (DIRTY or Transaction depending on the context)
  """

  alias ElvenGard.ECS
  alias ElvenGard.ECS.Events.{EntitySpawned, ComponentCreated}
  alias ElvenGard.ECS.{Config, Entity}

  ## Transactions

  @spec transaction((() -> result)) :: {:error, result} | {:ok, any()} when result: any()
  def transaction(query) do
    Config.backend().transaction(query)
  end

  @spec abort(any()) :: no_return()
  def abort(reason) do
    Config.backend().abort(reason)
  end

  ## Entities

  @doc """
  Transactional way to spawn an Entity
  """
  @spec spawn_entity(Entity.spec()) :: {:ok, Entity.t()} | {:error, reason}
        when reason: :already_exists | :cant_set_children
  def spawn_entity(specs) when is_map(specs) do
    %{
      components: components,
      children: children
    } = specs

    fn ->
      with {:ok, entity} <- create_entity(specs),
           :ok <- set_children(entity, children),
           components <- add_components(entity, components),
           {:ok, _} <- push_spawn_events(entity, components, specs) do
        entity
      else
        {:error, reason} -> abort(reason)
      end
    end
    |> transaction()
  end

  @doc """
  TODO: Documentation
  """
  @spec set_parent(Entity.t(), Entity.t() | nil) :: :ok | {:error, :not_found}
  def set_parent(%Entity{} = entity, parent) do
    Config.backend().set_parent(entity, parent)
  end

  @doc """
  TODO: Documentation
  """
  @spec add_component(Entity.t(), Component.spec()) :: Component.t()
  def add_component(%Entity{} = entity, component_spec) do
    Config.backend().add_component(entity, component_spec)
  end

  ## Components

  ## Private helpers

  defp create_entity(%{id: id, parent: parent}) do
    Config.backend().create_entity(id, parent)
  end

  defp set_children(entity, children) do
    children
    |> Enum.map(&set_parent(&1, entity))
    |> Enum.all?(&match?(:ok, &1))
    |> then(&if &1, do: :ok, else: {:error, :cant_set_children})
  end

  defp add_components(entity, components) do
    Enum.map(components, &add_component(entity, &1))
  end

  defp push_spawn_events(entity, components, specs) do
    %{children: children, parent: parent} = specs

    entity_event = %EntitySpawned{
      entity: entity,
      components: components,
      children: children,
      parent: parent
    }

    events = Enum.map(components, &%ComponentCreated{entity: entity, component: &1})
    ECS.push([entity_event | events], partition: :system)
  end
end
