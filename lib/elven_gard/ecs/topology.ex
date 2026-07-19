defmodule ElvenGard.ECS.Topology do
  @moduledoc """
  Helpers for coordinating ECS topology processes.

  Event sources and partitions are supervised by the host application. Use
  `wait_for_partitions/2` when another child must not continue until every
  partition has finished its startup systems and subscribed to its event
  source.
  """

  alias ElvenGard.ECS.Topology.Partition

  ## Public API

  @doc """
  Waits until every partition reports that startup is complete.

  Returns `:ok` for an empty list or when every partition starts before the
  timeout. Returns `{:error, :timeout}` otherwise.
  """
  @spec wait_for_partitions([GenServer.server()], timeout()) :: :ok | {:error, :timeout}
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
