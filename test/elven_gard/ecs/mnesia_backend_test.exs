defmodule ElvenGard.ECS.MnesiaBackendTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Component, Entity, MnesiaBackend}

  test "initializes existing tables synchronously without keeping a process alive" do
    assert :ignore = MnesiaBackend.start_link([])
    assert :ok = :mnesia.wait_for_tables([Entity, Component], 0)
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
end
