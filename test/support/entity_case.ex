defmodule ElvenGard.ECS.EntityCase do
  use ExUnit.CaseTemplate

  alias ElvenGard.ECS.{Entity, Command}

  using _ do
    quote do
      import unquote(__MODULE__), only: [invalid_entity: 0, spawn_entity: 0, spawn_entity: 1]
    end
  end

  ## Helpers

  def invalid_entity(), do: %Entity{id: "<invalid>"}

  def spawn_entity(attrs \\ []) do
    {:ok, entity} = attrs |> Entity.entity_spec() |> Command.spawn_entity()
    entity
  end
end
