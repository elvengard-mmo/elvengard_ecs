defmodule ElvenGard.ECS.Topology.EventSource do
  @moduledoc """
  Routes events to partitions.

  An event source accepts one subscriber process per partition identifier.
  Events dispatched before that partition subscribes are buffered in order.
  Each unconsumed partition keeps at most 10,000 events; older events are
  dropped with a warning when the limit is exceeded.

  Subscribers are monitored and automatically removed when they terminate.
  The default event source uses a global name. Applications normally start it
  before their `ElvenGard.ECS.Topology.Partition` children:

      children = [
        ElvenGard.ECS.Topology.EventSource,
        {MyGame.WorldPartition, id: :world}
      ]

  A local or custom event source can be started with `name: name` and passed to
  each partition through its `:event_source` option.

  Dispatch emits `[:elvengard_ecs, :event_dispatch]` spans without event
  payloads. Buffer overflow emits `[:elvengard_ecs, :event_drop]` with the
  dropped count, partition, and configured buffer limit.
  """

  use GenServer

  require Logger

  alias ElvenGard.ECS.Event

  @buffer_limit 10_000

  ## Public API

  @doc """
  Starts an event source.

  The `:name` option defaults to the global name used by `subscribe/1` and
  `dispatch/1`. Starting another source with that default name returns
  `:ignore` when one is already registered.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, name())
    do_start_link(name, opts)
  end

  @doc """
  Subscribes the calling process to one partition.

  The required `:partition` option identifies the events delivered to the
  caller. Only one process may own a partition at a time. Buffered events are
  delivered immediately after a successful subscription.
  """
  @spec subscribe(GenServer.server(), Keyword.t()) :: :ok | {:error, :already_exists}
  def subscribe(name \\ name(), opts) do
    partition = validate_partition(opts)
    GenServer.call(name, {:subscribe, partition})
  end

  @doc """
  Asynchronously unsubscribes the calling process from an event source.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(name \\ name()) do
    GenServer.cast(name, {:unsubscribe, self()})
  end

  @doc """
  Asynchronously dispatches events according to their `:partition` field.

  Use `ElvenGard.ECS.push/2` when events must also receive an `:inserted_at`
  timestamp.
  """
  @spec dispatch(GenServer.server(), [Event.t()]) :: :ok
  def dispatch(name \\ name(), events) do
    GenServer.cast(name, {:dispatch, events})
  end

  @doc """
  Dispatches events and waits until every destination partition has completed
  the tick that consumed them.

  Unlike `dispatch/2`, this operation requires every destination partition to
  be subscribed when it starts. A timeout stops waiting but does not cancel
  events that have already been delivered.
  """
  @spec dispatch_and_wait(GenServer.server(), [Event.t()], timeout()) ::
          :ok
          | {:error, :timeout}
          | {:error, {:partition_unavailable, [any()]}}
          | {:error, {:partition_down, [any()]}}
          | {:error, {:systems_failed, %{optional(any()) => [module()]}}}
  def dispatch_and_wait(name \\ name(), events, timeout \\ 5_000) do
    {metadata, partition_count} = event_dispatch_metadata(events, :awaited)

    :telemetry.span([:elvengard_ecs, :event_dispatch], metadata, fn ->
      result = GenServer.call(name, {:dispatch_and_wait, events, timeout}, :infinity)

      measurements = %{
        event_count: length(events),
        partition_count: partition_count
      }

      {result, measurements, Map.put(metadata, :outcome, dispatch_outcome(result))}
    end)
  end

  @doc false
  @spec ack(GenServer.server(), reference(), any(), [module()]) :: :ok
  def ack(name, receipt, partition, failed_systems) do
    GenServer.cast(name, {:ack, receipt, partition, failed_systems})
  end

  ## GenServer behaviour

  @impl true
  def init(_opts) do
    {:ok,
     %{
       partitions: %{},
       subscribers: %{},
       discarded: %{},
       waiters: %{},
       waiter_monitors: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, partition}, {pid, _}, state) do
    %{partitions: partitions, subscribers: subscribers, discarded: discarded} = state

    case partition_exists?(partitions, partition) do
      false ->
        ref = Process.monitor(pid)
        subscribers = Map.put(subscribers, pid, {partition, ref})
        partitions = Map.put(partitions, partition, pid)

        {{pending, _event_count}, discarded} =
          Map.pop(discarded, partition, {:queue.new(), 0})

        :ok = maybe_send(pid, :queue.to_list(pending))

        {:reply, :ok,
         %{state | partitions: partitions, subscribers: subscribers, discarded: discarded}}

      true ->
        Logger.error("there is already a consumer for the partition: #{partition}")
        {:reply, {:error, :already_exists}, state}
    end
  end

  def handle_call({:dispatch_and_wait, events, timeout}, from, state) do
    grouped_events = Enum.group_by(events, & &1.partition, & &1)
    unavailable = unavailable_partitions(grouped_events, state.partitions)

    case {map_size(grouped_events), unavailable} do
      {0, []} ->
        {:reply, :ok, state}

      {_, []} ->
        {receipt, state} = register_waiter(from, Map.keys(grouped_events), timeout, state)
        dispatch_tracked_events(grouped_events, state.partitions, receipt)
        {:noreply, state}

      {_, partitions} ->
        {:reply, {:error, {:partition_unavailable, partitions}}, state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    %{partitions: partitions, subscribers: subscribers} = state

    case Map.pop(subscribers, pid) do
      {{partition, ref}, subscribers} ->
        partitions = Map.delete(partitions, partition)
        true = Process.demonitor(ref, [:flush])

        state = %{state | partitions: partitions, subscribers: subscribers}
        {:noreply, fail_partition_waiters(state, partition)}

      {nil, _subscribers} ->
        Logger.error("can't unsubscribe process #{inspect(pid)}: not registered")
        {:noreply, state}
    end
  end

  def handle_cast({:dispatch, events}, state) do
    grouped_events = events |> Enum.group_by(& &1.partition, & &1) |> Enum.to_list()
    metadata = dispatch_metadata(:async, Enum.map(grouped_events, &elem(&1, 0)))

    discarded =
      :telemetry.span([:elvengard_ecs, :event_dispatch], metadata, fn ->
        discarded = dispatch_events(grouped_events, state.partitions, state.discarded)

        measurements = %{
          event_count: length(events),
          partition_count: length(grouped_events)
        }

        {discarded, measurements, Map.put(metadata, :outcome, :ok)}
      end)

    {:noreply, %{state | discarded: discarded}}
  end

  def handle_cast({:ack, receipt, partition, failed_systems}, state) do
    case state.waiters do
      %{^receipt => waiter} ->
        pending = MapSet.delete(waiter.pending, partition)

        failures =
          case failed_systems do
            [] -> waiter.failures
            systems -> Map.put(waiter.failures, partition, systems)
          end

        waiter = %{waiter | pending: pending, failures: failures}

        case MapSet.size(pending) do
          0 -> {:noreply, complete_waiter(state, receipt, waiter)}
          _ -> {:noreply, put_in(state.waiters[receipt], waiter)}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:await_timeout, receipt}, state) do
    case Map.fetch(state.waiters, receipt) do
      {:ok, waiter} ->
        GenServer.reply(waiter.from, {:error, :timeout})
        {:noreply, delete_waiter(state, receipt, waiter)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.waiter_monitors, ref) do
      {receipt, waiter_monitors} when not is_nil(receipt) ->
        state = %{state | waiter_monitors: waiter_monitors}

        case Map.pop(state.waiters, receipt) do
          {nil, _waiters} ->
            {:noreply, state}

          {waiter, waiters} ->
            cancel_waiter_timer(waiter.timer)
            {:noreply, %{state | waiters: waiters}}
        end

      {nil, _waiter_monitors} ->
        handle_subscriber_down(state, pid, ref)
    end
  end

  ## Internal API

  @doc false
  @spec name() :: {:global, module()}
  def name(), do: {:global, __MODULE__}

  ## Private functions

  defp maybe_send(_pid, []), do: :ok
  defp maybe_send(pid, events), do: GenServer.cast(pid, {:events, events})

  defp event_dispatch_metadata(events, mode) do
    partitions = events |> Enum.map(& &1.partition) |> Enum.uniq()
    {dispatch_metadata(mode, partitions), length(partitions)}
  end

  defp dispatch_metadata(mode, partitions) do
    partition =
      case partitions do
        [partition] -> partition
        [] -> nil
        _partitions -> :multiple
      end

    %{mode: mode, partition: partition}
  end

  defp dispatch_outcome(:ok), do: :ok
  defp dispatch_outcome({:error, :timeout}), do: :timeout
  defp dispatch_outcome({:error, {:partition_unavailable, _partitions}}), do: :unavailable
  defp dispatch_outcome({:error, {:partition_down, _partitions}}), do: :partition_down
  defp dispatch_outcome({:error, {:systems_failed, _failures}}), do: :systems_failed

  defp dispatch_tracked_events(grouped_events, partitions, receipt) do
    Enum.each(grouped_events, fn {partition, events} ->
      pid = Map.fetch!(partitions, partition)
      GenServer.cast(pid, {:tracked_events, receipt, self(), events})
    end)
  end

  defp unavailable_partitions(grouped_events, partitions) do
    grouped_events
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(partitions, &1))
    |> Enum.sort()
  end

  defp register_waiter(from, partitions, timeout, state) do
    receipt = make_ref()
    {caller, _tag} = from
    monitor = Process.monitor(caller)
    timer = start_waiter_timer(receipt, timeout)

    waiter = %{
      from: from,
      pending: MapSet.new(partitions),
      failures: %{},
      timer: timer,
      monitor: monitor
    }

    state = %{
      state
      | waiters: Map.put(state.waiters, receipt, waiter),
        waiter_monitors: Map.put(state.waiter_monitors, monitor, receipt)
    }

    {receipt, state}
  end

  defp start_waiter_timer(_receipt, :infinity), do: nil

  defp start_waiter_timer(receipt, timeout) do
    Process.send_after(self(), {:await_timeout, receipt}, timeout)
  end

  defp complete_waiter(state, receipt, waiter) do
    reply =
      case map_size(waiter.failures) do
        0 -> :ok
        _ -> {:error, {:systems_failed, waiter.failures}}
      end

    GenServer.reply(waiter.from, reply)
    delete_waiter(state, receipt, waiter)
  end

  defp delete_waiter(state, receipt, waiter) do
    cancel_waiter_timer(waiter.timer)
    true = Process.demonitor(waiter.monitor, [:flush])

    %{
      state
      | waiters: Map.delete(state.waiters, receipt),
        waiter_monitors: Map.delete(state.waiter_monitors, waiter.monitor)
    }
  end

  defp cancel_waiter_timer(nil), do: :ok

  defp cancel_waiter_timer(timer) do
    _result = Process.cancel_timer(timer)
    :ok
  end

  defp handle_subscriber_down(state, pid, ref) do
    case Map.pop(state.subscribers, pid) do
      {{partition, ^ref}, subscribers} ->
        partitions = Map.delete(state.partitions, partition)
        state = %{state | partitions: partitions, subscribers: subscribers}
        {:noreply, fail_partition_waiters(state, partition)}

      {nil, _subscribers} ->
        {:noreply, state}
    end
  end

  defp fail_partition_waiters(state, partition) do
    Enum.reduce(state.waiters, state, fn {receipt, waiter}, acc_state ->
      case MapSet.member?(waiter.pending, partition) do
        true ->
          GenServer.reply(waiter.from, {:error, {:partition_down, [partition]}})
          delete_waiter(acc_state, receipt, waiter)

        false ->
          acc_state
      end
    end)
  end

  defp do_start_link({:global, name}, opts) do
    case :global.whereis_name(name) do
      :undefined -> GenServer.start_link(__MODULE__, opts, name: {:global, name})
      _ -> :ignore
    end
  end

  defp do_start_link(name, opts) do
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp validate_partition(opts) do
    case Keyword.get(opts, :partition) do
      partition when not is_nil(partition) -> partition
      nil -> raise ArgumentError, ":partition option is required when subscribing"
    end
  end

  defp partition_exists?(partitions, partition) do
    Map.has_key?(partitions, partition)
  end

  defp dispatch_events([], _partitions, discarded), do: discarded

  defp dispatch_events([{partition, events} | rest], partitions, discarded) do
    case partitions do
      %{^partition => pid} ->
        maybe_send(pid, events)
        dispatch_events(rest, partitions, discarded)

      _ ->
        buffer = Map.get(discarded, partition, {:queue.new(), 0})
        discarded = Map.put(discarded, partition, buffer_events(partition, buffer, events))
        dispatch_events(rest, partitions, discarded)
    end
  end

  defp buffer_events(partition, {queue, event_count}, events) do
    new_event_count = length(events)
    total_event_count = event_count + new_event_count
    dropped_event_count = max(total_event_count - @buffer_limit, 0)

    queue =
      case new_event_count >= @buffer_limit do
        true ->
          events
          |> Enum.take(-@buffer_limit)
          |> :queue.from_list()

        false ->
          queue
          |> drop_oldest(dropped_event_count)
          |> :queue.join(:queue.from_list(events))
      end

    case dropped_event_count do
      0 ->
        :ok

      count ->
        Logger.warning("dropped #{count} buffered events for partition #{inspect(partition)}")

        :telemetry.execute(
          [:elvengard_ecs, :event_drop],
          %{event_count: count},
          %{partition: partition, buffer_limit: @buffer_limit}
        )
    end

    {queue, min(total_event_count, @buffer_limit)}
  end

  defp drop_oldest(queue, 0), do: queue

  defp drop_oldest(queue, count) do
    {{:value, _event}, queue} = :queue.out(queue)
    drop_oldest(queue, count - 1)
  end
end
