defmodule ElvenGard.ECS.Topology.PartitionTest do
  use ExUnit.Case, async: true

  # alias ElvenGard.ECS.Topology.EventSource
  alias ElvenGard.ECS.Topology.Partition

  ## Setup

  setup do
    name = :"Elixir.EventSource#{Enum.random(1..1_000_000)}"

    source =
      start_supervised!(
        {ElvenGard.ECS.Topology.EventSource, [name: name]},
        id: name
      )

    %{source: source}
  end

  ## Test modules

  defmodule TestPartition do
    use ElvenGard.ECS.Topology.Partition

    @impl true
    def setup(opts) do
      args = [
        event_source: Keyword.fetch!(opts, :event_source),
        systems: Keyword.get(opts, :systems, []),
        interval: Keyword.get(opts, :interval, 1),
        concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())
      ]

      {Keyword.get(opts, :id, :default), args}
    end
  end

  defmodule Test1Event do
    use ElvenGard.ECS.Event, fields: [:id]
  end

  defmodule Test2Event do
    use ElvenGard.ECS.Event, fields: [:id, :foo]
  end

  defmodule WithoutEventsSystem do
    use ElvenGard.ECS.System, lock_components: []

    @impl true
    def run(%{partition: partition, delta: delta}) do
      IO.puts("[WithoutEventsSystem] partition: #{partition} - delta: #{delta}")
    end
  end

  defmodule WithEventsSystem do
    use ElvenGard.ECS.System,
      lock_components: [],
      event_subscriptions: [Test1Event, Test2Event]

    @impl true
    def run(event, %{partition: partition, delta: delta}) do
      IO.puts(
        "[WithEventsSystem] partition: #{partition} - delta: #{delta} - event: #{inspect(event)}"
      )
    end
  end

  defmodule UnlockedBlockingSystem do
    use ElvenGard.ECS.System, lock_components: []

    @impl true
    def run(%{partition: test_pid, delta: delta}) do
      send(test_pid, {:system_started, :unlocked, self(), delta})

      receive do
        :finish -> :ok
      end
    end
  end

  defmodule SyncSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    @impl true
    def run(%{partition: test_pid, delta: delta}) do
      send(test_pid, {:system_started, :sync, delta})
    end
  end

  defmodule EventRecordingSystem do
    use ElvenGard.ECS.System,
      lock_components: [],
      event_subscriptions: [Test1Event]

    @impl true
    def run(%Test1Event{id: id}, %{partition: test_pid}) do
      send(test_pid, {:event_processed, id})
    end
  end

  ## Tests

  describe "expand_with_events/2" do
    test "without event subscription" do
      assert [WithoutEventsSystem] = Partition.expand_with_events(WithoutEventsSystem, [])
    end

    test "with events subscription" do
      assert [] = Partition.expand_with_events(WithEventsSystem, [])

      events = [%Test1Event{}]
      expanded = Partition.expand_with_events(WithEventsSystem, events)
      assert length(expanded) == 1
      assert {WithEventsSystem, %Test1Event{}} = Enum.at(expanded, 0)

      events = [
        %Test2Event{id: 1},
        %Test1Event{id: 2},
        %Test2Event{id: 3},
        %Test2Event{id: 4}
      ]

      expanded = Partition.expand_with_events(WithEventsSystem, events)
      assert length(expanded) == 4
      assert {WithEventsSystem, %Test2Event{id: 1}} = Enum.at(expanded, 0)
      assert {WithEventsSystem, %Test1Event{id: 2}} = Enum.at(expanded, 1)
      assert {WithEventsSystem, %Test2Event{id: 3}} = Enum.at(expanded, 2)
      assert {WithEventsSystem, %Test2Event{id: 4}} = Enum.at(expanded, 3)
    end
  end

  test "runs a sync system in an isolated batch", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [UnlockedBlockingSystem, SyncSystem],
         interval: 60_000,
         concurrency: 2}
      )

    assert Partition.started?(partition)
    send(partition, :tick)

    assert_receive {:system_started, :unlocked, task, delta}
    refute_receive {:system_started, :sync, _delta}, 100

    send(task, :finish)
    assert_receive {:system_started, :sync, ^delta}
    assert delta >= 0
  end

  test "preserves event order across batches", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [EventRecordingSystem],
         interval: 60_000,
         concurrency: 1}
      )

    assert Partition.started?(partition)

    GenServer.cast(partition, {:events, [%Test1Event{id: 1}, %Test1Event{id: 2}]})
    GenServer.cast(partition, {:events, [%Test1Event{id: 3}, %Test1Event{id: 4}]})
    send(partition, :tick)

    assert_receive {:event_processed, 1}
    assert_receive {:event_processed, 2}
    assert_receive {:event_processed, 3}
    assert_receive {:event_processed, 4}
  end

  # test "aa", %{source: source} do
  #   systems = [WithoutEventsSystem, WithEventsSystem, WithoutEventsSystem]
  #   start_supervised!({TestPartition, id: :default, event_source: source, systems: systems})

  #   Process.sleep(1001)

  #   events = [
  #     {%Test2Event{id: 1}, :default},
  #     {%Test1Event{id: 2}, :default},
  #     {%Test2Event{id: 3}, :default},
  #     {%Test2Event{id: 4}, :default}
  #   ]

  #   ElvenGard.ECS.Topology.EventSource.dispatch(source, events)

  #   Process.sleep(2000)
  # end
end
