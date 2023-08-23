defmodule ElvenGard.ECS.Entity do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Entity
  """

  import ElvenGard.ECS, only: [is_entity: 1]

  alias __MODULE__
  alias ElvenGard.ECS.UUID
  alias ElvenGard.ECS.Config

  @type t :: struct()

  @type id :: String.t() | integer()
  @type entity_spec :: %{
          id: id(),
          components: [module()],
          children: [Entity.t()],
          parents: [Entity.t()]
        }

  @callback new(Keyword.t()) :: entity_spec()

  # Public API

  @doc false
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      @derive {Inspect, only: [:id]}
      @enforce_keys [:id]
      defstruct [:id, __type__: :entity]
    end
  end

  @spec entity_spec(Keyword.t()) :: entity_spec()
  def entity_spec(opts \\ []) do
    default = %{
      id: UUID.uuid4(),
      components: [],
      children: [],
      parents: []
    }

    Map.merge(default, Map.new(opts))
  end

  @doc """
  TODO: Documentation
  """
  def spawn(entity_module, opts) when is_atom(entity_module) do
    Config.backend().spawn_entity(entity_module, opts)
  end
end
