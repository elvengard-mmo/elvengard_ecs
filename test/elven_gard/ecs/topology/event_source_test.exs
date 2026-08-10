defmodule ElvenGard.ECS.Topology.EventSourceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ElvenGard.ECS.Topology.EventSource

  defmodule OddEvenEvent do
    use ElvenGard.ECS.Event, fields: [:value]

    def new(value) do
      %OddEvenEvent{
        value: value,
        partition: if(rem(value, 2) == 0, do: :even, else: :odd)
      }
    end

    def value(%OddEvenEvent{value: value}) do
      value
    end
  end

  ## Setup

  setup do
    name = :"Elixir.EventSource#{Enum.random(1..1_000_000)}"
    %{source: start_supervised!({EventSource, [name: name]}, id: name)}
  end

  ## Tests

  test "is globally registered" do
    start_supervised!({EventSource, []})

    {:global, name} = EventSource.name()
    assert is_pid(:global.whereis_name(name))
  end

  test "cannot be start multiple times" do
    start_supervised!({EventSource, []})

    # EventSource is already started by the setup_all
    assert EventSource.start_link([]) == :ignore
  end

  test "subscribe/1 require a :partition option" do
    assert_raise ArgumentError, ":partition option is required when subscribing", fn ->
      EventSource.subscribe([])
    end
  end

  test "subscribes and unsubscribe", %{source: source} do
    :ok = EventSource.subscribe(source, partition: :odd)
    assert Map.has_key?(partitions(source), :odd)

    :ok = EventSource.unsubscribe(source)
    refute Map.has_key?(partitions(source), :odd)
  end

  test "subscribe and dispatch", %{source: source} do
    :ok = EventSource.subscribe(source, partition: :odd)
    events = Enum.map([1, 3, 5, 7, 9], &OddEvenEvent.new/1)

    :ok = EventSource.dispatch(source, events)
    assert_receive {:"$gen_cast", {:events, ^events}}
  end

  test "emits bounded asynchronous dispatch telemetry", %{source: source} do
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elvengard_ecs, :event_dispatch, :stop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = EventSource.subscribe(source, partition: :odd)
    events = Enum.map([1, 3], &OddEvenEvent.new/1)

    :ok = EventSource.dispatch(source, events)
    assert_receive {:"$gen_cast", {:events, ^events}}

    assert_receive {:telemetry, %{duration: duration, event_count: 2, partition_count: 1},
                    metadata}

    assert duration >= 0
    assert metadata.mode == :async
    assert metadata.partition == :odd
    refute Map.has_key?(metadata, :events)
  end

  test "waits for tracked dispatch acknowledgements", %{source: source} do
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elvengard_ecs, :event_dispatch, :stop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = EventSource.subscribe(source, partition: :odd)
    events = Enum.map([1, 3], &OddEvenEvent.new/1)
    dispatch = Task.async(fn -> EventSource.dispatch_and_wait(source, events, 1_000) end)

    assert_receive {:"$gen_cast", {:tracked_events, receipt, ^source, ^events}}
    :ok = EventSource.ack(source, receipt, :odd, [])

    assert Task.await(dispatch) == :ok

    assert_receive {:telemetry, %{duration: duration, event_count: 2, partition_count: 1},
                    %{mode: :awaited, outcome: :ok, partition: :odd}}

    assert duration >= 0
  end

  test "returns an error when an awaited partition is unavailable", %{source: source} do
    events = [OddEvenEvent.new(1)]

    assert EventSource.dispatch_and_wait(source, events, 1_000) ==
             {:error, {:partition_unavailable, [:odd]}}
  end

  test "times awaited dispatches out without cancelling delivery", %{source: source} do
    :ok = EventSource.subscribe(source, partition: :odd)
    events = [OddEvenEvent.new(1)]
    dispatch = Task.async(fn -> EventSource.dispatch_and_wait(source, events, 10) end)

    assert_receive {:"$gen_cast", {:tracked_events, _receipt, ^source, ^events}}
    assert Task.await(dispatch) == {:error, :timeout}

    %{waiters: waiters, waiter_monitors: waiter_monitors} = :sys.get_state(source)
    assert waiters == %{}
    assert waiter_monitors == %{}
  end

  test "buffers events before subscription", %{source: source} do
    :ok = EventSource.dispatch(source, Enum.map([1, 3], &OddEvenEvent.new/1))
    :ok = EventSource.dispatch(source, Enum.map([7, 9], &OddEvenEvent.new/1))
    :ok = EventSource.dispatch(source, Enum.map([1, 3, 5, 7, 9], &OddEvenEvent.new/1))

    :ok = EventSource.subscribe(source, partition: :odd)
    all_events = Enum.map([1, 3, 7, 9, 1, 3, 5, 7, 9], &OddEvenEvent.new/1)
    assert_receive {:"$gen_cast", {:events, ^all_events}}
  end

  test "keeps the latest 10,000 buffered events and logs dropped events", %{source: source} do
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elvengard_ecs, :event_drop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    events = Enum.map(1..10_005, &OddEvenEvent.new(&1 * 2 - 1))
    {initial_events, overflow_events} = Enum.split(events, 9_998)

    :ok = EventSource.dispatch(source, initial_events)

    log =
      capture_log(fn ->
        :ok = EventSource.dispatch(source, overflow_events)
        :ok = EventSource.subscribe(source, partition: :odd)

        assert_receive {:"$gen_cast", {:events, buffered_events}}
        assert length(buffered_events) == 10_000
        assert buffered_events == Enum.drop(events, 5)
      end)

    assert log =~ "dropped 5 buffered events for partition :odd"

    assert_receive {:telemetry, %{event_count: 5}, %{partition: :odd, buffer_limit: 10_000}}
  end

  test "dispatch to multiple partition", %{source: source} do
    all_events = Enum.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], &OddEvenEvent.new/1)
    odd_events = Enum.map([1, 3, 5, 7, 9], &OddEvenEvent.new/1)
    even_events = Enum.map([2, 4, 6, 8, 10], &OddEvenEvent.new/1)
    :ok = EventSource.dispatch(source, all_events)

    # First get odd events
    :ok = EventSource.subscribe(source, partition: :odd)
    assert_receive {:"$gen_cast", {:events, ^odd_events}}
    refute_receive {:"$gen_cast", {:events, ^even_events}}

    # Then get even events
    :ok = EventSource.unsubscribe(source)
    :ok = EventSource.subscribe(source, partition: :even)
    assert_receive {:"$gen_cast", {:events, ^even_events}}
  end

  test "subscribers are monitored", %{source: source} do
    self = self()

    {:ok, pid} =
      Task.start(fn ->
        EventSource.subscribe(source, partition: :odd)
        send(self, :sync_message)
        Process.sleep(:infinity)
      end)

    # Wait for partition to be subscribed
    receive do
      :sync_message -> :ok
    end

    # Process is registered
    assert Map.has_key?(partitions(source), :odd)

    # Process is unregistered when the process crash/exits
    sync_kill(pid)
    refute Map.has_key?(partitions(source), :odd)
  end

  test "survives a subscriber exiting immediately after unsubscribe", %{source: source} do
    caller = self()

    {:ok, subscriber} =
      Task.start(fn ->
        :ok = EventSource.subscribe(source, partition: :odd)
        send(caller, :subscribed)

        receive do
          :unsubscribe -> EventSource.unsubscribe(source)
        end
      end)

    assert_receive :subscribed
    :ok = :sys.suspend(source)

    subscriber_ref = Process.monitor(subscriber)
    send(subscriber, :unsubscribe)
    assert_receive {:DOWN, ^subscriber_ref, :process, ^subscriber, :normal}

    :ok = :sys.resume(source)

    refute Map.has_key?(partitions(source), :odd)
    assert Process.alive?(source)
  end

  ## Helpers

  @doc false
  def handle_telemetry(_event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, measurements, metadata})
  end

  defp partitions(source) do
    %{partitions: partitions} = :sys.get_state(source)
    partitions
  end

  defp sync_kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end
end
