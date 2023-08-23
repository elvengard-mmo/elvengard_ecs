defmodule ElvenGard.ECS.QueryTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Entity, Query}

  ## Tests

  test "spawn_entity/1 register an entity" do
    specs = Entity.entity_spec()

    assert {:ok, %Entity{} = entity} = Query.spawn_entity(specs)
    assert specs.id == entity.id

    assert {:error, :already_spawned} = Query.spawn_entity(specs)
  end

  test "fetch_entity/1 return an entity if found" do
    entity = spawn_entity()

    assert {:ok, ^entity} = Query.fetch_entity(entity.id)
    assert {:error, :not_found} = Query.fetch_entity("<unknown>")
  end

  test "parent returns the parent if any" do
    player = spawn_entity()
    assert {:ok, nil} = Query.parent(player)

    item = spawn_entity(parent: player)
    assert {:ok, ^player} = Query.parent(item)

    assert {:error, :not_found} = Query.parent(%Entity{id: "<invalid>"})
  end

  ## Helpers

  def spawn_entity(attrs \\ []) do
    {:ok, entity} = attrs |> Entity.entity_spec() |> Query.spawn_entity()
    entity
  end
end
