defmodule ElvenGard.ECS.CommandTest do
  use ElvenGard.ECS.EntityCase, async: true

  alias ElvenGard.ECS.{Command, Entity, Query}
  alias ElvenGard.ECS.Components.{BuffComponent, PlayerComponent, PositionComponent}

  ## Tests

  describe "spawn_entity/1" do
    test "spawn an Entity with default specs" do
      specs = Entity.entity_spec()

      assert {:ok, %Entity{} = entity} = Command.spawn_entity(specs)
      assert specs.id == entity.id

      assert {:error, :already_exists} = Command.spawn_entity(specs)
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

  describe "set_parent/2" do
    test "set the parent for an Entity" do
      entity_parent = spawn_entity()

      entity = spawn_entity()
      {:ok, parent} = Query.parent(entity)
      assert is_nil(parent)

      assert :ok = Command.set_parent(entity, entity_parent)
      {:ok, parent} = Query.parent(entity)
      assert parent == entity_parent

      assert :ok = Command.set_parent(entity, nil)
      {:ok, parent} = Query.parent(entity)
      assert is_nil(parent)
    end
  end

  describe "add_component/2" do
    test "add a Component to an Entity" do
      entity = spawn_entity()
      assert {:ok, []} = Query.components(entity)

      # Add a first Component
      assert %PlayerComponent{name: "Player"} = Command.add_component(entity, PlayerComponent)
      {:ok, components} = Query.components(entity)
      assert length(components) == 1
      assert %PlayerComponent{name: "Player"} in components

      # Add a second Component
      assert %BuffComponent{buff_id: 42} =
               Command.add_component(entity, {BuffComponent, [buff_id: 42]})

      {:ok, components} = Query.components(entity)
      assert length(components) == 2
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components

      # Add the same Component
      assert %BuffComponent{buff_id: 1337} =
               Command.add_component(entity, {BuffComponent, [buff_id: 1337]})

      {:ok, components} = Query.components(entity)
      assert length(components) == 3
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components
      assert %BuffComponent{buff_id: 1337} in components

      # Add the same buff: Mnesia doesn't support duplicate_bag
      assert %BuffComponent{buff_id: 1337} =
               Command.add_component(entity, {BuffComponent, [buff_id: 1337]})

      {:ok, components} = Query.components(entity)
      assert length(components) == 3
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components
      assert %BuffComponent{buff_id: 1337} in components
    end
  end
end
