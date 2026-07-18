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
    task =
      Task.async(fn ->
        Enum.each(pids, &Partition.started?(&1, :infinity))
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      nil -> {:error, :timeout}
    end
  end
end
