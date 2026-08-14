defmodule ElvenGard.ECS.MultiTest do
  use ElvenGard.ECS.EntityCase, async: true

  alias ElvenGard.ECS.{ChangeSet, Command, Entity, Multi, Query}
  alias ElvenGard.ECS.Components.{BuffComponent, PositionComponent}

  ## Building multis

  test "keeps named operations ordered and rejects duplicate names" do
    run = fn %{seed: seed} -> {:ok, seed + 1} end

    multi =
      Multi.new()
      |> Multi.put(:seed, 41)
      |> Multi.run(:answer, run)

    assert [{:seed, {:put, 41}}, {:answer, {:run, ^run}}] = Multi.to_list(multi)

    assert_raise ArgumentError, ~r/:seed is already a member/, fn ->
      Multi.put(multi, :seed, 42)
    end
  end

  test "appends and prepends multis while preserving order" do
    left = Multi.new() |> Multi.put(:left, 1)
    right = Multi.new() |> Multi.put(:right, 2)

    assert [:left, :right] = left |> Multi.append(right) |> Multi.to_list() |> Keyword.keys()
    assert [:right, :left] = left |> Multi.prepend(right) |> Multi.to_list() |> Keyword.keys()

    duplicate = Multi.new() |> Multi.put(:left, 2)

    assert_raise ArgumentError, ~r/both declared operations/, fn ->
      Multi.append(left, duplicate)
    end
  end

  ## Transactions

  test "emits bounded multi telemetry with numeric measurements" do
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elvengard_ecs, :multi, :stop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    multi =
      Multi.new()
      |> Multi.put(:one, 1)
      |> Multi.put(:two, 2)
      |> Multi.merge(fn _changes -> Multi.new() |> Multi.put(:three, 3) end)

    assert {:ok, %{one: 1, two: 2, three: 3}, changes} =
             Command.transact_with_changes(multi)

    assert ChangeSet.empty?(changes)

    assert_receive {:telemetry, %{duration: duration, operation_count: 3, change_count: 0},
                    metadata}

    assert duration >= 0
    assert metadata.backend == ElvenGard.ECS.MnesiaBackend
    assert metadata.outcome == :ok
    assert metadata.tracks_changes
    refute Map.has_key?(metadata, :multi)
    refute Map.has_key?(metadata, :changes)
  end

  test "reports failed multi outcomes without failure payloads" do
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elvengard_ecs, :multi, :stop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    multi = Multi.new() |> Multi.put(:seed, 1) |> Multi.error(:validation, :private_reason)

    assert Command.transact(multi) ==
             {:error, :validation, :private_reason, %{seed: 1}}

    assert_receive {:telemetry, %{duration: duration, operation_count: 2, change_count: 0},
                    metadata}

    assert duration >= 0
    assert metadata.outcome == :error
    refute Map.has_key?(metadata, :reason)
    refute Map.has_key?(metadata, :failed_operation)
  end

  test "executes dependent entity and component commands atomically" do
    partition = make_ref()
    entity_id = {:multi_entity, make_ref()}

    spec =
      Entity.entity_spec(
        id: entity_id,
        partition: partition,
        components: [PositionComponent]
      )

    multi =
      Multi.new()
      |> Multi.spawn_entity(:spawn, spec)
      |> Multi.add_component(
        :buff,
        fn %{spawn: {entity, _components}} -> entity end,
        {BuffComponent, buff_id: 42}
      )
      |> Multi.update_component(
        :position,
        fn %{spawn: {entity, _components}} -> entity end,
        PositionComponent,
        pos_x: 12
      )

    assert {:ok,
            %{
              spawn: {%Entity{id: ^entity_id} = entity, [%PositionComponent{}]},
              buff: %BuffComponent{buff_id: 42},
              position: %PositionComponent{pos_x: 12}
            }} = Command.transact(multi)

    assert {:ok, %PositionComponent{pos_x: 12}} = Query.fetch_component(entity, PositionComponent)
    assert {:ok, [%BuffComponent{buff_id: 42}]} = Query.fetch_components(entity, BuffComponent)
  end

  test "rolls every command back and reports the failed operation" do
    entity_id = {:rolled_back_entity, make_ref()}
    spec = Entity.entity_spec(id: entity_id, components: [PositionComponent])

    multi =
      Multi.new()
      |> Multi.spawn_entity(:spawn, spec)
      |> Multi.error(:validation, :invalid_position)

    assert {:error, :validation, :invalid_position, %{spawn: {%Entity{id: ^entity_id}, _}}} =
             Command.transact(multi)

    assert Query.fetch_entity(entity_id) == {:error, :not_found}
  end

  test "supports relationship, replacement and deletion commands" do
    parent = spawn_entity()
    entity = spawn_entity(components: [PositionComponent])
    partition = make_ref()
    replacement = %PositionComponent{map_id: 7, pos_x: 3, pos_y: 4}

    multi =
      Multi.new()
      |> Multi.set_parent(:parent, entity, parent)
      |> Multi.set_partition(:partition, entity, partition)
      |> Multi.replace_component(:replacement, entity, replacement)
      |> Multi.delete_component(:deletion, entity, PositionComponent)

    assert {:ok,
            %{
              parent: ^parent,
              partition: ^partition,
              replacement: ^replacement,
              deletion: PositionComponent
            }} = Command.transact(multi)

    assert Query.parent(entity) == {:ok, parent}
    assert Query.partition(entity) == {:ok, partition}
    assert Query.fetch_component(entity, PositionComponent) == {:error, :not_found}
  end

  test "despawns from preloaded components and tracks the entity mutation" do
    entity = spawn_entity(components: [PositionComponent])
    {:ok, components} = Query.list_components(entity)

    multi =
      Multi.new()
      |> Multi.despawn_preloaded_entity(:despawn, entity, components)

    assert {:ok, %{despawn: {^entity, ^components}}, changes} =
             Command.transact_with_changes(multi)

    assert ChangeSet.to_list(changes) == [
             {:despawn, {:despawn_entity, entity, components}}
           ]

    assert Query.fetch_entity(entity.id) == {:error, :not_found}
  end

  test "merges dependent multis dynamically" do
    entity = spawn_entity()

    multi =
      Multi.new()
      |> Multi.put(:entity, entity)
      |> Multi.merge(fn %{entity: selected_entity} ->
        Multi.new()
        |> Multi.add_component(:position, selected_entity, {PositionComponent, pos_x: 9})
      end)
      |> Multi.run(:loaded, fn %{entity: selected_entity} ->
        Query.fetch_component(selected_entity, PositionComponent)
      end)

    assert {:ok,
            %{
              entity: ^entity,
              position: %PositionComponent{pos_x: 9},
              loaded: %PositionComponent{pos_x: 9}
            }} = Command.transact(multi)
  end

  test "returns a bounded changeset only for the current multi" do
    first_entity = spawn_entity()
    second_entity = spawn_entity()

    first_multi =
      Multi.new()
      |> Multi.add_component(:position, first_entity, {PositionComponent, pos_x: 4})
      |> Multi.set_partition(:partition, first_entity, :arena)

    assert {:ok, first_results, first_changes} = Command.transact_with_changes(first_multi)
    assert first_results.position == %PositionComponent{pos_x: 4}
    refute ChangeSet.empty?(first_changes)

    assert ChangeSet.to_list(first_changes) == [
             {:position, {:add_component, first_entity, %PositionComponent{pos_x: 4}}},
             {:partition, {:set_partition, first_entity, :arena}}
           ]

    second_multi =
      Multi.new()
      |> Multi.add_component(:buff, second_entity, {BuffComponent, buff_id: 7})

    assert {:ok, _second_results, second_changes} =
             Command.transact_with_changes(second_multi)

    assert ChangeSet.to_list(second_changes) == [
             {:buff, {:add_component, second_entity, %BuffComponent{buff_id: 7}}}
           ]

    assert length(ChangeSet.to_list(first_changes)) == 2
    assert ChangeSet.empty?(ChangeSet.new())
  end

  ## Telemetry callback

  @doc false
  def handle_telemetry(_event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, measurements, metadata})
  end
end
