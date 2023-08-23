defmodule ElvenGard.ECS.Entity do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Entity
  """

  alias __MODULE__
  alias ElvenGard.ECS.UUID

  @type id :: String.t() | integer()
  @type t :: %Entity{id: id()}

  @type entity_spec :: %{
          id: id(),
          components: [module()],
          children: [t()],
          parent: t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id]

  @callback new(Keyword.t()) :: entity_spec()

  # Public API

  @doc """
  TODO: Documentation
  """
  @spec entity_spec(Keyword.t()) :: entity_spec()
  def entity_spec(opts \\ []) do
    default = %{
      id: UUID.uuid4(),
      components: [],
      children: [],
      parent: nil
    }

    Map.merge(default, Map.new(opts))
  end
end
