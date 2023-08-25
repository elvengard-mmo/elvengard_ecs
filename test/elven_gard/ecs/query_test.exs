defmodule ElvenGard.ECS.QueryTest do
  use ElvenGard.ECS.EntityCase, async: true

  alias ElvenGard.ECS.Query
  alias ElvenGard.ECS.Components.{BuffComponent, PlayerComponent, PositionComponent}

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
      assert {:error, :not_found} = Query.parent(invalid_entity())
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
      # For concistency, the System should check that the parent exists with
      # fetch_entity/1
      assert {:ok, []} = Query.children(invalid_entity())
    end
  end

  describe "parent_of?/2" do
    test "returns if an Entity is the parent of another" do
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
    test "returns if an Entity is the child of another" do
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
      # For concistency, the System should check that the parent exists with
      # fetch_entity/1
      assert {:ok, []} = Query.components(invalid_entity())
    end
  end

  describe "fetch_components/2" do
    test "returns a list of components by it's module name" do
      components = [
        {PlayerComponent, []},
        {BuffComponent, [buff_id: 1]},
        {BuffComponent, [buff_id: 2]}
      ]

      player = spawn_entity(components: components)

      assert {:ok, [player_component]} = Query.fetch_components(player, PlayerComponent)
      assert %PlayerComponent{name: "Player"} = player_component

      assert {:ok, [buff1, buff2]} = Query.fetch_components(player, BuffComponent)
      assert %BuffComponent{buff_id: 1} = buff1
      assert %BuffComponent{buff_id: 2} = buff2
    end

    test "returns an empty list if the Entity or Component doesn't exists" do
      # If the Entity or Component doesn't exists, it returns an empty list
      # This is a design choice to focus on performance
      # For concistency, the System should check that the Entity exists with
      # fetch_entity/1
      assert {:ok, []} = Query.fetch_components(invalid_entity(), PlayerComponent)
      assert {:ok, []} = Query.fetch_components(spawn_entity(), InvalidComponent)
    end
  end

  describe "fetch_component/2" do
    test "returns a component by it's module name" do
      components = [{PositionComponent, [pos_x: 13, pos_y: 37]}]
      entity = spawn_entity(components: components)

      assert {:ok, component} = Query.fetch_component(entity, PositionComponent)
      assert %PositionComponent{map_id: 1, pos_x: 13, pos_y: 37} = component

      assert {:error, :not_found} = Query.fetch_component(entity, PlayerComponent)
    end

    test "returns a not_found error if the entity doesn't exists" do
      assert {:error, :not_found} = Query.fetch_component(invalid_entity(), PlayerComponent)
    end

    test "raises an error if more that 1 component is found" do
      # Mnesia doesn't seems to support duplicate bag so components must be differents
      components = [{BuffComponent, [buff_id: 1]}, {BuffComponent, [buff_id: 2]}]
      entity = spawn_entity(components: components)

      assert_raise RuntimeError, ~r/have more that 1 component of type/, fn ->
        Query.fetch_component(entity, BuffComponent)
      end
    end
  end
end
