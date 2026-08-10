defmodule ElvenGard.ECS do
  @moduledoc """
  Entry point for events in ElvenGard.ECS.

  ElvenGard.ECS stores entities and components through a configurable backend
  and executes systems inside partitions. Most applications use
  `ElvenGard.ECS.Command` for writes and `ElvenGard.ECS.Query` for reads.

  This module provides the clock used by events and dispatch functions that
  timestamp events before forwarding them to
  `ElvenGard.ECS.Topology.EventSource`.
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

  @doc """
  Timestamps and dispatches events, then waits for their processing tick.

  The `:partition` option has the same override semantics as `push/2`.
  `:event_source` selects a custom event source and `:timeout` controls how
  long to await partition acknowledgements; they default to the global source
  and 5,000 milliseconds.

  A timeout only stops the caller from waiting. Events that were delivered are
  still processed. Use `push/2` when the caller does not require an
  acknowledgement; its asynchronous fast path does not allocate or track a
  receipt.
  """
  @spec push_and_wait(Event.t() | [Event.t()], Keyword.t()) ::
          {:ok, [Event.t()]}
          | {:error, :timeout}
          | {:error, {:partition_unavailable, [any()]}}
          | {:error, {:partition_down, [any()]}}
          | {:error, {:systems_failed, %{optional(any()) => [module()]}}}
  def push_and_wait(maybe_events, opts \\ []) do
    now = now()
    events = maybe_events |> List.wrap() |> Enum.map(&Map.put(&1, :inserted_at, now))

    events =
      case Keyword.get(opts, :partition) do
        nil -> events
        partition -> Enum.map(events, &Map.put(&1, :partition, partition))
      end

    event_source = Keyword.get(opts, :event_source, EventSource.name())
    timeout = Keyword.get(opts, :timeout, 5_000)

    case EventSource.dispatch_and_wait(event_source, events, timeout) do
      :ok -> {:ok, events}
      {:error, _reason} = error -> error
    end
  end
end
