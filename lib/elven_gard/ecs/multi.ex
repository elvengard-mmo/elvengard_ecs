defmodule ElvenGard.ECS.Multi do
  @moduledoc """
  Builds ordered, named ECS commands for one atomic transaction.

  A multi is an immutable description. Execute it with
  `ElvenGard.ECS.Command.transact/1`. Successful operation results are stored
  under their names and are available to later resolver and `run/3` functions.
  The first error rolls every write back and identifies the failed operation.
  """

  alias __MODULE__

  ## Struct

  defstruct operations: [], names: MapSet.new()

  @typedoc "A unique operation name."
  @type name :: any()

  @typedoc "Results produced by successful operations so far."
  @type changes :: %{optional(name()) => any()}

  @typedoc "A direct operation argument or a resolver using prior results."
  @type value_or_fun :: any() | (changes() -> any())

  @typedoc "The result returned when one named operation fails."
  @type failure :: {:error, name(), any(), changes()}

  @typep operation ::
           {:spawn_entity, value_or_fun()}
           | {:despawn_entity, value_or_fun(), (ElvenGard.ECS.Entity.t(), [struct()] -> any())}
           | {:despawn_preloaded_entity, value_or_fun(), value_or_fun(),
              (ElvenGard.ECS.Entity.t(), [struct()] -> any())}
           | {:set_parent, value_or_fun(), value_or_fun()}
           | {:set_partition, value_or_fun(), value_or_fun()}
           | {:add_component, value_or_fun(), value_or_fun()}
           | {:delete_component, value_or_fun(), value_or_fun()}
           | {:replace_component, value_or_fun(), value_or_fun()}
           | {:update_component, value_or_fun(), value_or_fun(), value_or_fun()}
           | {:put, any()}
           | {:run, (changes() -> {:ok, any()} | {:error, any()})}
           | {:error, any()}
           | {:merge, (changes() -> t())}

  @opaque t :: %Multi{operations: [{name(), operation()}], names: MapSet.t(name())}

  ## Public API

  @doc "Returns an empty multi."
  @spec new() :: t()
  def new(), do: %Multi{}

  @doc "Adds an entity spawn command."
  @spec spawn_entity(t(), name(), value_or_fun()) :: t()
  def spawn_entity(%Multi{} = multi, name, spec) do
    add_operation(multi, name, {:spawn_entity, spec})
  end

  @doc "Adds an entity despawn command."
  @spec despawn_entity(
          t(),
          name(),
          value_or_fun(),
          (ElvenGard.ECS.Entity.t(), [struct()] -> :delete | :ignore)
        ) :: t()
  def despawn_entity(
        %Multi{} = multi,
        name,
        entity,
        on_child_delete \\ fn _entity, _components -> :delete end
      ) do
    add_operation(multi, name, {:despawn_entity, entity, on_child_delete})
  end

  @doc "Adds a despawn command using the entity's complete preloaded component set."
  @spec despawn_preloaded_entity(
          t(),
          name(),
          value_or_fun(),
          value_or_fun(),
          (ElvenGard.ECS.Entity.t(), [struct()] -> :delete | :ignore)
        ) :: t()
  def despawn_preloaded_entity(
        %Multi{} = multi,
        name,
        entity,
        components,
        on_child_delete \\ fn _entity, _components -> :delete end
      ) do
    add_operation(
      multi,
      name,
      {:despawn_preloaded_entity, entity, components, on_child_delete}
    )
  end

  @doc "Adds a direct-parent update."
  @spec set_parent(t(), name(), value_or_fun(), value_or_fun()) :: t()
  def set_parent(%Multi{} = multi, name, entity, parent) do
    add_operation(multi, name, {:set_parent, entity, parent})
  end

  @doc "Adds a partition update."
  @spec set_partition(t(), name(), value_or_fun(), value_or_fun()) :: t()
  def set_partition(%Multi{} = multi, name, entity, partition) do
    add_operation(multi, name, {:set_partition, entity, partition})
  end

  @doc "Adds a component value to an entity."
  @spec add_component(t(), name(), value_or_fun(), value_or_fun()) :: t()
  def add_component(%Multi{} = multi, name, entity, component) do
    add_operation(multi, name, {:add_component, entity, component})
  end

  @doc "Deletes component values from an entity."
  @spec delete_component(t(), name(), value_or_fun(), value_or_fun()) :: t()
  def delete_component(%Multi{} = multi, name, entity, component) do
    add_operation(multi, name, {:delete_component, entity, component})
  end

  @doc "Replaces every component of the same module on an entity."
  @spec replace_component(t(), name(), value_or_fun(), value_or_fun()) :: t()
  def replace_component(%Multi{} = multi, name, entity, component) do
    add_operation(multi, name, {:replace_component, entity, component})
  end

  @doc "Updates one selected component on an entity."
  @spec update_component(t(), name(), value_or_fun(), value_or_fun(), value_or_fun()) :: t()
  def update_component(%Multi{} = multi, name, entity, component, attrs) do
    add_operation(multi, name, {:update_component, entity, component, attrs})
  end

  @doc "Adds an already available result without executing a command."
  @spec put(t(), name(), any()) :: t()
  def put(%Multi{} = multi, name, value) do
    add_operation(multi, name, {:put, value})
  end

  @doc "Adds a function returning `{:ok, value}` or `{:error, reason}`."
  @spec run(t(), name(), (changes() -> {:ok, any()} | {:error, any()})) :: t()
  def run(%Multi{} = multi, name, function) when is_function(function, 1) do
    add_operation(multi, name, {:run, function})
  end

  @doc "Adds an operation that always fails with `reason`."
  @spec error(t(), name(), any()) :: t()
  def error(%Multi{} = multi, name, reason) do
    add_operation(multi, name, {:error, reason})
  end

  @doc "Appends all operations from `right` after `left`."
  @spec append(t(), t()) :: t()
  def append(%Multi{} = left, %Multi{} = right) do
    merge_structs(left, right, &(&2 ++ &1))
  end

  @doc "Prepends all operations from `right` before `left`."
  @spec prepend(t(), t()) :: t()
  def prepend(%Multi{} = left, %Multi{} = right) do
    merge_structs(left, right, &(&1 ++ &2))
  end

  @doc "Dynamically merges a multi built from results produced so far."
  @spec merge(t(), (changes() -> t())) :: t()
  def merge(%Multi{} = multi, function) when is_function(function, 1) do
    %{multi | operations: [{:merge, {:merge, function}} | multi.operations]}
  end

  @doc "Returns named operations in execution order."
  @spec to_list(t()) :: [{name(), any()}]
  def to_list(%Multi{operations: operations}) do
    Enum.reverse(operations)
  end

  ## Internal API

  @doc false
  @spec __names__(t()) :: MapSet.t(name())
  def __names__(%Multi{names: names}), do: names

  ## Private function

  defp add_operation(%Multi{} = multi, name, operation) do
    case MapSet.member?(multi.names, name) do
      true ->
        raise ArgumentError, "#{inspect(name)} is already a member of ElvenGard.ECS.Multi"

      false ->
        %{
          multi
          | operations: [{name, operation} | multi.operations],
            names: MapSet.put(multi.names, name)
        }
    end
  end

  defp merge_structs(%Multi{} = left, %Multi{} = right, joiner) do
    common_names = left.names |> MapSet.intersection(right.names) |> MapSet.to_list()

    case common_names do
      [] ->
        %Multi{
          operations: joiner.(left.operations, right.operations),
          names: MapSet.union(left.names, right.names)
        }

      names ->
        raise ArgumentError,
              "cannot combine ElvenGard.ECS.Multi values because both declared operations: " <>
                inspect(names)
    end
  end
end
