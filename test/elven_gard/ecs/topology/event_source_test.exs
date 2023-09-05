defmodule ElvenGard.ECS.Topology.EventSourceTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Topology.EventSource

  ## Setup

  setup do
    name = :"Elixir.EventSource#{Enum.random(1..1_000_000)}"
    %{source: start_supervised!({EventSource, [name: name, hash: &odd_even_hash/1]}, id: name)}
  end

  ## Tests

  test "is globally registered" do
    start_supervised!({EventSource, hash: &odd_even_hash/1})

    {:global, name} = EventSource.name()
    assert is_pid(:global.whereis_name(name))
  end

  test "cannot be start multiple times" do
    start_supervised!({EventSource, hash: &odd_even_hash/1})

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
    :ok = EventSource.dispatch(source, [1, 3, 5, 7, 9])
    assert_receive {:"$gen_cast", {:events, [1, 3, 5, 7, 9]}}
  end

  test "buffers events before subscription", %{source: source} do
    :ok = EventSource.dispatch(source, [1, 3])
    :ok = EventSource.dispatch(source, [7, 9])
    :ok = EventSource.dispatch(source, [1, 3, 5, 7, 9])

    :ok = EventSource.subscribe(source, partition: :odd)
    assert_receive {:"$gen_cast", {:events, [1, 3, 7, 9, 1, 3, 5, 7, 9]}}
  end

  test "dispatch to multiple partition", %{source: source} do
    :ok = EventSource.dispatch(source, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

    # First get odd events
    :ok = EventSource.subscribe(source, partition: :odd)
    assert_receive {:"$gen_cast", {:events, [1, 3, 5, 7, 9]}}
    refute_receive {:"$gen_cast", {:events, [2, 4, 6, 8, 10]}}

    # Then get even events
    :ok = EventSource.unsubscribe(source)
    :ok = EventSource.subscribe(source, partition: :even)
    assert_receive {:"$gen_cast", {:events, [2, 4, 6, 8, 10]}}
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

  ## Helpers

  defp odd_even_hash(event) do
    {event, if(rem(event, 2) == 0, do: :even, else: :odd)}
  end

  defp partitions(source) do
    {_hash, partitions, _subscribers, _discarded} = :sys.get_state(source)
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
