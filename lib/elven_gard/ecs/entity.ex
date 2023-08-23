defmodule ElvenGard.ECS.Entity do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Entity
  """

  alias ElvenGard.ECS.UUID

  defmacro __using__(opts) do
    components = opts[:components] || raise "components opt is mantatory"

    quote location: :keep do
      import unquote(__MODULE__), only: [def_introspection: 0, def_new: 0]

      @enforce_keys [:id]
      defstruct [:id]

      @components unquote(components)

      unquote(def_introspection())
      unquote(def_new())
    end
  end

  ## Internal API

  def def_introspection() do
    quote location: :keep, unquote: false do
      def __type__(), do: :entity
      def __components__(), do: unquote(@components)
    end
  end

  def def_new() do
    quote location: :keep, unquote: false do
      def new(id \\ nil) do
        id = if is_nil(id), do: UUID.uuid4(), else: id
        %__MODULE__{id: id}
      end
    end
  end
end
