defmodule ElvenGard.ECS.TopologyTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Topology

  defmodule ControllablePartition do
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid) do
      {:ok, test_pid}
    end

    @impl true
    def handle_call(:started?, from, test_pid) do
      send(test_pid, {:started?, from})
      {:noreply, test_pid}
    end
  end

  test "waits until a partition is started" do
    partition = start_supervised!({ControllablePartition, self()})
    waiter = Task.async(fn -> Topology.wait_for_partitions([partition]) end)

    assert_receive {:started?, from}
    GenServer.reply(from, true)

    assert Task.await(waiter) == :ok
  end

  test "returns an error on timeout" do
    partition = start_supervised!({ControllablePartition, self()})

    assert Topology.wait_for_partitions([partition], 10) == {:error, :timeout}
  end

  test "does not consume a stale result from a previous wait" do
    partition = start_supervised!({ControllablePartition, self()})
    send(self(), {:"$wait_for_partitions", []})

    assert Topology.wait_for_partitions([partition], 10) == {:error, :timeout}
  end
end
