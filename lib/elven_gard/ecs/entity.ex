defmodule ElvenGard.ECS.Entity do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Entity
  """

  alias __MODULE__
  alias ElvenGard.ECS.UUID
  alias ElvenGard.ECS.Config

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

  @doc """
  TODO: Documentation
  """
  @spec spawn(entity_spec()) :: {:ok, t()} | {:error, :already_spawned}
  def spawn(specs) do
    Config.backend().spawn_entity(specs)
  end

  @doc """
  TODO: Documentation
  """
  @spec fetch(id()) :: {:ok, t()} | {:error, :not_found}
  def fetch(id) do
    Config.backend().fetch_entity(id)
  end
end
