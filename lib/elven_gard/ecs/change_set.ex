defmodule ElvenGard.ECS.ChangeSet do
  @moduledoc """
  Describes writes performed by one successful `ElvenGard.ECS.Multi`.

  A change set is returned only by
  `ElvenGard.ECS.Command.transact_with_changes/1`. It is an immutable value
  scoped to that transaction: the ECS does not retain it, append it to a
  journal, or carry it into later ticks.
  """

  alias __MODULE__
  alias ElvenGard.ECS.{Component, Entity, Multi}

  ## Struct

  defstruct entries: []

  @typedoc "One committed ECS mutation."
  @type change ::
          {:spawn_entity, Entity.t(), [Component.t()]}
          | {:despawn_entity, Entity.t(), [Component.t()]}
          | {:set_parent, Entity.t(), Entity.t() | nil}
          | {:set_partition, Entity.t(), Entity.partition()}
          | {:add_component, Entity.t(), Component.t()}
          | {:delete_component, Entity.t(), module() | Component.t()}
          | {:replace_component, Entity.t(), Component.t()}
          | {:update_component, Entity.t(), Component.t()}

  @opaque t :: %ChangeSet{entries: [{Multi.name(), change()}]}

  ## Public API

  @doc "Returns an empty transaction-scoped change set."
  @spec new() :: t()
  def new(), do: %ChangeSet{}

  @doc "Returns committed mutations in their execution order."
  @spec to_list(t()) :: [{Multi.name(), change()}]
  def to_list(%ChangeSet{entries: entries}), do: Enum.reverse(entries)

  @doc "Returns whether the transaction produced no tracked ECS mutation."
  @spec empty?(t()) :: boolean()
  def empty?(%ChangeSet{entries: entries}), do: entries == []

  ## Internal API

  @doc false
  @spec add(t(), Multi.name(), change()) :: t()
  def add(%ChangeSet{} = change_set, name, change) do
    %{change_set | entries: [{name, change} | change_set.entries]}
  end
end
