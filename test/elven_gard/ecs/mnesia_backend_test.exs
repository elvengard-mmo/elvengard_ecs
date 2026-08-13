defmodule ElvenGard.ECS.MnesiaBackendTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Component, Entity, MnesiaBackend, Query}
  alias ElvenGard.ECS.Components.PositionComponent

  test "initializes existing tables synchronously without keeping a process alive" do
    assert :ignore = MnesiaBackend.start_link([])
    assert :ok = :mnesia.wait_for_tables([Entity, Component], 0)
  end

  test "reuses an active transaction and preserves its rollback boundary" do
    entity_id = make_ref()

    assert {:error, :nested_abort} =
             MnesiaBackend.transaction(fn ->
               assert {:ok, %Entity{id: ^entity_id}} =
                        MnesiaBackend.create_entity(entity_id, nil, :default)

               MnesiaBackend.transaction(fn -> MnesiaBackend.abort(:nested_abort) end)
             end)

    assert {:error, :not_found} = MnesiaBackend.fetch_entity(entity_id)
  end

  test "partitioned queries avoid global component table scans" do
    partition = make_ref()
    {:ok, entity} = MnesiaBackend.create_entity(make_ref(), nil, partition)
    {:ok, position} = MnesiaBackend.add_component(entity, PositionComponent)

    test_pid = self()

    tracer =
      spawn_link(fn ->
        receive do
          message -> send(test_pid, {:ecs_trace, message})
        after
          100 -> :ok
        end
      end)

    :erlang.trace_pattern({MnesiaBackend, :select_components_by_type, 1}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    on_exit(fn ->
      :erlang.trace(self(), false, [:call])

      :erlang.trace_pattern(
        {MnesiaBackend, :select_components_by_type, 1},
        false,
        [:local]
      )
    end)

    query = Query.select(PositionComponent, partition: partition)

    assert Query.all(query) == [position]

    refute_receive {:ecs_trace,
                    {:trace, _pid, :call, {MnesiaBackend, :select_components_by_type, _arguments}}},
                   150
  end

  test "creates an entity only once under concurrent calls" do
    id = make_ref()
    caller = self()
    task_count = 20

    tasks =
      for _index <- 1..task_count do
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :create -> MnesiaBackend.create_entity(id, nil, :default)
          end
        end)
      end

    Enum.each(tasks, fn _task -> assert_receive {:ready, _pid} end)
    Enum.each(tasks, fn task -> send(task.pid, :create) end)

    results = Task.await_many(tasks)

    assert 1 == Enum.count(results, &match?({:ok, %Entity{id: ^id}}, &1))
    assert task_count - 1 == Enum.count(results, &(&1 == {:error, :already_exists}))
  end

  test "rejects direct and indirect parent cycles" do
    {:ok, root} = MnesiaBackend.create_entity(make_ref(), nil, :default)
    {:ok, child} = MnesiaBackend.create_entity(make_ref(), root, :default)
    {:ok, grandchild} = MnesiaBackend.create_entity(make_ref(), child, :default)

    assert {:error, :cyclic_relationship} = MnesiaBackend.set_parent(root, root)
    assert {:error, :cyclic_relationship} = MnesiaBackend.set_parent(root, grandchild)
    assert {:ok, nil} = MnesiaBackend.parent(root)
  end

  test "rejects a creation that closes a parent cycle" do
    first_id = make_ref()
    second_id = make_ref()
    second = %Entity{id: second_id}

    assert {:ok, first} = MnesiaBackend.create_entity(first_id, second, :default)

    assert {:error, :cyclic_relationship} =
             MnesiaBackend.create_entity(second_id, first, :default)

    assert {:error, :not_found} = MnesiaBackend.fetch_entity(second_id)
  end

  test "allows only one of two concurrent creations that would form a cycle" do
    caller = self()
    first_id = make_ref()
    second_id = make_ref()

    tasks = [
      Task.async(fn ->
        send(caller, {:ready, self()})

        receive do
          :create ->
            MnesiaBackend.create_entity(first_id, %Entity{id: second_id}, :default)
        end
      end),
      Task.async(fn ->
        send(caller, {:ready, self()})

        receive do
          :create ->
            MnesiaBackend.create_entity(second_id, %Entity{id: first_id}, :default)
        end
      end)
    ]

    Enum.each(tasks, fn _task -> assert_receive({:ready, _pid}) end)
    Enum.each(tasks, fn task -> send(task.pid, :create) end)

    results = Task.await_many(tasks)

    assert 1 == Enum.count(results, &match?({:ok, %Entity{}}, &1))
    assert 1 == Enum.count(results, &(&1 == {:error, :cyclic_relationship}))
  end

  test "updates the parent and partition without losing concurrent changes" do
    caller = self()
    partition = make_ref()
    {:ok, parent} = MnesiaBackend.create_entity(make_ref(), nil, :default)
    {:ok, entity} = MnesiaBackend.create_entity(make_ref(), nil, :default)

    lock_task =
      Task.async(fn ->
        :mnesia.transaction(fn ->
          [_record] = :mnesia.wread({Entity, entity.id})
          send(caller, :entity_locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive(:entity_locked)

    parent_task =
      Task.async(fn ->
        send(caller, {:update_started, self()})
        MnesiaBackend.set_parent(entity, parent)
      end)

    partition_task =
      Task.async(fn ->
        send(caller, {:update_started, self()})
        MnesiaBackend.set_partition(entity, partition)
      end)

    parent_pid = parent_task.pid
    partition_pid = partition_task.pid

    assert_receive({:update_started, ^parent_pid})
    assert_receive({:update_started, ^partition_pid})
    refute Task.yield(parent_task, 50)
    refute Task.yield(partition_task, 50)

    send(lock_task.pid, :release)

    assert {:atomic, :ok} = Task.await(lock_task)
    assert [:ok, :ok] = Task.await_many([parent_task, partition_task])
    assert {:ok, ^parent} = MnesiaBackend.parent(entity)
    assert {:ok, ^partition} = MnesiaBackend.partition(entity)
  end

  test "updates a component without losing concurrent changes" do
    caller = self()
    {:ok, entity} = MnesiaBackend.create_entity(make_ref(), nil, :default)
    {:ok, %PositionComponent{}} = MnesiaBackend.add_component(entity, PositionComponent)
    key = {Component, {entity.id, PositionComponent}}

    lock_task =
      Task.async(fn ->
        :mnesia.transaction(fn ->
          [_record] = :mnesia.wread(key)
          send(caller, :component_locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive(:component_locked)

    update_tasks = [
      Task.async(fn ->
        send(caller, {:update_started, self()})
        MnesiaBackend.update_component(entity, PositionComponent, pos_x: 1)
      end),
      Task.async(fn ->
        send(caller, {:update_started, self()})
        MnesiaBackend.update_component(entity, PositionComponent, pos_y: 2)
      end)
    ]

    update_pids = Enum.map(update_tasks, & &1.pid)

    Enum.each(update_tasks, fn _task ->
      assert_receive({:update_started, pid})
      assert pid in update_pids
    end)

    Enum.each(update_tasks, fn task -> refute Task.yield(task, 50) end)

    send(lock_task.pid, :release)

    assert {:atomic, :ok} = Task.await(lock_task)
    assert Enum.all?(Task.await_many(update_tasks), &match?({:ok, %PositionComponent{}}, &1))

    assert {:ok, [%PositionComponent{pos_x: 1, pos_y: 2}]} =
             MnesiaBackend.fetch_components(entity, PositionComponent)
  end
end
