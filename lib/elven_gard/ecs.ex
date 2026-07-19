defmodule ElvenGard.ECS do
  @moduledoc """
  Entry point for events in ElvenGard.ECS.

  ElvenGard.ECS stores entities and components through a configurable backend
  and executes systems inside partitions. Most applications use
  `ElvenGard.ECS.Command` for writes and `ElvenGard.ECS.Query` for reads.

  This module provides the clock used by events and `push/2`, which timestamps
  events before forwarding them to `ElvenGard.ECS.Topology.EventSource`.
  """

  alias ElvenGard.ECS.Event
  alias ElvenGard.ECS.Topology.EventSource

  ## Public API

  @doc """
  Returns the current monotonic time in milliseconds.

  The value is suitable for measuring elapsed time inside the current Erlang
  VM. It is not a wall-clock timestamp.
  """
  @spec now() :: integer()
  def now(), do: System.monotonic_time(:millisecond)

  @doc """
  Timestamps and dispatches one event or a list of events.

  Every event receives the same `:inserted_at` monotonic timestamp. By default,
  its existing `:partition` field determines the destination partition. Pass
  `partition: partition` to override that field for every dispatched event.

  Returns the events after both fields have been applied. Dispatch is
  asynchronous.
  """
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
