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

  describe "parent/1" do
    test "returns the parent using 'parent' entity spec" do
      player = spawn_entity()
      assert {:ok, nil} = Query.parent(player)

      item = spawn_entity(parent: player)
      assert {:ok, ^player} = Query.parent(item)
    end

    test "returns the parent using 'children' entity spec" do
      item1 = spawn_entity()
      assert {:ok, nil} = Query.parent(item1)

      item2 = spawn_entity()
      assert {:ok, nil} = Query.parent(item2)

      player = spawn_entity(children: [item1, item2])
      assert {:ok, ^player} = Query.parent(item1)
      assert {:ok, ^player} = Query.parent(item2)
    end

    test "returns a not found error if entity doesn't exists" do
      assert {:error, :not_found} = Query.parent(%Entity{id: "<invalid>"})
    end
  end

  describe "children/1" do
    test "returns the children using 'parent' entity spec" do
      player = spawn_entity()
      assert {:ok, []} = Query.children(player)

      item1 = spawn_entity(parent: player)
      assert {:ok, [^item1]} = Query.children(player)

      item2 = spawn_entity(parent: player)
      assert {:ok, items} = Query.children(player)
      assert length(items) == 2
      assert item1 in items
      assert item2 in items
    end

    test "returns the children using 'children' entity spec" do
      item1 = spawn_entity()
      assert {:ok, []} = Query.children(item1)

      item2 = spawn_entity()
      assert {:ok, []} = Query.children(item2)

      player = spawn_entity(children: [item1, item2])
      assert {:ok, items} = Query.children(player)
      assert length(items) == 2
      assert item1 in items
      assert item2 in items
    end

    test "returns an empty list if entity doesn't exists" do
      # If the parent entity doesn't exists, it returns an empty list
      # This is a design choice to focus on performance
      # For concistency, the system should check that the parent exists with
      # fetch_entity/1
      assert {:ok, []} = Query.children(%Entity{id: "<invalid>"})
    end
  end

  ## Helpers

  def spawn_entity(attrs \\ []) do
    {:ok, entity} = attrs |> Entity.entity_spec() |> Query.spawn_entity()
    entity
  end
end
