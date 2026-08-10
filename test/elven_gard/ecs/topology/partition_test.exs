defmodule ElvenGard.ECS.Topology.PartitionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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
        pre_tick_systems: Keyword.get(opts, :pre_tick_systems, []),
        systems: Keyword.get(opts, :systems, []),
        post_tick_systems: Keyword.get(opts, :post_tick_systems, []),
        shutdown_systems: Keyword.get(opts, :shutdown_systems, []),
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

  defmodule FailOnceEventSystem do
    use ElvenGard.ECS.System,
      lock_components: [],
      event_subscriptions: [Test1Event]

    @impl true
    def run(%Test1Event{id: counter}, _context) do
      case :atomics.add_get(counter, 1, 1) do
        1 -> :ok
        2 -> raise "system failed"
      end
    end
  end

  defmodule ShutdownSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    @impl true
    def run(%{partition: test_pid, delta: :shutdown, reason: reason}) do
      send(test_pid, {:shutdown_system_run, __MODULE__, reason})
    end
  end

  defmodule FailingShutdownSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    @impl true
    def run(%{delta: :shutdown}) do
      raise "shutdown failed"
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

  test "runs pre-tick, tick and post-tick systems behind phase barriers", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         pre_tick_systems: [ElvenGard.ECS.PhaseRecordingSystem],
         systems: [ElvenGard.ECS.PhaseRecordingSystem],
         post_tick_systems: [ElvenGard.ECS.PhaseRecordingSystem],
         interval: 60_000,
         concurrency: 3}
      )

    assert Partition.started?(partition)
    send(partition, :tick)

    assert_receive {:phase_run, first_phase}
    assert_receive {:phase_run, second_phase}
    assert_receive {:phase_run, third_phase}
    assert [first_phase, second_phase, third_phase] == [:pre_tick, :tick, :post_tick]
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

  test "reports a failed duplicate system execution", %{source: source} do
    counter = :atomics.new(1, [])

    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [FailOnceEventSystem],
         interval: 60_000,
         concurrency: 2}
      )

    assert Partition.started?(partition)
    event = %Test1Event{id: counter}

    log =
      capture_log(fn ->
        GenServer.cast(partition, {:events, [event, event]})
        send(partition, :tick)
        assert Partition.started?(partition)
      end)

    assert log =~ "1 systems killed/crashed"
  end

  test "runs shutdown systems with the partition and stop reason", %{source: source} do
    child_id = make_ref()
    handler_id = make_ref()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:elvengard_ecs, :shutdown_system_run, :stop],
          [:elvengard_ecs, :partition_shutdown]
        ],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [],
         shutdown_systems: [ShutdownSystem],
         interval: 60_000},
        id: child_id
      )

    assert Partition.started?(partition)
    assert :ok = stop_supervised(child_id)
    assert_receive {:shutdown_system_run, ShutdownSystem, :shutdown}

    assert_receive {:telemetry, [:elvengard_ecs, :shutdown_system_run, :stop],
                    %{duration: system_duration},
                    %{partition: test_pid, reason: :shutdown, system: ShutdownSystem}}

    assert test_pid == self()
    assert system_duration >= 0

    assert_receive {:telemetry, [:elvengard_ecs, :partition_shutdown],
                    %{duration: partition_duration},
                    %{
                      id: test_pid,
                      reason: :shutdown,
                      shutdown_systems: [ShutdownSystem]
                    }}

    assert test_pid == self()
    assert partition_duration >= 0
  end

  test "continues shutdown after one system fails and logs the failure", %{source: source} do
    child_id = make_ref()

    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [],
         shutdown_systems: [FailingShutdownSystem, ShutdownSystem],
         interval: 60_000},
        id: child_id
      )

    assert Partition.started?(partition)

    log =
      capture_log(fn ->
        assert :ok = stop_supervised(child_id)
        assert_receive {:shutdown_system_run, ShutdownSystem, :shutdown}
      end)

    assert log =~ "shutdown system failed"
    assert log =~ inspect(FailingShutdownSystem)
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

  ## Test helpers

  def handle_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end
end
