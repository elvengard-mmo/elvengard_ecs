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

  ## GenServer behaviour

  @impl true
  def init(_opts) do
    # partitions = %{partition => pid}
    # subscribers = %{pid => {partition, ref}}
    # discarded = %{partition => {queue, event_count}}
    # {partitions, subscribers, discarded}
    {:ok, {%{}, %{}, %{}}}
  end

  @impl true
  def handle_call({:subscribe, partition}, {pid, _}, {partitions, subs, discarded} = state) do
    case partition_exists?(partitions, partition) do
      false ->
        ref = Process.monitor(pid)
        subs = Map.put(subs, pid, {partition, ref})
        partitions = Map.put(partitions, partition, pid)

        {{pending, _event_count}, discarded} =
          Map.pop(discarded, partition, {:queue.new(), 0})

        :ok = maybe_send(pid, :queue.to_list(pending))
        {:reply, :ok, {partitions, subs, discarded}}

      true ->
        Logger.error("there is already a consumer for the partition: #{partition}")
        {:reply, {:error, :already_exists}, state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, {partitions, subs, discarded} = state) do
    case Map.pop(subs, pid) do
      {{partition, ref}, subs} ->
        partitions = Map.delete(partitions, partition)
        true = Process.demonitor(ref, [:flush])
        {:noreply, {partitions, subs, discarded}}

      {nil, _subs} ->
        Logger.error("can't unsubscribe process #{inspect(pid)}: not registered")
        {:noreply, state}
    end
  end

  def handle_cast({:dispatch, events}, {partitions, subs, discarded}) do
    discarded =
      events
      |> Enum.group_by(& &1.partition, & &1)
      |> Enum.to_list()
      |> dispatch_events(partitions, discarded)

    {:noreply, {partitions, subs, discarded}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, {partitions, subs, discarded}) do
    {{partition, ^ref}, subs} = Map.pop!(subs, pid)
    partitions = Map.delete(partitions, partition)
    {:noreply, {partitions, subs, discarded}}
  end

  ## Internal API

  @doc false
  @spec name() :: {:global, module()}
  def name(), do: {:global, __MODULE__}

  ## Private functions

  defp maybe_send(_pid, []), do: :ok
  defp maybe_send(pid, events), do: GenServer.cast(pid, {:events, events})

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
    end

    {queue, min(total_event_count, @buffer_limit)}
  end

  defp drop_oldest(queue, 0), do: queue

  defp drop_oldest(queue, count) do
    {{:value, _event}, queue} = :queue.out(queue)
    drop_oldest(queue, count - 1)
  end
end
