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
        tick_mode: Keyword.get(opts, :tick_mode, :continuous),
        initial_tick: Keyword.get(opts, :initial_tick, true),
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

  defmodule ChangeEmittingSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    alias ElvenGard.ECS.{ChangeSet, Entity, System}

    @impl true
    def run(%{partition: test_pid, phase: phase, change_sets: change_sets}) do
      names = Enum.flat_map(change_sets, &change_names/1)
      send(test_pid, {:visible_change_sets, phase, names})

      entity = %Entity{id: {:phase, phase}}

      ChangeSet.new()
      |> ChangeSet.add(phase, {:set_parent, entity, nil})
      |> System.emit_changes()
    end

    defp change_names(change_set) do
      Enum.map(ChangeSet.to_list(change_set), &elem(&1, 0))
    end
  end

  defmodule EventChangeEmittingSystem do
    use ElvenGard.ECS.System,
      lock_components: :sync,
      event_subscriptions: [Test1Event]

    alias ElvenGard.ECS.{ChangeSet, Entity, System}

    @impl true
    def run(%Test1Event{id: id}, %{partition: test_pid, change_sets: change_sets}) do
      send(test_pid, {:event_visible_change_set_count, length(change_sets)})
      entity = %Entity{id: {:event, id}}

      ChangeSet.new()
      |> ChangeSet.add({:event, id}, {:set_parent, entity, nil})
      |> System.emit_changes()
    end
  end

  defmodule ChangeObservingSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    alias ElvenGard.ECS.ChangeSet

    @impl true
    def run(%{partition: test_pid, phase: phase, change_sets: change_sets}) do
      names =
        Enum.flat_map(change_sets, fn change_set ->
          Enum.map(ChangeSet.to_list(change_set), &elem(&1, 0))
        end)

      send(test_pid, {:observed_change_sets, phase, names})
    end
  end

  defmodule OutputEmittingSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    alias ElvenGard.ECS.System

    @impl true
    def run(%{partition: test_pid, phase: phase, outputs: outputs}) do
      send(test_pid, {:visible_outputs, phase, outputs})
      System.emit_changes([], %{prepared_in: phase})
    end
  end

  defmodule OutputObservingSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    alias ElvenGard.ECS.System

    @impl true
    def run(%{partition: test_pid, phase: phase} = context) do
      send(test_pid, {:observed_output, phase, System.output(context, OutputEmittingSystem)})
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

  test "wakes an on-demand partition as soon as an event arrives", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [EventRecordingSystem],
         tick_mode: :on_demand,
         initial_tick: false}
      )

    assert Partition.started?(partition)
    GenServer.cast(partition, {:events, [%Test1Event{id: 41}]})

    assert_receive {:event_processed, 41}
  end

  test "sleeps an on-demand partition until a system deadline or explicit wake", %{source: source} do
    counter = :atomics.new(1, [])

    partition =
      start_supervised!(
        {TestPartition,
         id: {self(), counter},
         event_source: source,
         systems: [ElvenGard.ECS.OnDemandSchedulingSystem],
         tick_mode: :on_demand,
         initial_tick: false}
      )

    assert Partition.started?(partition)
    refute_receive {:on_demand_tick, _count}, 30

    assert :ok = Partition.wake(partition)
    assert_receive {:on_demand_tick, 1}
    assert_receive {:on_demand_tick, 2}
    refute_receive {:on_demand_tick, _count}, 30
  end

  test "runs a conditional system only after its condition becomes true", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         pre_tick_systems: [ChangeEmittingSystem],
         systems: [ElvenGard.ECS.ConditionalSystem],
         interval: 60_000}
      )

    assert Partition.started?(partition)
    send(partition, :tick)

    assert_receive {:conditional_system_ran, :tick}
  end

  test "skips a conditional system when its condition remains false", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         systems: [ElvenGard.ECS.ConditionalSystem],
         interval: 60_000}
      )

    assert Partition.started?(partition)
    send(partition, :tick)

    refute_receive {:conditional_system_ran, :tick}, 30
  end

  test "carries emitted change sets into later phases and drops them after the tick", %{
    source: source
  } do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         pre_tick_systems: [ChangeEmittingSystem],
         systems: [ChangeEmittingSystem],
         post_tick_systems: [ChangeEmittingSystem],
         interval: 60_000,
         concurrency: 3}
      )

    assert Partition.started?(partition)
    send(partition, :tick)

    assert_receive {:visible_change_sets, :pre_tick, []}
    assert_receive {:visible_change_sets, :tick, [:pre_tick]}
    assert_receive {:visible_change_sets, :post_tick, [:pre_tick, :tick]}

    send(partition, :tick)
    assert_receive {:visible_change_sets, :pre_tick, []}
  end

  test "carries outputs into later phases and drops them after the tick", %{source: source} do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         pre_tick_systems: [OutputEmittingSystem],
         systems: [OutputObservingSystem],
         post_tick_systems: [OutputObservingSystem],
         interval: 60_000,
         concurrency: 3}
      )

    assert Partition.started?(partition)
    send(partition, :tick)

    assert_receive {:visible_outputs, :pre_tick, []}
    assert_receive {:observed_output, :tick, {:ok, %{prepared_in: :pre_tick}}}
    assert_receive {:observed_output, :post_tick, {:ok, %{prepared_in: :pre_tick}}}

    send(partition, :tick)
    assert_receive {:visible_outputs, :pre_tick, []}
  end

  test "carries event-system changes into later batches and the post-tick phase", %{
    source: source
  } do
    partition =
      start_supervised!(
        {TestPartition,
         id: self(),
         event_source: source,
         pre_tick_systems: [EventChangeEmittingSystem, ChangeObservingSystem],
         systems: [],
         post_tick_systems: [ChangeObservingSystem],
         interval: 60_000,
         concurrency: 2}
      )

    assert Partition.started?(partition)
    GenServer.cast(partition, {:events, [%Test1Event{id: 7}]})
    _state = :sys.get_state(partition)
    send(partition, :tick)

    assert_receive {:event_visible_change_set_count, 0}
    assert_receive {:observed_change_sets, :pre_tick, [{:event, 7}]}
    assert_receive {:observed_change_sets, :post_tick, [{:event, 7}]}
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

  test "acknowledges tracked events after every tick phase completes", %{source: source} do
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
    receipt = make_ref()
    events = [%Test1Event{id: 1}]

    GenServer.cast(partition, {:tracked_events, receipt, self(), events})
    _state = :sys.get_state(partition)
    send(partition, :tick)

    assert_receive {:event_processed, 1}
    assert_receive {:"$gen_cast", {:ack, ^receipt, test_pid, []}}
    assert test_pid == self()
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

  test "reports failed systems in a tracked event acknowledgement", %{source: source} do
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
    receipt = make_ref()
    event = %Test1Event{id: counter}

    capture_log(fn ->
      GenServer.cast(partition, {:tracked_events, receipt, self(), [event, event]})
      _state = :sys.get_state(partition)
      send(partition, :tick)

      assert_receive {:"$gen_cast", {:ack, ^receipt, test_pid, [FailOnceEventSystem]}}
      assert test_pid == self()
    end)
  end

  test "emits tick and phase telemetry without raw event payloads", %{source: source} do
    handler_id = make_ref()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:elvengard_ecs, :partition_tick, :stop],
          [:elvengard_ecs, :phase_run, :stop],
          [:elvengard_ecs, :system_run, :stop]
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
         systems: [EventRecordingSystem],
         interval: 60_000,
         concurrency: 1}
      )

    assert Partition.started?(partition)
    event = %Test1Event{id: 7}
    GenServer.cast(partition, {:events, [event]})
    _state = :sys.get_state(partition)
    send(partition, :tick)

    assert_receive {:event_processed, 7}

    assert_receive {:telemetry, [:elvengard_ecs, :system_run, :stop],
                    %{duration: system_duration}, system_metadata}

    assert system_duration >= 0
    assert system_metadata.partition == self()
    assert system_metadata.phase == :tick
    assert system_metadata.event_type == Test1Event
    refute Map.has_key?(system_metadata, :event)

    assert_receive {:telemetry, [:elvengard_ecs, :phase_run, :stop],
                    %{
                      duration: phase_duration,
                      event_count: 1,
                      failure_count: 0,
                      output_count: 0,
                      system_run_count: 1
                    }, %{partition: test_pid, phase: :tick, configured_system_count: 1}}

    assert test_pid == self()
    assert phase_duration >= 0

    assert_receive {:telemetry, [:elvengard_ecs, :partition_tick, :stop],
                    %{
                      duration: tick_duration,
                      event_count: 1,
                      failure_count: 0,
                      output_count: 0,
                      receipt_count: 0
                    }, %{partition: test_pid}}

    assert test_pid == self()
    assert tick_duration >= 0
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
