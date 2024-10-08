defmodule ElvenGard.ECS.Topology.EventSource do
  @moduledoc """
  TODO: ElvenGard.ECS.Topology.EventSource
  """

  use GenServer

  require Logger

  ## Public API

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, name())
    do_start_link(name, opts)
  end

  @spec subscribe(GenServer.server(), Keyword.t()) :: :ok | {:error, :already_exists}
  def subscribe(name \\ name(), opts) do
    partition = validate_partition(opts)
    GenServer.call(name, {:subscribe, partition})
  end

  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(name \\ name()) do
    GenServer.cast(name, {:unsubscribe, self()})
  end

  @spec dispatch(GenServer.server(), [any()]) :: :ok
  def dispatch(name \\ name(), events) do
    GenServer.cast(name, {:dispatch, events})
  end

  ## GenServer behaviour

  @impl true
  def init(_opts) do
    # partitions = %{partition => pid}
    # subscribers = %{pid => {partition, ref}}
    # discarded = %{partition => [events]}
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
        {pending, discarded} = Map.pop(discarded, partition, [])

        :ok = maybe_send(pid, pending)
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
        true = Process.demonitor(ref)
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
  @spec name :: {:global, module()}
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
    partition in Map.keys(partitions)
  end

  defp dispatch_events([], _partitions, discarded), do: discarded

  defp dispatch_events([{partition, events} | rest], partitions, discarded) do
    case partitions do
      %{^partition => pid} ->
        maybe_send(pid, events)
        dispatch_events(rest, partitions, discarded)

      _ ->
        discarded = Map.update(discarded, partition, events, &(&1 ++ events))
        dispatch_events(rest, partitions, discarded)
    end
  end
end
