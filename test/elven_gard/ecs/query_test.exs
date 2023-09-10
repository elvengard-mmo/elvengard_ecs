defmodule ElvenGard.ECS.QueryTest do
  use ElvenGard.ECS.EntityCase, async: true

  alias ElvenGard.ECS.Query
  alias ElvenGard.ECS.Components.{BuffComponent, PlayerComponent, PositionComponent}

  ## General

  describe "select/2 + all/1" do
    test "Entities + component modules + preload" do
      %{player1: player1, pet1: pet1, player2: player2} = spawn_few_entities()

      query =
        Query.select(
          ElvenGard.ECS.Entity,
          with: [PositionComponent],
          preload: [BuffComponent]
        )

      assert %Query{} = query

      result = Query.all(query)
      assert is_list(result)
      assert length(result) == 3

      assert bundle1 = Enum.find(result, &(elem(&1, 0).id == player1.id))
      assert {^player1, components1} = bundle1
      assert length(components1) == 3
      assert %PositionComponent{map_id: 1, pos_x: 0, pos_y: 0} in components1
      assert %BuffComponent{buff_id: 42} in components1
      assert %BuffComponent{buff_id: 1337} in components1

      assert bundle2 = Enum.find(result, &(elem(&1, 0).id == pet1.id))
      assert {^pet1, components2} = bundle2
      assert length(components2) == 1
      assert %PositionComponent{map_id: 1, pos_x: 0, pos_y: 0} in components2

      assert bundle3 = Enum.find(result, &(elem(&1, 0).id == player2.id))
      assert {^player2, components3} = bundle3
      assert length(components3) == 2
      assert %PositionComponent{map_id: 2, pos_x: 0, pos_y: 0} in components3
      assert %BuffComponent{buff_id: 42} in components1
    end

    test "Entities + component specs + preload" do
      %{player1: player1, pet1: pet1, player2: _player2} = spawn_few_entities()

      query =
        Query.select(
          ElvenGard.ECS.Entity,
          with: [{PositionComponent, [{:==, :map_id, 1}]}],
          preload: [BuffComponent]
        )

      assert %Query{} = query
      assert result = Query.all(query)
      assert length(result) == 2

      assert bundle1 = Enum.find(result, &(elem(&1, 0).id == player1.id))
      assert {^player1, components1} = bundle1
      assert length(components1) == 3
      assert %PositionComponent{map_id: 1, pos_x: 0, pos_y: 0} in components1
      assert %BuffComponent{buff_id: 42} in components1
      assert %BuffComponent{buff_id: 1337} in components1

      assert bundle2 = Enum.find(result, &(elem(&1, 0).id == pet1.id))
      assert {^pet1, components2} = bundle2
      assert length(components2) == 1
      assert %PositionComponent{map_id: 1, pos_x: 0, pos_y: 0} in components2
    end
  end

  describe "select_entities/1" do
    test "with parent" do
      %{player1: player1, pet1: pet1, player2: player2} = spawn_few_entities()

      assert {:ok, [^pet1]} = Query.select_entities(with_parent: player1)
      assert {:ok, []} = Query.select_entities(with_parent: player2)
      assert {:ok, []} = Query.select_entities(with_parent: pet1)
    end

    test "without parent" do
      %{player1: player1, pet1: pet1, player2: player2} = spawn_few_entities()

      assert {:ok, entities} = Query.select_entities(without_parent: player1)
      refute pet1 in entities
      assert player1 in entities
      assert player2 in entities

      assert {:ok, entities} = Query.select_entities(without_parent: player2)
      assert pet1 in entities
      assert player1 in entities
      assert player2 in entities
    end

    test "with component" do
      %{player1: player1, pet1: pet1, player2: player2} = spawn_few_entities()

      assert {:ok, entities} = Query.select_entities(with_component: PlayerComponent)
      assert player1 in entities
      assert player2 in entities
      refute pet1 in entities

      assert {:ok, entities} = Query.select_entities(with_component: PositionComponent)
      assert player1 in entities
      assert player2 in entities
      assert pet1 in entities

      assert {:ok, entities} = Query.select_entities(with_component: BuffComponent)
      assert player1 in entities
      assert player2 in entities
      refute pet1 in entities
    end
  end

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

  ## Helpers

  defp spawn_few_entities() do
    player1 =
      spawn_entity(
        components: [
          {PlayerComponent, [name: "Player1"]},
          {PositionComponent, [map_id: 1]},
          {BuffComponent, [buff_id: 42]},
          {BuffComponent, [buff_id: 1337]}
        ]
      )

    player2 =
      spawn_entity(
        components: [
          {PlayerComponent, [name: "Player2"]},
          {PositionComponent, [map_id: 2]},
          {BuffComponent, [buff_id: 42]}
        ]
      )

    pet1 =
      spawn_entity(
        parent: player1,
        components: [
          {PositionComponent, [map_id: 1]}
        ]
      )

    %{player1: player1, pet1: pet1, player2: player2}
  end
end
