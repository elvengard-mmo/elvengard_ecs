defmodule ElvenGard.ECS do
  @moduledoc """
  Documentation for `ElvenGard.ECS`.
  """

  alias ElvenGard.ECS.Event
  alias ElvenGard.ECS.Topology.EventSource

  ## Public API

  @spec now() :: integer()
  def now(), do: System.monotonic_time(:millisecond)

  @spec push(Event.t() | [Event.t()], Keyword.t()) :: {:ok, [Event.t()]}
  def push(maybe_events, opts \\ []) do
    now = now()
    events = maybe_events |> List.wrap() |> Enum.map(&Map.put(&1, :inserted_at, now))

    case Keyword.get(opts, :partition) do
      nil ->
        EventSource.dispatch(events)
        {:ok, events}

      partition ->
        partition_event = Enum.map(events, &Map.put(&1, :partition, partition))
        EventSource.dispatch(partition_event)
        {:ok, partition_event}
    end
  end
end
