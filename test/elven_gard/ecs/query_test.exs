defmodule ElvenGard.ECS.QueryTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Command, Entity, Query}

  ## Tests - Entities

  test "fetch_entity/1 returns an entity if found" do
    entity = spawn_entity()

    assert {:ok, ^entity} = Query.fetch_entity(entity.id)
    assert {:error, :not_found} = Query.fetch_entity("<unknown>")
  end

  ## Tests - Relationships

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

  describe "parent_of?/2" do
    test "return if an Entity is the parent of another" do
      dummy = spawn_entity()
      parent = spawn_entity()
      child = spawn_entity(parent: parent)

      assert Query.parent_of?(parent, child)
      refute Query.parent_of?(child, parent)
      refute Query.parent_of?(dummy, parent)
      refute Query.parent_of?(dummy, child)
    end
  end

  describe "child_of?/2" do
    test "return if an Entity is the child of another" do
      dummy = spawn_entity()
      parent = spawn_entity()
      child = spawn_entity(parent: parent)

      assert Query.child_of?(child, parent)
      refute Query.child_of?(parent, child)
      refute Query.child_of?(dummy, child)
      refute Query.child_of?(dummy, parent)
    end
  end

  ## Tests - Components

  defmodule PlayerComponent do
    use ElvenGard.ECS.Component, state: [name: "Player"]
  end

  defmodule PositionComponent do
    use ElvenGard.ECS.Component, state: [map_id: 1, pos_x: 0, pos_y: 0]
  end

  describe "components/1" do
    test "returns a list of components for an Entity" do
      entity = spawn_entity()
      assert {:ok, []} = Query.components(entity)

      entity2 = spawn_entity(components: [PlayerComponent])
      assert {:ok, [player_component2]} = Query.components(entity2)
      assert %PlayerComponent{name: "Player"} = player_component2

      entity3 = spawn_entity(components: [{PlayerComponent, [name: "TestPlayer"]}])
      assert {:ok, [player_component3]} = Query.components(entity3)
      assert %PlayerComponent{name: "TestPlayer"} = player_component3

      components4 = [{PlayerComponent, []}, {PositionComponent, [pos_x: 13, pos_y: 37]}]
      entity4 = spawn_entity(components: components4)
      assert {:ok, [player_component4, position_component4]} = Query.components(entity4)
      assert %PlayerComponent{name: "Player"} = player_component4
      assert %PositionComponent{map_id: 1, pos_x: 13, pos_y: 37} = position_component4
    end

    test "returns an empty list if entity doesn't exists" do
      # If the parent entity doesn't exists, it returns an empty list
      # This is a design choice to focus on performance
      # For concistency, the system should check that the parent exists with
      # fetch_entity/1
      assert {:ok, []} = Query.components(%Entity{id: "<invalid>"})
    end
  end

  ## Helpers

  def spawn_entity(attrs \\ []) do
    {:ok, entity} = attrs |> Entity.entity_spec() |> Command.spawn_entity()
    entity
  end
end
