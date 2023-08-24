defmodule ElvenGard.ECS.CommandTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Command, Entity, Query}

  ## Test Structures

  defmodule PlayerComponent do
    use ElvenGard.ECS.Component, state: [name: "Player"]
  end

  defmodule PositionComponent do
    use ElvenGard.ECS.Component, state: [map_id: 1, pos_x: 0, pos_y: 0]
  end

  ## Tests

  describe "spawn_entity/1" do
    test "spawn an Entity with default specs" do
      specs = Entity.entity_spec()

      assert {:ok, %Entity{} = entity} = Command.spawn_entity(specs)
      assert specs.id == entity.id

      assert {:error, :already_spawned} = Command.spawn_entity(specs)
    end

    test "spawn an Entity with parent spec" do
      {:ok, parent} = Command.spawn_entity(Entity.entity_spec())
      specs = Entity.entity_spec(parent: parent)

      assert {:ok, %Entity{} = entity} = Command.spawn_entity(specs)
      assert {:ok, ^parent} = Query.parent(entity)
    end

    test "spawn an Entity with children spec" do
      {:ok, child1} = Command.spawn_entity(Entity.entity_spec())
      {:ok, child2} = Command.spawn_entity(Entity.entity_spec())
      specs = Entity.entity_spec(children: [child1, child2])

      assert {:ok, %Entity{} = entity} = Command.spawn_entity(specs)
      assert {:ok, children} = Query.children(entity)
      assert length(children) == 2
      assert child1 in children
      assert child2 in children
    end

    test "spawn an Entity with components spec" do
      specs =
        Entity.entity_spec(
          components: [
            PlayerComponent,
            {PositionComponent, [map_id: 42]}
          ]
        )

      assert {:ok, %Entity{} = entity} = Command.spawn_entity(specs)
      assert {:ok, [player_component, position_component]} = Query.components(entity)
      assert %PlayerComponent{name: "Player"} = player_component
      assert %PositionComponent{map_id: 42, pos_x: 0, pos_y: 0} = position_component
    end
  end
end
