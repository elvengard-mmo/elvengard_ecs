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
end
