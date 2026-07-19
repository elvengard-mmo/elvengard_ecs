defmodule ElvenGard.ECS.Command do
  @moduledoc """
  Write API for entities, components, and relationships.

  Commands delegate to the configured backend. Compound operations such as
  spawning and despawning entities run in a transaction so failures roll back
  the complete operation.
  """

  alias ElvenGard.ECS.{Component, Config, Entity, Query}

  ## Transactions

  @doc """
  Executes a function in a backend transaction.

  Returns `{:ok, result}` when the function completes or `{:error, reason}`
  when the transaction is aborted.
  """
  @spec transaction((-> result)) :: {:error, any()} | {:ok, result} when result: any()
  def transaction(query) do
    Config.backend().transaction(query)
  end

  @doc "Aborts the current backend transaction with `reason`."
  @spec abort(any()) :: no_return()
  def abort(reason) do
    Config.backend().abort(reason)
  end

  ## Entities

  @doc """
  Creates an entity and its relationships and components atomically.

  Build `specs` with `ElvenGard.ECS.Entity.entity_spec/1`. The operation is
  rolled back when the ID already exists, a parent cycle is detected, or a
  child cannot be attached.
  """
  @spec spawn_entity(Entity.spec()) :: {:ok, {Entity.t(), [Component.t()]}} | {:error, reason}
        when reason: :already_exists | :cant_set_children | :cyclic_relationship
  def spawn_entity(specs) when is_map(specs) do
    %{
      components: components_specs,
      children: children
    } = specs

    fn ->
      with {:ok, entity} <- create_entity(specs),
           :ok <- set_children(entity, children),
           components <- add_components(entity, components_specs) do
        {entity, components}
      else
        {:error, reason} -> abort(reason)
      end
    end
    |> transaction()
  end

  @doc """
  Deletes an entity and its components atomically.

  By default, descendants are deleted recursively. `on_child_delete` receives
  each direct child and its components and must return `:delete` to delete that
  subtree or `:ignore` to keep it. A failure anywhere in the cascade rolls back
  the complete transaction.
  """
  @spec despawn_entity(Entity.t(), (Entity.t(), [Component.t()] -> :delete | :ignore)) ::
          {:ok, {Entity.t(), [Component.t()]}} | {:error, any()}
  def despawn_entity(%Entity{} = entity, on_child_delete \\ fn _, _ -> :delete end) do
    fn -> do_despawn_entity(entity, on_child_delete) end
    |> transaction()
  end

  @doc """
  Sets or clears the direct parent of an entity.

  Returns `{:error, :cyclic_relationship}` when the relationship would make
  the entity one of its own ancestors.
  """
  @spec set_parent(Entity.t(), Entity.t() | nil) ::
          :ok | {:error, :cyclic_relationship | :not_found}
  def set_parent(%Entity{} = entity, parent) do
    Config.backend().set_parent(entity, parent)
  end

  @doc """
  Moves an entity to a partition.
  """
  @spec set_partition(Entity.t(), Entity.partition()) :: :ok | {:error, :not_found}
  def set_partition(%Entity{} = entity, partition) do
    Config.backend().set_partition(entity, partition)
  end

  @doc """
  Adds a component to an entity.

  Accepts a component module, a `{module, attributes}` specification, or an
  already constructed component struct. Multiple distinct components of the
  same module may be attached to one entity.
  """
  @spec add_component(Entity.t(), Component.spec() | Component.t()) :: {:ok, Component.t()}
  def add_component(%Entity{} = entity, component_or_spec) do
    Config.backend().add_component(entity, component_or_spec)
  end

  @doc """
  Deletes components from an entity.

  Passing a component module deletes every component of that module. Passing a
  component struct deletes only components equal to that struct.
  """
  @spec delete_component(Entity.t(), module() | Component.t()) :: :ok
  def delete_component(%Entity{} = entity, component) do
    Config.backend().delete_component(entity, component)
  end

  @doc """
  Replaces every component of the same module with `component`.
  """
  @spec replace_component(Entity.t(), Component.t()) :: :ok
  def replace_component(%Entity{} = entity, %_{} = component) do
    Config.backend().replace_component(entity, component)
  end

  @doc """
  Updates one component using `attrs`.

  Passing a component struct selects that exact value. Passing a module
  succeeds only when the entity owns exactly one component of that module;
  otherwise it returns `:not_found` or `:multiple_values`.
  """
  @spec update_component(Entity.t(), module() | Component.t(), Keyword.t()) ::
          {:ok, Component.t()} | {:error, :not_found | :multiple_values}
  def update_component(%Entity{} = entity, component, attrs) do
    Config.backend().update_component(entity, component, attrs)
  end

  ## Components

  ## Private helpers

  defp unwrap({:ok, value}), do: value

  defp create_entity(%{id: id, parent: parent, partition: partition}) do
    Config.backend().create_entity(id, parent, partition)
  end

  defp set_children(entity, children) do
    children
    |> Enum.map(&set_parent(&1, entity))
    |> Enum.all?(&match?(:ok, &1))
    |> then(&if &1, do: :ok, else: {:error, :cant_set_children})
  end

  defp add_components(entity, components) do
    components
    |> Enum.map(&add_component(entity, &1))
    |> Enum.map(fn {:ok, component} -> component end)
  end

  defp do_despawn_entity(entity, on_child_delete) do
    entity
    |> Query.children()
    |> then(&unwrap/1)
    |> Enum.map(&{&1, unwrap(Query.list_components(&1))})
    |> Enum.map(fn {entity, components} = tuple ->
      {tuple, on_child_delete.(entity, components)}
    end)
    |> Enum.each(&maybe_despawn_child(&1, on_child_delete))

    {:ok, components} = Config.backend().delete_components_for(entity)
    :ok = Config.backend().delete_entity(entity)

    {entity, components}
  end

  defp maybe_despawn_child({_tuple, :ignore}, _on_child_delete), do: :ok

  defp maybe_despawn_child({{entity, _components}, :delete}, on_child_delete) do
    do_despawn_entity(entity, on_child_delete)
  end

  defp maybe_despawn_child({tuple, value}, _on_child_delete) do
    raise "on_child_delete/2 must return :ignore or :delete. " <>
            "Got #{inspect(value)} for #{inspect(tuple, limit: :infinity)}"
  end
end
