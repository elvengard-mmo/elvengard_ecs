defmodule ElvenGard.ECS.CommandTest do
  use ElvenGard.ECS.EntityCase, async: true

  alias ElvenGard.ECS.{Command, Entity, Query}
  alias ElvenGard.ECS.Components.{BuffComponent, PlayerComponent, PositionComponent}

  ## Tests

  describe "spawn_entity/1" do
    test "spawn an Entity with default specs" do
      specs = Entity.entity_spec()

      assert {:ok, {entity, components}} = Command.spawn_entity(specs)
      assert %Entity{} = entity
      assert specs.id == entity.id
      assert components == []

      assert {:error, :already_exists} = Command.spawn_entity(specs)
    end

    test "spawn an Entity with parent spec" do
      {:ok, {parent, []}} = Command.spawn_entity(Entity.entity_spec())
      specs = Entity.entity_spec(parent: parent)

      assert {:ok, {entity, []}} = Command.spawn_entity(specs)
      assert {:ok, ^parent} = Query.parent(entity)
    end

    test "spawn an Entity with children spec" do
      {:ok, {child1, []}} = Command.spawn_entity(Entity.entity_spec())
      {:ok, {child2, []}} = Command.spawn_entity(Entity.entity_spec())
      specs = Entity.entity_spec(children: [child1, child2])

      assert {:ok, {entity, []}} = Command.spawn_entity(specs)
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

      assert {:ok, {entity, components}} = Command.spawn_entity(specs)
      assert length(components) == 2
      assert %PlayerComponent{} in components
      assert %PositionComponent{map_id: 42} in components

      assert {:ok, [player_component, position_component]} = Query.list_components(entity)
      assert %PlayerComponent{name: "Player"} = player_component
      assert %PositionComponent{map_id: 42, pos_x: 0, pos_y: 0} = position_component
    end

    test "spawn an Entity with partition spec" do
      partition = make_ref()
      specs = Entity.entity_spec(partition: partition)

      {:ok, {_outside_entity, []}} = Command.spawn_entity(Entity.entity_spec())
      assert {:ok, entity} = Command.spawn_entity(specs)

      assert [^entity] =
               Query.select(Entity, partition: partition)
               |> Query.all()
    end
  end

  describe "despawn_entity/2" do
    test "despawn an Entity" do
      # Spawn a dummy Entity
      entity = spawn_entity(Entity.entity_spec())

      # Despawn it
      assert {:ok, {^entity, components}} = Command.despawn_entity(entity)
      assert components == []
      assert {:error, :not_found} = Query.fetch_entity(entity.id)
    end

    test "with components" do
      # Spawn a dummy Entity
      specs =
        Entity.entity_spec(
          components: [
            PlayerComponent,
            {PositionComponent, [map_id: 42]}
          ]
        )

      entity = spawn_entity(Entity.entity_spec(specs))

      # Despawn it
      assert {:ok, {^entity, components}} = Command.despawn_entity(entity)
      assert %PlayerComponent{name: "Player"} in components
      assert %PositionComponent{map_id: 42, pos_x: 0, pos_y: 0} in components
      assert {:error, :not_found} = Query.fetch_entity(entity.id)
    end

    test "with children on delete (default behaviour)" do
      # Spawn dummy Entities
      parent = spawn_entity(Entity.entity_spec())
      entity1 = spawn_entity(Entity.entity_spec(parent: parent))
      entity2 = spawn_entity(Entity.entity_spec(parent: parent))

      # Despawn the parent
      assert {:ok, {^parent, []}} = Command.despawn_entity(parent)
      assert {:error, :not_found} = Query.fetch_entity(parent.id)
      assert {:error, :not_found} = Query.fetch_entity(entity1.id)
      assert {:error, :not_found} = Query.fetch_entity(entity2.id)
    end

    test "with children on delete callback" do
      # Spawn dummy Entities
      parent_comp = [PlayerComponent, {PositionComponent, [map_id: 42]}]
      c1_comp = [{PositionComponent, [map_id: 42]}]
      c2_comp = [{BuffComponent, [buff_id: 1337]}]

      parent = spawn_entity(Entity.entity_spec(components: parent_comp))
      child1 = spawn_entity(Entity.entity_spec(parent: parent, components: c1_comp))
      child2 = spawn_entity(Entity.entity_spec(parent: parent, components: c2_comp))

      # Despawn the parent
      fun = fn entity, components ->
        send(self(), {:despawn, entity, components})
        :delete
      end

      assert {:ok, {^parent, [_, _]}} = Command.despawn_entity(parent, fun)
      assert {:error, :not_found} = Query.fetch_entity(parent.id)
      assert {:error, :not_found} = Query.fetch_entity(child1.id)
      assert {:error, :not_found} = Query.fetch_entity(child2.id)

      assert_received {:despawn, ^child1, [%PositionComponent{map_id: 42, pos_x: 0, pos_y: 0}]}
      assert_received {:despawn, ^child2, [%BuffComponent{buff_id: 1337}]}
    end

    test "with children on delete cascade" do
      # Spawn dummy Entities
      entity1 = spawn_entity(Entity.entity_spec())
      entity2 = spawn_entity(Entity.entity_spec(parent: entity1))
      entity3 = spawn_entity(Entity.entity_spec(parent: entity2))

      # Despawn entity1 and delete entity2 and entity3 on cascade
      fun = fn entity, components ->
        send(self(), {:despawn, entity, components})
        :delete
      end

      assert {:ok, {^entity1, []}} = Command.despawn_entity(entity1, fun)
      assert {:error, :not_found} = Query.fetch_entity(entity1.id)
      assert {:error, :not_found} = Query.fetch_entity(entity2.id)
      assert {:error, :not_found} = Query.fetch_entity(entity3.id)

      assert_received {:despawn, ^entity2, []}
      assert_received {:despawn, ^entity3, []}
    end

    test "with children on ignore callback" do
      # Spawn dummy Entities
      ref = make_ref()
      entity1 = spawn_entity(Entity.entity_spec())
      entity2 = spawn_entity(Entity.entity_spec(id: ref, parent: entity1))
      entity3 = spawn_entity(Entity.entity_spec(parent: entity2))

      # Despawn entity1 but keep entity2 and entity3
      fun = fn entity, components ->
        send(self(), {:despawn, entity, components})

        # Keep only entity3
        if entity.id == ref, do: :ignore, else: :delete
      end

      assert {:ok, {^entity1, []}} = Command.despawn_entity(entity1, fun)
      assert {:error, :not_found} = Query.fetch_entity(entity1.id)
      assert {:ok, ^entity2} = Query.fetch_entity(entity2.id)
      assert {:ok, ^entity3} = Query.fetch_entity(entity3.id)

      assert_received {:despawn, ^entity2, []}
      refute_received {:despawn, ^entity3, []}
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

    test "returns a not found error if entity doesn't exists" do
      assert {:error, :not_found} = Command.set_parent(invalid_entity(), make_ref())
    end
  end

  describe "set_partition/2" do
    test "set the partition for an Entity" do
      entity = spawn_entity()
      partition = make_ref()

      assert :ok = Command.set_partition(entity, partition)
      assert Query.partition(entity) == {:ok, partition}
    end

    test "returns a not found error if entity doesn't exists" do
      assert {:error, :not_found} = Command.set_partition(invalid_entity(), make_ref())
    end
  end

  describe "add_component/2" do
    test "add a Component specs to an Entity" do
      entity = spawn_entity()
      assert {:ok, []} = Query.list_components(entity)

      # Add a first Component
      {:ok, component} = Command.add_component(entity, PlayerComponent)
      assert %PlayerComponent{name: "Player"} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 1
      assert %PlayerComponent{name: "Player"} in components

      # Add a second Component
      {:ok, component} = Command.add_component(entity, {BuffComponent, [buff_id: 42]})
      assert %BuffComponent{buff_id: 42} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 2
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components

      # Add the same Component
      {:ok, component} = Command.add_component(entity, {BuffComponent, [buff_id: 1337]})
      assert %BuffComponent{buff_id: 1337} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 3
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components
      assert %BuffComponent{buff_id: 1337} in components

      # Add the same buff: Mnesia doesn't support duplicate_bag
      {:ok, component} = Command.add_component(entity, {BuffComponent, [buff_id: 1337]})
      assert %BuffComponent{buff_id: 1337} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 3
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components
      assert %BuffComponent{buff_id: 1337} in components
    end

    test "add a Component structure to an Entity" do
      entity = spawn_entity()
      assert {:ok, []} = Query.list_components(entity)

      # Add a first Component
      {:ok, component} = Command.add_component(entity, %PlayerComponent{})
      assert %PlayerComponent{name: "Player"} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 1
      assert %PlayerComponent{name: "Player"} in components

      # Add a second Component
      {:ok, component} = Command.add_component(entity, %BuffComponent{buff_id: 42})
      assert %BuffComponent{buff_id: 42} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 2
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components

      # Add the same Component
      {:ok, component} = Command.add_component(entity, %BuffComponent{buff_id: 1337})
      assert %BuffComponent{buff_id: 1337} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 3
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components
      assert %BuffComponent{buff_id: 1337} in components

      # Add the same buff: Mnesia doesn't support duplicate_bag
      {:ok, component} = Command.add_component(entity, %BuffComponent{buff_id: 1337})
      assert %BuffComponent{buff_id: 1337} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 3
      assert %PlayerComponent{name: "Player"} in components
      assert %BuffComponent{buff_id: 42} in components
      assert %BuffComponent{buff_id: 1337} in components
    end
  end

  describe "delete_component/2" do
    test "by type" do
      components = [PlayerComponent, {BuffComponent, buff_id: 12}, {BuffComponent, buff_id: 34}]
      entity = spawn_entity(components: components)
      {:ok, [_, _, _]} = Query.list_components(entity)

      assert :ok = Command.delete_component(entity, PlayerComponent)
      {:ok, components} = Query.list_components(entity)
      assert length(components) == 2
      refute %PlayerComponent{} in components

      assert :ok = Command.delete_component(entity, BuffComponent)
      assert {:ok, []} = Query.list_components(entity)
    end

    test "by structure" do
      components = [PlayerComponent, {BuffComponent, buff_id: 12}, {BuffComponent, buff_id: 34}]
      entity = spawn_entity(components: components)
      {:ok, [_, _, _]} = Query.list_components(entity)

      assert :ok = Command.delete_component(entity, %PlayerComponent{})
      {:ok, components} = Query.list_components(entity)
      assert length(components) == 2
      refute %PlayerComponent{} in components

      assert :ok = Command.delete_component(entity, %BuffComponent{buff_id: 12})
      assert {:ok, [%BuffComponent{buff_id: 34}]} = Query.list_components(entity)

      assert :ok = Command.delete_component(entity, %BuffComponent{buff_id: 34})
      assert {:ok, []} = Query.list_components(entity)
    end
  end

  describe "replace_component/2" do
    test "for a single component" do
      entity = spawn_entity(components: [PlayerComponent])
      {:ok, [%PlayerComponent{name: "Player"}]} = Query.list_components(entity)

      assert :ok = Command.replace_component(entity, %PlayerComponent{name: "ImNotAPlayer"})
      {:ok, [component]} = Query.list_components(entity)
      assert %PlayerComponent{name: "ImNotAPlayer"} = component
    end

    test "override multiple components" do
      components = [{BuffComponent, buff_id: 12}, {BuffComponent, buff_id: 34}]
      entity = spawn_entity(components: components)
      {:ok, [_, _]} = Query.list_components(entity)

      assert :ok = Command.replace_component(entity, %BuffComponent{buff_id: 1337})
      {:ok, components} = Query.list_components(entity)
      assert [%BuffComponent{buff_id: 1337}] = components
    end
  end

  describe "update_component/3" do
    test "can update a component by type" do
      components = [PlayerComponent]
      entity = spawn_entity(components: components)
      {:ok, [%PlayerComponent{}]} = Query.list_components(entity)

      assert {:ok, component} =
               Command.update_component(entity, PlayerComponent, name: "TestPlayer")

      assert %PlayerComponent{name: "TestPlayer"} = component
      assert {:ok, [%PlayerComponent{name: "TestPlayer"}]} = Query.list_components(entity)
    end

    test "can update a component by structure" do
      components = [{BuffComponent, buff_id: 12}, {BuffComponent, buff_id: 34}]
      entity = spawn_entity(components: components)
      {:ok, [_, _]} = Query.list_components(entity)

      assert {:ok, component} =
               Command.update_component(entity, %BuffComponent{buff_id: 12}, buff_id: 1337)

      assert %BuffComponent{buff_id: 1337} = component

      {:ok, components} = Query.list_components(entity)
      assert length(components) == 2
      assert %BuffComponent{buff_id: 34} in components
      assert %BuffComponent{buff_id: 1337} in components
    end

    test "returns an error if no component found" do
      entity = spawn_entity(components: [{BuffComponent, buff_id: 1}])

      assert {:error, :not_found} = Command.update_component(entity, PlayerComponent, name: "")

      assert {:error, :not_found} =
               Command.update_component(entity, %BuffComponent{buff_id: 2}, buff_id: 9)
    end

    test "returns an error if multiple components found" do
      components = [{BuffComponent, buff_id: 1}, {BuffComponent, buff_id: 2}]
      entity = spawn_entity(components: components)

      assert {:error, :multiple_values} =
               Command.update_component(entity, BuffComponent, buff_id: 123)
    end
  end
end
