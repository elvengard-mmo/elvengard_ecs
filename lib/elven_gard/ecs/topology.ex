defmodule ElvenGard.ECS.Topology do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Topology
  """

  alias ElvenGard.ECS.Topology.Partition

  ## Public API

  def wait_for_partitions(pids, timeout \\ 5000)

  def wait_for_partitions([], _timeout), do: :ok
  def wait_for_partitions(_pids, timeout) when timeout < 1, do: {:error, :timeout}

  def wait_for_partitions(pids, timeout) do
    start = ElvenGard.ECS.now()
    pid = spawn_link(__MODULE__, :do_wait_for_partitions, [self(), pids])

    receive do
      {:"$wait_for_partitions", []} -> :ok
      {:"$wait_for_partitions", pids} -> wait_for_partitions(pids, ElvenGard.ECS.now() - start)
    after
      timeout ->
        Process.unlink(pid)
        Process.exit(pid, :timeout)
        {:error, :timeout}
    end
  end

  ## Internal use only

  @doc false
  def do_wait_for_partitions(from, pids) do
    result =
      pids
      |> Enum.map(&if not Partition.started?(&1), do: &1)
      |> Enum.reject(&is_nil/1)

    send(from, {:"$wait_for_partitions", result})
  end
end
