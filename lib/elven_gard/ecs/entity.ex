defmodule ElvenGard.ECS.Entity do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Entity
  """

  alias __MODULE__
  alias ElvenGard.ECS.UUID
  alias ElvenGard.ECS.Component

  @type t :: %Entity{id: id()}
  @type id :: any()
  @type partition :: :default | any()

  @type spec :: %{
          id: id(),
          components: [Component.spec()],
          children: [t()],
          parent: t() | nil,
          partition: partition
        }

  @enforce_keys [:id]
  defstruct [:id]

  @callback entity_spec(Keyword.t()) :: spec()

  # Public API

  @doc """
  TODO: Documentation
  """
  @spec entity_spec(Keyword.t()) :: spec()
  def entity_spec(opts \\ []) do
    default = %{
      id: UUID.uuid4(),
      components: [],
      children: [],
      parent: nil,
      partition: :default
    }

    Map.merge(default, Map.new(opts))
  end
end
