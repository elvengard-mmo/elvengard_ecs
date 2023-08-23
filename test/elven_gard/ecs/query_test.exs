defmodule ElvenGard.ECS.QueryTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Entity, Query}

  test "spawn_entity/1 register an entity" do
    specs = Entity.entity_spec()

    assert {:ok, %Entity{} = entity} = Query.spawn_entity(specs)
    assert specs.id == entity.id

    assert {:error, :already_spawned} = Query.spawn_entity(specs)
  end

  test "fetch_entity/1 return an entity if found" do
    specs = Entity.entity_spec()
    {:ok, entity} = Query.spawn_entity(specs)

    assert {:ok, ^entity} = Query.fetch_entity(specs.id)
    assert {:error, :not_found} = Query.fetch_entity("<unknown>")
  end
end
